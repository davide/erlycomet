%%%---------------------------------------------------------------------------------------
%%% @author     Roberto Saccon <rsaccon@gmail.com> [http://rsaccon.com]
%%% @author     Roberto Saccon <telarson@gmail.com>
%%% @copyright  2007 Roberto Saccon, Tait Larson
%%% @doc        gloabl server and mnesia broker
%%% @reference  See <a href="http://erlyvideo.googlecode.com" target="_top">http://erlyvideo.googlecode.com</a> for more information
%%% @end
%%%
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
%%%---------------------------------------------------------------------------------------
-module(erlycomet_api).
-author('rsaccon@gmail.com').
-author('telarson@gmail.com').
-include("erlycomet.hrl").
-include_lib("stdlib/include/qlc.hrl").


%% API
-export([add_connection/2,
         replace_connection/3,
         connections/0,
         connection/1,
         connection_pid/1,
         remove_connection/1,
         subscribe/2,
         unsubscribe/2,
         channels/0,
         deliver_to_connection/2,
         deliver_event/1]).

 

%%====================================================================
%% API
%%====================================================================
%%-------------------------------------------------------------------------
%% @spec (string(), pid()) -> ok | error 
%% @doc
%% adds a connection
%% @end
%%-------------------------------------------------------------------------
add_connection(ClientId, Pid) -> 
    E = #connection{client_id=ClientId, pid=Pid},
    F = fun() -> mnesia:write(E) end,
    case mnesia:transaction(F) of
        {atomic, ok} -> ok;
        _ -> error
    end.
 
%%-------------------------------------------------------------------------
%% @spec (string(), pid(), any()) -> {ok, new} | {ok, replaced} | error 
%% @doc
%% replaces a connection
%% @end
%%-------------------------------------------------------------------------
replace_connection(ClientId, Pid, NewState) -> 
    E = #connection{client_id=ClientId, pid=Pid, state=NewState},
    F1 = fun() -> mnesia:read({connection, ClientId}) end,
    {Status, F2} = case mnesia:transaction(F1) of
        {atomic, EA} ->
            case EA of
                [] ->
                    {new, fun() -> mnesia:write(E) end};
				[#connection{state=State}] ->
                    case State of
                        handshake ->
                            {replaced_hs, fun() -> mnesia:write(E) end};
                        _ ->
                            {replaced, fun() -> mnesia:write(E) end}
                    end
            end;
        _ ->
            {new, fun() -> mnesia:write(E) end}
    end,
    case mnesia:transaction(F2) of
        {atomic, ok} -> {ok, Status};
        _ -> error
    end.
       
          
%%--------------------------------------------------------------------
%% @spec () -> list()
%% @doc
%% returns list of connections
%% @end 
%%--------------------------------------------------------------------    
connections() -> 
    do(qlc:q([X || X <-mnesia:table(connection)])).
  
connection(ClientId) ->
    F = fun() -> mnesia:read({connection, ClientId}) end,
    case mnesia:transaction(F) of
        {atomic, Row} ->
            case Row of
                [] -> undefined;
                [Conn] -> Conn
            end;
        _ ->
            undefined
    end.


%%--------------------------------------------------------------------
%% @spec (string()) -> pid()
%% @doc 
%% returns the PID of a connection if it exists
%% @end 
%%--------------------------------------------------------------------    
connection_pid(ClientId) ->
    case connection(ClientId) of
        #connection{pid=Pid} -> Pid;
        undefined -> undefined
    end.    

%%--------------------------------------------------------------------
%% @spec (string()) -> ok | error  
%% @doc
%% removes a connection
%% @end 
%%--------------------------------------------------------------------  
remove_connection(ClientId) ->
    F = fun() -> mnesia:delete({connection, ClientId}) end,
    case mnesia:transaction(F) of
        {atomic, ok} -> ok;
        _ -> error
    end.    


%%--------------------------------------------------------------------
%% @spec (string(), string()) -> ok | error 
%% @doc
%% subscribes a client to a channel
%% @end 
%%--------------------------------------------------------------------
subscribe(ClientId, ChannelName) ->
    F = fun() ->
        Channel = case mnesia:read({channel, ChannelName}) of
            [] -> 
                #channel{name=ChannelName, client_ids=[ClientId]};
            [#channel{client_ids=[]}=Channel1] ->
                Channel1#channel{client_ids=[ClientId]};
            [#channel{client_ids=Ids}=Channel1] ->
                Channel1#channel{client_ids=[ClientId | Ids]}
        end,
        mnesia:write(Channel)
    end,
    case mnesia:transaction(F) of
        {atomic, ok} -> ok;
        _ -> error
    end.
    
    
%%--------------------------------------------------------------------
%% @spec (string(), string()) -> ok | error  
%% @doc
%% unsubscribes a client from a channel
%% @end 
%%--------------------------------------------------------------------
unsubscribe(ClientId, ChannelName) ->
    F = fun() ->
        case mnesia:read({channel, ChannelName}) of
            [] ->
                {error, channel_not_found};
            [#channel{client_ids=Ids}=Channel] ->
                mnesia:write(Channel#channel{client_ids = lists:delete(ClientId,  Ids)})
        end
    end,
    case mnesia:transaction(F) of
        {atomic, ok} -> ok;
        _ -> error
    end.


%%--------------------------------------------------------------------
%% @spec () -> list()
%% @doc
%% returns a list of channels
%% @end 
%%--------------------------------------------------------------------
channels() ->
    do(qlc:q([X || X <-mnesia:table(channel)])).


%%--------------------------------------------------------------------
%% @spec (string(), #event) -> ok | {error, connection_not_found} 
%% @doc
%% delivers data to one connection
%% @end 
%%--------------------------------------------------------------------  
deliver_to_connection(ClientId, Event) ->
    F = fun() -> mnesia:read({connection, ClientId}) end,
    case mnesia:transaction(F) of 
        {atomic, []} ->
            {error, connection_not_found};
        {atomic, [#connection{pid=Pid}]} ->
			io:format("Delivering ~p to ~p:~p.~n", [Event, ClientId, Pid]),
            Pid ! {flush, Event},
            ok
    end.
    

%%--------------------------------------------------------------------
%% @spec  (binary(), #event) -> ok | {error, channel_not_found} 
%% @doc
%% delivers data to all connections of a channel
%% @end 
%%--------------------------------------------------------------------
deliver_event(Event) ->
    globbing(fun deliver_to_single_channel/1, Event).
    

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

globbing(Fun, Event) ->
	Channel = Event#event.channel,
    case lists:reverse(binary_to_list(Channel)) of
        [$*, $* | T] ->
            lists:map(fun
                    (X) ->
                        case string:str(X, lists:reverse(T)) of
                            1 ->
                                Fun(Event);
                            _ -> 
                                skip
                        end                        
                end, channels());
        [$* | T] ->
            lists:map(fun
                    (X) ->
                        case string:str(X, lists:reverse(T)) of
                            1 -> 
                                Tokens = string:tokens(string:sub_string(X, length(T) + 1), "/"),
                                case Tokens of
                                    [_] ->
                                        Fun(Event);
                                    _ ->
                                        skip
                                end;
                            _ -> 
                                skip
                        end                        
                end, channels());
        _ ->
            Fun(Event)
    end.


deliver_to_single_channel(#event{channel=Channel} = Event) ->
    F = fun() -> mnesia:read({channel, Channel}) end,
    case mnesia:transaction(F) of 
        {atomic, [{channel, Channel, []}] } -> 
            ok;
        {atomic, [{channel, Channel, Ids}] } ->
            [send_event(connection_pid(ClientId), Event) || ClientId <- Ids],
            ok; 
        _ ->
            {error, channel_not_found}
     end.
     

send_event(Pid, Event) when is_pid(Pid)->
    Pid ! {flush, Event};
send_event(_, _) ->
    ok.


do(QLC) ->
    F = fun() -> qlc:e(QLC) end,
    {atomic, Val} = mnesia:transaction(F),
    Val.

