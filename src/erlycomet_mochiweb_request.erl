%%%-------------------------------------------------------------------
%%% @author Roberto Saccon <rsaccon@gmail.com> [http://rsaccon.com]
%%% @author Tait Larson
%%% @copyright 2007 Roberto Saccon, Tait Larson
%%% @doc 
%%% Comet extension for MochiWeb
%%% @end  
%%%
%%% The MIT License
%%%
%%% Copyright (c) 2007 Roberto Saccon, Tait Larson
%%%
%%% Permission is hereby granted, free of charge, to any person obtaining a copy
%%% of this software and associated documentation files (the "Software"), to deal
%%% in the Software without restriction, including without limitation the rights
%%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%%% copies of the Software, and to permit persons to whom the Software is
%%% furnished to do so, subject to the following conditions:
%%%
%%% The above copyright notice and this permission notice shall be included in
%%% all copies or substantial portions of the Software.
%%%
%%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
%%% THE SOFTWARE.
%%%
%%% @since 2007-11-11 by Roberto Saccon, Tait Larson
%%%-------------------------------------------------------------------
-module(erlycomet_mochiweb_request, [CustomAppModule]).
-author('telarson@gmail.com').
-author('rsaccon@gmail.com').


%% API
-export([handle/1]).

-include("erlycomet.hrl").

-record(state, {
    id = undefined,
    connection_type,
    messages = [],
    timeout = 1200000,      %% 20 min, just for testing
    callback = undefined}).  


%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% @spec
%% @doc handle POST / GET Comet messages
%% @end 
%%--------------------------------------------------------------------
handle(Req) ->
    handle(Req, Req:get(method)).
        
handle(Req, 'POST') ->
    handle(Req, Req:parse_post());
handle(Req, 'GET') ->
    handle(Req, Req:parse_qs());    
handle(Req, [{"message", Msg}, {"jsonp", Callback} | _]) ->
    case process_bayeux_msg(Req, json_decode(Msg), Callback) of
        done -> ok;
        [done] -> ok;
        Body -> 
            Resp = callback_wrapper(json_encode(Body), Callback),       
            Req:ok({"text/javascript", Resp})   
    end;
handle(Req, [{"message", Msg} | _]) ->
    case process_bayeux_msg(Req, json_decode(Msg), undefined) of
        done -> ok;
        [done] -> ok;
        Body -> Req:ok({"text/json", json_encode(Body)})
    end;
% New scenario!
handle(Req, [{Msg, []}]) ->
    case process_bayeux_msg(Req, json_decode(Msg), undefined) of
        done -> ok;
        [done] -> ok;
        Body -> Req:ok({"text/json", json_encode(Body)})
    end;
handle(Req, _Other) ->
	Req:not_found().
	%Req:respond({404, [{"Content-Type", "text/plain"}], <<"Nenhuma lolita por aqui!">>}).


%%====================================================================
%% Internal functions
%%====================================================================

process_bayeux_msg(Req, JsonObj, Callback) ->
    case JsonObj of   
        Array when is_list(Array) -> 
            [ process_msg(Req, X, Callback) || X <- Array ];
        Struct-> 
            process_msg(Req, Struct, Callback)
    end.


process_msg(Req, Struct, Callback) ->
    process_channel(Req, get_json_map_val(<<"channel">>, Struct), Struct, Callback).


get_json_map_val(Key, {struct, Pairs}) when is_list(Pairs) ->
    case [ V || {K, V} <- Pairs, K =:= Key] of
        [] -> undefined;
        [ V | _Rest ] -> V
    end;
get_json_map_val(_, _) ->
    undefined.
    

process_channel(_Req, <<"/meta/handshake">> = Channel, Struct, _) ->  
    % Advice = {struct, [{reconnect, "retry"},
    %                   {interval, 5000}]},
    % - get the alert from 
    _Ext = get_json_map_val(<<"ext">>, Struct),
    Id = generate_id(),
    erlycomet_api:replace_connection(Id, 0, handshake),
    JsonResp = {struct, [
        {channel, Channel}, 
        {version, 1.0},
        {supportedConnectionTypes, [
            <<"long-polling">>,
            <<"callback-polling">>]},
        {clientId, Id},
        {successful, true}]},
    % Resp2 = [{advice, Advice} | Resp],
	JsonResp;
    
process_channel(Req, <<"/meta/connect">> = Channel, Struct, Callback) ->  
    ClientId = get_json_map_val(<<"clientId">>, Struct),
    ConnectionType = get_json_map_val(<<"connectionType">>, Struct),
    L = [{channel,  Channel}, {clientId, ClientId}],    
    case erlycomet_api:replace_connection(ClientId, self(), connected) of
        {ok, Status} when Status =:= ok ; Status =:= replaced_hs ->
            {struct, [{successful, true} | L]};
            % don't reply immediately to new connect message.
            % instead wait. when new message is received, reply to connect and 
            % include the new message.  This is acceptable given bayeux spec. see section 4.2.2
        {ok, replaced} ->   
            Msg  = {struct, [{successful, true} | L]},
            Resp = Req:respond({200, [], chunked}),
            loop(Resp, #state{id = ClientId, 
                connection_type = ConnectionType,
                messages = [Msg],
                callback = Callback});
        _ ->
            {struct, [{successful, false} | L]}
    end;    
           
process_channel(Req, <<"/meta/disconnect">> = Channel, Struct, _) ->  
    ClientId = get_json_map_val(<<"clientId">>, Struct),
	process_client_id(Req, Channel, ClientId, []);
    
