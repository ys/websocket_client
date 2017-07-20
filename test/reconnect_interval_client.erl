-module(reconnect_interval_client).

-behaviour(websocket_client).

-export([
         start_link/1,
         stop/1
        ]).


-export([
         init/1,
         onconnect/2,
         ondisconnect/2,
         websocket_handle/3,
         websocket_info/3,
         websocket_terminate/3
        ]).

-record(state, {
          waiting = undefined :: undefined | pid()
         }).

start_link(Url) ->
    {ok, _} = websocket_client:start_link(Url, ?MODULE, [self()]).

stop(Pid) ->
    Pid ! stop.

init([Waiting]) ->
    {reconnect, #state{waiting=Waiting}}.

onconnect(_WSReq, State) ->
    State#state.waiting ! {ok, self()},
    {ok, State}.

ondisconnect(_Reason, State) ->
    {reconnect, 1000, State}.

websocket_handle(_, _, State) ->
    {ok, State}.

websocket_info(stop, _, State) ->
    {close, <<>>, State}.

websocket_terminate(_, _, _) ->
    ok.
