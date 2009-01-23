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
-module(erlycomet_yaws_request, [CustomAppModule]).
-author('telarson@gmail.com').
-author('rsaccon@gmail.com').


%% API
-export([handle/1]).

-include("erlycomet.hrl").
-include_lib("yaws/include/yaws_api.hrl").

-record(state, {
    id = undefined,
    connection_type,
    events = [],
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
	Timeout = infinity,
	handle(Arg, Req#http_request.method, Timeout).
        
handle(Arg, 'POST', Timeout) ->
    handle2(yaws_api:parse_post(Arg), Timeout);
handle(Arg, 'GET', Timeout) ->
    handle2(yaws_api:parse_query(Arg), Timeout).
	
handle2([{"message", Msg}, {"jsonp", Callback} | _], Timeout) ->
	YawsWorkerPid = self(),
	spawn(fun() ->
		case process_bayeux_msg(YawsWorkerPid, json_decode(Msg), Callback) of
			done -> ok;
			[done] -> ok;
			Body -> 
				Resp = callback_wrapper(json_encode(Body), Callback),
				send(YawsWorkerPid, Resp)
		end
	  end),
	{streamcontent_with_timeout, "application/octet-stream", <<>>, Timeout};
handle2([{"message", Msg} | _], Timeout) ->
	YawsWorkerPid = self(),
	spawn(fun() ->
		case process_bayeux_msg(YawsWorkerPid, json_decode(Msg), undefined) of
			done -> ok;
			[done] -> ok;
			Body -> send(YawsWorkerPid, json_encode(Body))
		end
	  end),
	{streamcontent_with_timeout, "application/octet-stream", <<>>, Timeout};
handle2([{Msg, undefined}], Timeout) ->
	YawsWorkerPid = self(),
	spawn(fun() ->
		case process_bayeux_msg(YawsWorkerPid, json_decode(Msg), undefined) of
			done -> ok;
			[done] -> ok;
			Body -> send(YawsWorkerPid, json_encode(Body))
		end
	  end),
	{streamcontent_with_timeout, "application/octet-stream", <<>>, Timeout};
handle2(_, _) ->
	[{status, 404}, {content, "text/html", "Nop."}].

%%====================================================================
%% Internal functions
%%====================================================================

process_bayeux_msg(YPid, JsonObj, Callback) ->
    case JsonObj of   
        Array when is_list(Array) -> 
            Out  = [ process_msg(YPid, X, Callback) || X <- Array ],
            Out1 = [ Msg || {comment, Msg} <- Out],
            case Out1 of 
                [] -> Out;
                _ -> {comment, Out1}
            end;
        Struct-> 
            process_msg(YPid, Struct, Callback)
    end.


process_msg(YPid, Struct, Callback) ->
    process_cmd(YPid, get_json_map_val(<<"channel">>, Struct), Struct, Callback).


get_json_map_val(Key, {struct, Pairs}) when is_list(Pairs) ->
    case [ V || {K, V} <- Pairs, K =:= Key] of
        [] -> undefined;
        [ V | _Rest ] -> V
    end;
get_json_map_val(_, _) ->
    undefined.
    

process_cmd(_YPid, <<"/meta/handshake">> = Channel, Struct, _) ->  
    % Advice = {struct, [{reconnect, "retry"},
    %                   {interval, 5000}]},
    % - get the alert from 
    Ext = get_json_map_val(<<"ext">>, Struct),
    CF = case get_json_map_val(<<"json-comment-filtered">>, Ext) of
        true -> true;
        _ -> false
    end,
    Id = generate_id(),
    erlycomet_api:replace_connection(Id, 0, handshake, CF),
    Ext1 = {struct, [{'json-comment-filtered', CF}]}, %not sure if this is necessary
    JsonResp = {struct, [
        {channel, Channel}, 
        {version, 1.0},
        {supportedConnectionTypes, [
            <<"long-polling">>,
            <<"callback-polling">>]},
        {clientId, Id},
        {successful, true},
        {ext, Ext1}]},
    % Resp2 = [{advice, Advice} | Resp],
    comment_filter(JsonResp, CF);
    
process_cmd(YPid, <<"/meta/connect">> = Channel, Struct, Callback) ->  
    ClientId = get_json_map_val(<<"clientId">>, Struct),
    ConnectionType = get_json_map_val(<<"connectionType">>, Struct),
    L = [{channel,  Channel}, {clientId, ClientId}],
    case erlycomet_api:replace_connection(ClientId, self(), connected) of
        {ok, Status} when Status =:= ok ; Status =:= replaced_hs ->
            comment_filter({struct, [{successful, true} | L]}, erlycomet_api:connection(ClientId));
            % don't reply immediately to new connect message.
            % instead wait. when new message is received, reply to connect and 
            % include the new message.  This is acceptable given bayeux spec. see section 4.2.2
        {ok, replaced} ->   
            Msg  = {struct, [{successful, true} | L]},
			State = #state{id = ClientId, connection_type = ConnectionType, events = [Msg], callback = Callback},
			loop(YPid, State);
        _ ->
            comment_filter({struct, [{successful, false} | L]}, erlycomet_api:connection(ClientId))
    end;    
           
process_cmd(_YPid, <<"/meta/disconnect">> = Channel, Struct, _) ->  
    ClientId = get_json_map_val(<<"clientId">>, Struct),
    process_cmd1(Channel, ClientId);
    
process_cmd(_YPid, <<"/meta/subscribe">> = Channel, Struct, _) ->   
    ClientId = get_json_map_val(<<"clientId">>, Struct),
    Subscription = get_json_map_val(<<"subscription">>, Struct),
    process_cmd1(Channel, ClientId, Subscription);
    
process_cmd(_YPid, <<"/meta/unsubscribe">> = Channel, Struct, _) -> 
    ClientId = get_json_map_val(<<"clientId">>, Struct),
    Subscription = get_json_map_val(<<"subscription">>, Struct),
    process_cmd1(Channel, ClientId, Subscription);   
          
process_cmd(_YPid, Channel, Struct, _) ->
    ClientId = get_json_map_val(<<"clientId">>, Struct),
    Data = get_json_map_val(<<"data">>, Struct),
    process_cmd1(Channel, ClientId, rpc(Data, Channel)).   
    
    
process_cmd1(Channel, undefined) ->
    {struct, [{<<"channel">>, Channel}, {successful, false}]};       
process_cmd1(Channel, Id) ->
    comment_filter(process_cmd2(Channel, Id), erlycomet_api:connection(Id)).

process_cmd1(Channel, undefined, _) ->   
    {struct, [{<<"channel">>, Channel}, {successful, false}]};  
process_cmd1(Channel, Id, Data) ->
    comment_filter(process_cmd2(Channel, Id, Data), erlycomet_api:connection(Id)).
       
        
process_cmd2(<<"/meta/disconnect">> = Channel, ClientId) -> 
    L = [{channel, Channel}, {clientId, ClientId}],
    case erlycomet_api:remove_connection(ClientId) of
        ok -> {struct, [{successful, true}  | L]};
        _ ->  {struct, [{successful, false}  | L]}
    end. 
    
                     
process_cmd2(<<"/meta/subscribe">> = Channel, ClientId, Subscription) ->    
    L = [{channel, Channel}, {clientId, ClientId}, {subscription, Subscription}],
    case erlycomet_api:subscribe(ClientId, Subscription) of
        ok -> {struct, [{successful, true}  | L]};
        _ ->  {struct, [{successful, false}  | L]}
    end;  
         
process_cmd2(<<"/meta/unsubscribe">> = Channel, ClientId, Subscription) ->  
    L = [{channel, Channel}, {clientId, ClientId}, {subscription, Subscription}],          
    case erlycomet_api:unsubscribe(ClientId, Subscription) of
        ok -> {struct, [{successful, true}  | L]};
        _ ->  {struct, [{successful, false}  | L]}
    end;  
    
process_cmd2(<<$/, $s, $e, $r, $v, $i, $c, $e, $/, _/binary>> = Channel, ClientId, Data) ->  
    L = [{"channel", Channel}, {"clientId", ClientId}],
    case erlycomet_api:deliver_to_connection(ClientId, Channel, Data) of
        ok -> {struct, [{"successful", true}  | L]};
        _ ->  {struct, [{"successful", false}  | L]}
    end;   
             
process_cmd2(Channel, ClientId, Data) ->  
    L = [{channel, Channel}, {clientId, ClientId}],
    case erlycomet_api:deliver_to_channel(Channel, Data) of
        ok -> {struct, [{successful, true}  | L]};
        _ ->  {struct, [{successful, false}  | L]}
    end.


json_decode(Str) ->
    mochijson2:decode(comment_filter_decode(Str)).
    
json_encode({comment, Body}) ->
    comment_filter_encode(mochijson2:encode(Body));
json_encode(Body) ->
    mochijson2:encode(Body).


callback_wrapper(Data, undefined) ->
    Data;       
callback_wrapper(Data, Callback) ->
    lists:concat([Callback, "(", Data, ");"]).
    

comment_filter_decode(Str) ->
    case Str of 
        "/*" ++ Rest ->
            case lists:reverse(Rest) of
                "/*" ++ Rest2 -> lists:reverse(Rest2);
                _ -> Str
            end;
        _ ->
            Str
    end.
    

comment_filter_encode(Str) ->    
    lists:concat(["/*", Str, "*/"]).


comment_filter(Data, #connection{comment_filtered=CF}=_Row) ->
    comment_filter(Data, CF);
comment_filter(Data, true) ->
    {comment, Data};
comment_filter(Data, _) ->
    Data.
     
                
generate_id() ->
    <<Num:128>> = crypto:rand_bytes(16),
    [HexStr] = io_lib:fwrite("~.16B",[Num]),
    case erlycomet_api:connection_pid(HexStr) of
        undefined ->
            HexStr;
    _ ->
        generate_id()
    end.


loop(YPid, #state{events=Events, id=Id, callback=Callback} = State) ->   
    receive
        stop ->
            disconnect(YPid, Id, State);
        {add, Event} -> 
            loop(YPid, State#state{events=[Event | Events]});      
        {flush, Event} -> 
            Events2 = [Event | Events],
            send(YPid, events_to_json_struct(Events2, Id), Callback),
            done;                
        flush -> 
            send(YPid, events_to_json_struct(Events, Id), Callback),
            done 
    after State#state.timeout ->
        disconnect(YPid, Id, Callback)
    end.


events_to_json_struct(Events, Id) ->
    comment_filter(lists:reverse(Events), erlycomet_api:connection(Id)).
  
    
send(YPid, Data, Callback) ->
    Chunk = callback_wrapper(json_encode(Data), Callback),
	send(YPid, Chunk).

send(YPid, Data) ->
    yaws_api:stream_chunk_deliver(YPid, Data),
	yaws_api:stream_chunk_end(YPid).
    
disconnect(YPid, Id, Callback) ->
    erlycomet_api:remove_connection(Id),
    Msg = {struct, [{channel, <<"/meta/disconnect">>}, {successful, true}, {clientId, Id}]},
    Msg2 = comment_filter(Msg, erlycomet_api:connection(Id)),
    Chunk = callback_wrapper(json_encode(Msg2), Callback),
	yaws_api:stream_chunk_deliver(YPid, Chunk),
	yaws_api:stream_chunk_end(YPid),
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