process_channel(Req, Channel, Struct, _) when (<<"/meta/subscribe">> =:= Channel);
                                                                       (<<"/meta/unsubscribe">> =:= Channel) ->
    ClientId = get_json_map_val(<<"clientId">>, Struct),
    Subscription = get_json_map_val(<<"subscription">>, Struct),
    process_client_id(Req, Channel, ClientId, Subscription);
          
process_channel(Req, Channel, Struct, _) ->
    ClientId = get_json_map_val(<<"clientId">>, Struct),
    Data = get_json_map_val(<<"data">>, Struct),
    process_client_id(Req, Channel, ClientId, rpc(Data, Channel)).   
    
    
process_client_id(_, Channel, undefined, _) ->   
    {struct, [{<<"channel">>, Channel}, {successful, false}]};  
process_client_id(Req, Channel, Id, Data) ->
    process_data(Req, Channel, Id, Data).
    

process_data(_, <<"/meta/disconnect">> = Channel, ClientId, _) ->    
	L = [{channel, Channel}, {clientId, ClientId}],
	case erlycomet_api:remove_connection(ClientId) of
		ok -> {struct, [{successful, true}  | L]};
		_ ->  {struct, [{successful, false}  | L]}
	end;

process_data(_, <<"/meta/subscribe">> = Channel, ClientId, Subscription) ->    
    L = [{channel, Channel}, {clientId, ClientId}, {subscription, Subscription}],
    case erlycomet_api:subscribe(ClientId, Subscription) of
        ok -> {struct, [{successful, true}  | L]};
        _ ->  {struct, [{successful, false}  | L]}
    end;  
         
process_data(_, <<"/meta/unsubscribe">> = Channel, ClientId, Subscription) ->  
    L = [{channel, Channel}, {clientId, ClientId}, {subscription, Subscription}],          
    case erlycomet_api:unsubscribe(ClientId, Subscription) of
        ok -> {struct, [{successful, true}  | L]};
        _ ->  {struct, [{successful, false}  | L]}
    end;  
    
process_data(_, <<$/, $s, $e, $r, $v, $i, $c, $e, $/, _/binary>> = Channel, ClientId, Data) ->  
    L = [{"channel", Channel}, {"clientId", ClientId}],
    case erlycomet_api:deliver_to_connection(ClientId, #event{channel=Channel, sender_id=0, data=Data}) of
        ok -> {struct, [{"successful", true}  | L]};
        _ ->  {struct, [{"successful", false}  | L]}
    end;   
             
process_data(_, Channel, ClientId, Data) ->  
    L = [{channel, Channel}, {clientId, ClientId}],
    case erlycomet_api:deliver_event(#event{channel=Channel, sender_id=ClientId, data=Data}) of
        ok -> {struct, [{successful, true}  | L]};
        _ ->  {struct, [{successful, false}  | L]}
    end.


json_decode(Str) ->
    mochijson2:decode(Str).
    
json_encode(Body) ->
    mochijson2:encode(Body).


callback_wrapper(Data, undefined) ->
    Data;       
callback_wrapper(Data, Callback) ->
    lists:concat([Callback, "(", Data, ");"]).


generate_id() ->
    <<Num:128>> = crypto:rand_bytes(16),
    [HexStr] = io_lib:fwrite("~.16B",[Num]),
    case erlycomet_api:connection_pid(HexStr) of
        undefined ->
            HexStr;
    _ ->
        generate_id()
    end.


loop(Resp, #state{messages=Msgs, id=ClientId, callback=Callback} = State) ->   
    receive
        stop ->  
            disconnect(Resp, ClientId, State);
        {add, Event} -> 
            loop(Resp, State#state{messages=[event_to_json_struct(Event) | Msgs]});
        {flush, Event} -> 
			Msgs2 = [event_to_json_struct(Event) | Msgs],
            send(Resp, lists:reverse(Msgs2), Callback),
            done;
        flush -> 
            send(Resp, lists:reverse(Msgs), Callback),
            done 
    after State#state.timeout ->
        disconnect(Resp, ClientId, Callback)
    end.


event_to_json_struct(#event{channel=C, data=D}) ->
	{struct, [{channel, C}, {data, D}]}.
  
    
send(Resp, Data, Callback) ->
    Chunk = callback_wrapper(json_encode(Data), Callback),
    Resp:write_chunk(Chunk),
    Resp:write_chunk([]).
    
    
disconnect(Resp, ClientId, Callback) ->
    erlycomet_api:remove_connection(ClientId),
    Msg = {struct, [{channel, <<"/meta/disconnect">>}, {successful, true}, {clientId, ClientId}]},
    Chunk = callback_wrapper(json_encode(Msg), Callback),
    Resp:write_chunk(Chunk),
    Resp:write_chunk([]),
    done.
    
    
rpc({struct, [{<<"id">>, Id}, {<<"method">>, Method}, {<<"params">>, Params}]}, Channel) ->
    Func = list_to_atom(binary_to_list(Method)),
    case catch apply(CustomAppModule, Func, [Channel | Params]) of
         {'EXIT', _} ->
             {struct, [{result, null}, {error, <<"RPC failure">>}, {id, Id}]};
         {error, Reason} ->
             {struct, [{result, null}, {error, Reason}, {id, Id}]};
         Value ->
             {struct, [{result, Value}, {error, null}, {id, Id}]}
    end;
rpc(Msg, _) -> Msg.