%%%-------------------------------------------------------------------
%%% @author Roberto Saccon <rsaccon@gmail.com> [http://rsaccon.com]
%%% @author Tait Larson
%%% @author Davide Marquês
%%% @copyright 2009 Roberto Saccon, Tait Larson, Davide Marquês
%%% @doc 
%%% Comet extension for Yaws
%%% @end  
%%%
%%% The MIT License
%%%
%%% Copyright (c) 2009 Roberto Saccon, Tait Larson, Davide Marquês
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
-module(erlycomet_yaws_request, [CustomAppModule]).
-author('telarson@gmail.com').
-author('rsaccon@gmail.com').
-author('nesrait@gmail.com').


%% API
-export([handle/1]).

-include("erlycomet.hrl").
-include_lib("yaws/include/yaws_api.hrl").

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
handle(Arg) ->
	Req = Arg#arg.req,
	Data = case Req#http_request.method of
		'POST' -> yaws_api:parse_post(Arg);
		'GET' -> yaws_api:parse_query(Arg)
	end,
	%io:format("handle -> ~p~n~p~n~n", [self(), Data]),
	handle2(Data).
	
handle2([{"message", Msg}, {"jsonp", Callback} | _]) ->
	case process_bayeux_msg(json_decode(Msg), Callback) of
		done -> comet_return();
		[done] -> comet_return();
		{streamcontent_with_timeout, _, _, _} = Comet -> Comet;
		[{streamcontent_with_timeout, _, _, _}] = Comet -> Comet;
		Body -> 
			Resp = callback_wrapper(json_encode(Body), Callback),
			send(Resp)
	end;
handle2([{"message", Msg} | _]) ->
	case process_bayeux_msg(json_decode(Msg), undefined) of
		done -> comet_return();
		[done] -> comet_return();
		{streamcontent_with_timeout, _, _, _} = Comet -> Comet;
		[{streamcontent_with_timeout, _, _, _}] = Comet -> Comet;
		Body -> send(json_encode(Body))
	end;
handle2([{Msg, undefined}]) ->
	case process_bayeux_msg(json_decode(Msg), undefined) of
		done -> comet_return();
		[done] -> comet_return();
		{streamcontent_with_timeout, _, _, _} = Comet -> Comet;
		[{streamcontent_with_timeout, _, _, _}] = Comet -> Comet;
		Body -> send(json_encode(Body))
	end;
handle2(_) ->
	[{status, 404}, {content, "text/html", "Nop."}].

%%====================================================================
%% Internal functions
%%====================================================================

comet_return() ->
	{streamcontent_with_timeout, "application/octet-stream", <<>>, infinity}.

process_bayeux_msg(JsonObj, Callback) ->
    case JsonObj of   
        Array when is_list(Array) -> 
            [ process_msg(X, Callback) || X <- Array ];
        Struct-> 
            process_msg(Struct, Callback)
    end.


process_msg(Struct, Callback) ->
    process_channel(get_json_map_val(<<"channel">>, Struct), Struct, Callback).


get_json_map_val(Key, {struct, Pairs}) when is_list(Pairs) ->
    case [ V || {K, V} <- Pairs, K =:= Key] of
        [] -> undefined;
        [ V | _Rest ] -> V
    end;
get_json_map_val(_, _) ->
    undefined.
    

process_channel(<<"/meta/handshake">> = Channel, Struct, _) ->  
    % Advice = {struct, [{reconnect, "retry"},
    %                   {interval, 5000}]},
    % - get the alert from 
    _Ext = get_json_map_val(<<"ext">>, Struct),
    Id = list_to_binary(generate_id()),
    erlycomet_api:replace_client_connection(Id, 0, handshake),
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
    
process_channel(<<"/meta/connect">> = Channel, Struct, Callback) ->  
    ClientId = get_json_map_val(<<"clientId">>, Struct),
    ConnectionType = get_json_map_val(<<"connectionType">>, Struct),
    L = [{channel,  Channel}, {clientId, ClientId}],
    case erlycomet_api:replace_client_connection(ClientId, self(), connected) of
        {ok, Status} when Status =:= ok ; Status =:= replaced_hs ->
            {struct, [{successful, true} | L]};
            % don't reply immediately to new connect message.
            % instead wait. when new message is received, reply to connect and 
            % include the new message.  This is acceptable given bayeux spec. see section 4.2.2
        {ok, replaced} ->   
            Msg  = {struct, [{successful, true} | L]},
			State = #state{id = ClientId, connection_type = ConnectionType, messages = [Msg], callback = Callback},
			loop(State);
        _ ->
            {struct, [{successful, false} | L]}
    end;    
    
process_channel(<<"/meta/disconnect">> = Channel, Struct, _) ->  
    ClientId = get_json_map_val(<<"clientId">>, Struct),
	process_client_id(Channel, ClientId, []);
    
process_channel(Channel, Struct, _) when (<<"/meta/subscribe">> =:= Channel);
                                                                   (<<"/meta/unsubscribe">> =:= Channel) ->
    ClientId = get_json_map_val(<<"clientId">>, Struct),
    Subscription = get_json_map_val(<<"subscription">>, Struct),
    process_client_id(Channel, ClientId, Subscription);
          
process_channel(Channel, Struct, _) ->
    ClientId = get_json_map_val(<<"clientId">>, Struct),
    Data = get_json_map_val(<<"data">>, Struct),
    process_client_id(Channel, ClientId, rpc(Data, Channel)).   


process_client_id(Channel, undefined, _) ->   
    {struct, [{<<"channel">>, Channel}, {successful, false}]};  
process_client_id(Channel, Id, Data) ->
    process_data(Channel, Id, Data).


process_data(<<"/meta/disconnect">> = Channel, ClientId, _) ->    
	L = [{channel, Channel}, {clientId, ClientId}],
	case erlycomet_api:remove_connection(ClientId) of
		ok -> {struct, [{successful, true}  | L]};
		_ ->  {struct, [{successful, false}  | L]}
	end;

process_data(<<"/meta/subscribe">> = Channel, ClientId, <<$/, $s, $e, $r, $v, $i, $c, $e, $/, _/binary>> = Subscription) ->
	{struct, [{successful, false}, {channel, Channel}, {clientId, ClientId}, {subscription, Subscription}]};
process_data(<<"/meta/subscribe">> = Channel, ClientId, Subscription) ->
    L = [{channel, Channel}, {clientId, ClientId}, {subscription, Subscription}],
    case erlycomet_api:subscribe(ClientId, Subscription) of
        ok -> {struct, [{successful, true}  | L]};
        _ ->  {struct, [{successful, false}  | L]}
    end;
         
process_data(<<"/meta/unsubscribe">> = Channel, ClientId, Subscription) ->  
    L = [{channel, Channel}, {clientId, ClientId}, {subscription, Subscription}],          
    case erlycomet_api:unsubscribe(ClientId, Subscription) of
        ok -> {struct, [{successful, true}  | L]};
        _ ->  {struct, [{successful, false}  | L]}
    end;  

process_data(<<$/, $s, $e, $r, $v, $i, $c, $e, $/, _/binary>> = Channel, ClientId, Data) ->  
    L = [{"channel", Channel}, {"clientId", ClientId}],
    case erlycomet_api:deliver_event(#event{channel=Channel, sender_id=ClientId, data=Data}) of
        ok -> {struct, [{"successful", true}  | L]};
        _ ->  {struct, [{"successful", false}  | L]}
    end;   
             
process_data(Channel, ClientId, Data) ->
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


loop(#state{messages=Msgs} = State) ->   
    receive
        stop ->
            disconnect(State);
        {add, Event} -> 
            loop(State#state{messages=[event_to_json_struct(Event) | Msgs]});
        {flush, Event} ->
            send(State#state{messages=[event_to_json_struct(Event) | Msgs]});
        flush -> 
            send(State)
    after State#state.timeout ->
		disconnect(State)
    end.

event_to_json_struct(#event{channel=C, data=D}) ->
	{struct, [{channel, C}, {data, D}]}.

send(#state{messages=Msgs, callback=Callback}) ->
    Data = callback_wrapper(json_encode(lists:reverse(Msgs)), Callback),
	send(Data);
send(Data) ->
	YawsPid = self(),
	spawn(fun() ->
				% Since we won't recover from send failure we can simply use an asynchronous send
				%~ case yaws_api:stream_chunk_deliver_blocking(YawsPid, Data) of
					%~ ok -> ok;
					%~ {error, _Rsn} ->
						%~ exit(connection_reset_by_peer)
				%~ end,
				yaws_api:stream_chunk_deliver(YawsPid, Data),
				yaws_api:stream_chunk_end(YawsPid)
			end),
	comet_return().
    
disconnect(#state{messages=Msgs, id=ClientId} = State) ->
    erlycomet_api:remove_connection(ClientId),
    Msg = {struct, [{channel, <<"/meta/disconnect">>}, {successful, true}, {clientId, ClientId}]},
	send(State#state{messages=[Msg | Msgs]}).
    
    
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
