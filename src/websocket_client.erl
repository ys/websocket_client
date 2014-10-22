-module(websocket_client).
%% @author Jeremy Ong
%% @author Michael Coles
%% @doc Erlang websocket client (FSM implementation)

-behaviour(gen_fsm).
%-compile([export_all]).

-include("websocket_req.hrl").

-export([start_link/3]).
-export([cast/2]).
-export([send/2]).

-export([init/1]).
-export([terminate/3]).
-export([handle_event/3]).
-export([handle_sync_event/4]).
-export([handle_info/3]).
-export([code_change/4]).

% States
-export([disconnected/2]).
-export([disconnected/3]).
-export([connected/2]).
-export([connected/3]).
-export([handshaking/2]).
-export([handshaking/3]).

-type state_name() :: atom().

-type state() :: any().
-type keepalive() :: integer().
-type close_type() :: normal | error | remote.

-callback init(list()) ->
    {ok, state()}
        | {ok, state(), keepalive()}.

-callback onconnect(websocket_req:req(), state()) ->
    {ok, state()}
        | {reply, websocket_req:frame(), state()}
        | {close, binary(), state()}.

-callback websocket_handle({text | binary | ping | pong, binary()}, websocket_req:req(), state()) ->
    {ok, state()}
        | {reply, websocket_req:frame(), state()}
        | {close, binary(), state()}.

-callback websocket_info(any(), websocket_req:req(), state()) ->
    {ok, state()}
        | {reply, websocket_req:frame(), state()}
        | {close, binary(),  state()}.

-callback websocket_terminate({close_type(), term()} | {close_type(), integer(), binary()},
                              websocket_req:req(), state()) ->
    ok.

-record(context,
        {
         wsreq     :: websocket_req:req(),
         transport :: #transport{},
         headers   :: list({string(), string()}),
         target    :: {Proto :: ws | wss,
                      Host :: string(), Port :: non_neg_integer(),
                      Path :: string()},
         handler   :: {module(), HState :: term()},
         buffer = <<>> :: binary()
        }).

%% @doc Start the websocket client
-spec start_link(URL :: string(), Handler :: module(), Args :: list()) ->
    {ok, pid()} | {error, term()}.
start_link(URL, Handler, Args) ->
    start_link(URL, Handler, Args, []).

start_link(URL, Handler, HandlerArgs, AsyncStart) when is_boolean(AsyncStart) ->
    start_link(URL, Handler, HandlerArgs, [{async_start, AsyncStart}]);
start_link(URL, Handler, HandlerArgs, Opts) when is_list(Opts) ->
    case http_uri:parse(URL, [{scheme_defaults, [{ws,80},{wss,443}]}]) of
        {ok, {Protocol, _, Host, Port, Path, Query}} ->
            InitArgs = [Protocol, Host, Port, Path ++ Query, Handler, HandlerArgs, Opts],
            %FsmOpts = [{dbg, [trace]}],
            FsmOpts = [],
            gen_fsm:start_link(?MODULE, InitArgs, FsmOpts);
        {error, _} = Error ->
            Error
    end.

send(Client, Frame) ->
    gen_fsm:sync_send_event(Client, {send, Frame}).

%% Send a frame asynchronously
-spec cast(Client :: pid(), websocket_req:frame()) -> ok.
cast(Client, Frame) ->
    gen_fsm:send_event(Client, {cast, Frame}).

-spec init(list(any())) ->
    {ok, state_name(), #context{}}
    %% NB DO NOT try to use Timeout to do keepalive.
    | {stop, Reason :: term()}.
init([Protocol, Host, Port, Path, Handler, HandlerArgs, Opts]) ->
    {ok, HState} = Handler:init(HandlerArgs), %% TODO More rigorous checks of return values
                                       %% e.g. {error, Reason}
    AsyncStart = proplists:get_value(async_start, Opts, false),
    Transport =
        case Protocol of
            wss ->
                #transport{
                   mod = ssl,
                   name = ssl,
                   closed = ssl_closed,
                   error = ssl_error,
                   opts = [
                           {mode, binary},
                           {active, AsyncStart},
                           {verify, verify_none},
                           {packet, 0}
                          ]};
            ws  ->
                #transport{
                    mod = gen_tcp,
                    name = tcp,
                    closed = tcp_closed,
                    error = tcp_error,
                    opts = [
                            binary,
                            {active, AsyncStart},
                            {packet, 0}
                           ]}
        end,
    WSReq = websocket_req:new(
                Protocol, Host, Port, Path,
                undefined, Transport,
                generate_ws_key()
            ),
    Context0 = #context{
                  transport = Transport,
                  headers = proplists:get_value(extra_headers, Opts, []),
                  wsreq   = WSReq,
                  target  = {Protocol, Host, Port, Path},
                  handler = {Handler, HState}
                 },
    if AsyncStart ->
           %% In async start mode, we return as quickly as possible, letting handshaking
           %% etc happen in the background
           gen_fsm:send_event(self(), connect),
           {ok, disconnected, Context0};
       true ->
           %% In synchronous start mode, we need to connect and handshake before we return
           %% control to the caller - also switch back to active mode for the socket
           case connect(Context0) of
               {error, ConnErr}->
                   {stop, ConnErr};
               {ok, #context{wsreq=WSReq1}=Context1} ->
                   case wait_for_handshake(WSReq1) of
                       {ok, Data} -> {ok, connected, Context1#context{buffer=Data}};
                       {error, HSErr}->
                           {stop, HSErr}
                   end
           end
    end.

-spec terminate(Reason :: term(), state_name(), #context{}) -> ok.
%% TODO Use Reason!!
terminate(_Reason, _StateName, #context{wsreq=undefined}) ->
    ok;
terminate(_Reason, _StateName,
          #context{
             transport=T,
             wsreq=WSReq
            }) ->
    case websocket_req:socket(WSReq) of
        undefined -> ok;
        Socket ->
            _ = (T#transport.mod):close(Socket)
    end,
    ok.

connect(TranspMod, Host, Port, TranspOpts, Timeout) ->
    TranspMod:connect(Host, Port, TranspOpts, Timeout).

connect(#context{
           transport=T,
           wsreq=WSReq0,
           headers=Headers,
           handler={Handler, HState0},
           target={_Protocol, Host, Port, _Path}
          }=Context) ->
    case connect(T#transport.mod, Host, Port, T#transport.opts, 6000) of
        {ok, Socket} ->
            WSReq1 = websocket_req:socket(Socket, WSReq0),
            {ok, HStateN, KeepAlive} =
                case Handler:onconnect(WSReq1, HState0) of
                    {ok, HState1} -> {ok, HState1, infinity};
                    {ok, _HS1, KA}=Result ->
                        erlang:send_after(KA, self(), keepalive),
                        Result
                end,
            WSReq2 = websocket_req:keepalive(KeepAlive, WSReq1),
            ok = send_handshake(WSReq2, Headers),
            {ok, Context#context{ handler={Handler, HStateN}, wsreq=WSReq2}};
        {error,_}=Error ->
            Error
    end.

%% TODO Split verify/validate out and don't hide the logic!
wait_for_handshake(WSReq) ->
    wait_for_handshake(<<>>, WSReq).
wait_for_handshake(Buffer, #websocket_req{
                      socket=Socket,
                      transport=T
                     }=WSReq) ->
    %% TODO Find a graceful way to handle gen_tcp/ssl/inet module diffs
    OptMod = case T#transport.mod of
                 gen_tcp -> inet;
                 ssl -> ssl
             end,
    OptMod:setopts(Socket, [{active, false}]),
    case (T#transport.mod):recv(Socket, 0, 6000) of
        {ok, Data} ->
            case verify_handshake(<< Buffer/binary, Data/binary >>, WSReq) of
                {error, _}=VerifyError -> VerifyError;
                {notfound, Remainder} ->
                    wait_for_handshake(Remainder, WSReq);
                {ok, Remainder} -> 
                    ok = OptMod:setopts(Socket, [{active, true}]),
                    {ok, Remainder}
            end;
        {error, _}=RecvError ->
            RecvError
    end.

verify_handshake(Data, WSReq) ->
    case re:run(Data, "\\r\\n\\r\\n") of
        {match, _} ->
            case validate_handshake(Data, websocket_req:key(WSReq)) of
                {error,_}=Error ->
                    Error;
                {ok, Remaining} ->
                    %% TODO This is nasty and hopefully there's a nicer way
                    {ok, Remaining}
            end;
        _ ->
            {notfound, Data}
    end.

-spec handle_event(Event :: term(), state_name(), #context{}) ->
    {next_state, state_name(), #context{}}
    | {stop, Reason :: term(), #context{}}.
handle_event(_Event, State, Context) ->
    {next_state, State, Context}. %% i.e. ignore, do nothing

-spec handle_sync_event(Event :: term(), From :: pid(), state_name(), #context{}) ->
    {next_state, state_name(), #context{}}
    | {reply, Reply :: term(), state_name(), #context{}}
    | {stop, Reason :: term(), #context{}}
    | {stop, Reason :: term(), Reply :: term(), #context{}}.
handle_sync_event(Event, {_From, Tag}, State, Context) ->
    {reply, {noop, Event, Tag}, State, Context}.

-spec handle_info(Info :: term(), state_name(), #context{}) ->
    {next_state, state_name(), #context{}}
    | {stop, Reason :: term(), #context{}}.
handle_info(keepalive, KAState, #context{ wsreq=WSReq }=Context)
  when KAState =:= handshaking; KAState =:= connected ->
    [KeepAlive, KATimer] =
        websocket_req:get([keepalive, keepalive_timer], WSReq),
    case KATimer of
        undefined -> ok;
        _ -> erlang:cancel_timer(KATimer)
    end,
    ok = encode_and_send({ping, <<>>}, WSReq),
    NewTimer = erlang:send_after(KeepAlive, self(), keepalive),
    WSReq1 = websocket_req:set([{keepalive_timer, NewTimer}], WSReq),
    {next_state, KAState, Context#context{wsreq=WSReq1}};
%% TODO Move Socket into #transport{} from #websocket_req{} so that we can
%% match on it here
handle_info({TransClosed, _Socket}, _State,
            #context{
               transport=#transport{ closed=TransClosed },
               wsreq=WSReq,
               handler={Handler, HState0}
              }=Context) ->
    ok = websocket_close(WSReq, Handler, HState0, {remote, closed}),
    {stop, socket_closed, Context};
handle_info({TransError, _Socket, Reason},
            _AnyState,
            #context{
               transport=#transport{ error=TransError},
               handler={Handler, HState0},
               wsreq=WSReq
              }=Context) ->
    ok = websocket_close(WSReq, Handler, HState0, {TransError, Reason}),
    {stop, {socket_error, Reason}, Context};
handle_info({Trans, Socket, Data},
            handshaking,
            #context{
               transport=#transport{ name=Trans },
               wsreq=WSReq,
               buffer=Buffer
              }=Context) ->
    MaybeHandshakeResp = << Buffer/binary, Data/binary >>,
    case re:run(MaybeHandshakeResp, "\\r\\n\\r\\n") of
        {match, _} ->
            % TODO: I don't think state transitions should happen from handle_info
            case validate_handshake(MaybeHandshakeResp, websocket_req:key(WSReq)) of
                {error,_}=Error ->
                    {stop, Error, Context};
                {ok, Remaining} ->
                    %% TODO This is nasty and hopefully there's a nicer way
                    self() ! {Trans, Socket, Remaining},
                    {next_state, connected, Context#context{buffer = <<>>}}
            end;
        _ ->
            {next_state, handshaking, Context#context{buffer=MaybeHandshakeResp}}
    end;
handle_info({Trans, _Socket, Data},
            connected,
            #context{
               transport=#transport{ name=Trans },
               handler={Handler, HState0},
               wsreq=WSReq,
               buffer=Buffer
              }=Context) ->
    {ok, WSReqN, HStateN, BufferN} =
    Result =
        case websocket_req:remaining(WSReq) of
            undefined ->
                retrieve_frame(WSReq, Handler, HState0,
                               << Buffer/binary, Data/binary >>);
            Remaining ->
                retrieve_frame(WSReq, Handler, HState0,
                               websocket_req:opcode(WSReq), Remaining, Data, Buffer)
        end,
    case Result of
        {ok, WSReqN, HStateN, BufferN} ->
            {next_state, connected, Context#context{
                                      handler={Handler, HStateN},
                                      wsreq=WSReqN,
                                      buffer=BufferN}};
        {close, Reason, WSReqN, Handler, HStateN} ->
            {stop, Reason, Context#context{
                             wsreq=WSReqN, 
                             handler={Handler, HStateN}}}
    end;
handle_info(Msg, State,
            #context{
               wsreq=WSReq,
               handler={Handler, HState0},
               buffer=Buffer
              }=Context) ->
    try Handler:websocket_info(Msg, WSReq, HState0) of
        HandlerResponse ->
            case handle_response(HandlerResponse, Handler, Buffer, WSReq) of
                {ok, WSReqN, HStateN, BufferN} ->
                    {next_state, State, Context#context{
                                          handler={Handler, HStateN},
                                          wsreq=WSReqN,
                                          buffer=BufferN}};
                {close, Reason, WSReqN, Handler, HStateN} ->
                    {stop, Reason, Context#context{
                                     wsreq=WSReqN,
                                     handler={Handler, HStateN}}}
            end
    catch Class:Reason ->
        %% TODO Maybe a function_clause catch here to allow
        %% not having to have a catch-all clause in websocket_info CB?
        error_logger:error_msg(
          "** Websocket client ~p terminating in ~p/~p~n"
          "   for the reason ~p:~p~n"
          "** Last message was ~p~n"
          "** Handler state was ~p~n"
          "** Stacktrace: ~p~n~n",
          [Handler, websocket_info, 3, Class, Reason, Msg, HState0,
           erlang:get_stacktrace()]),
        websocket_close(WSReq, Handler, HState0, Reason),
        {stop, Reason, Context}
    end.

-spec code_change(OldVsn :: term(), state_name(), #context{}, Extra :: any()) ->
    {ok, state_name(), #context{}}.
code_change(_OldVsn, StateName, Context, _Extra) ->
    {ok, StateName, Context}.

disconnected(connect, Context0) ->
    case connect(Context0) of
        {ok, Context1} ->
            {next_state, handshaking, Context1};
        {error,_}=Error ->
            {stop, Error, Context0}
    end.

disconnected(connect, _From, Context0) ->
    case connect(Context0) of
        {ok, Context1} ->
            {reply, ok, handshaking, Context1};
        {error,_}=Error ->
            {reply, Error, disconnected, Context0}
    end;
disconnected(_Event, _From, Context) -> {stop, unhandled_sync_event, Context}.


connected({cast, Frame}, #context{wsreq=WSReq}=Context) ->
    ok = encode_and_send(Frame, WSReq),
    {next_state, connected, Context}.

connected({send, Frame}, _From, #context{wsreq=WSReq}=Context) ->
    {reply, encode_and_send(Frame, WSReq), connected, Context};
connected(_Event, _From, Context) ->
    {reply, {error, unhandled_sync_event}, connected, Context}.

handshaking(_Event, Context) ->
    {next_state, handshaking, Context}.
handshaking(_Event, _From, Context) ->
    {reply, {error, unhandled_sync_event}, handshaking, Context}.

%% @doc Key sent in initial handshake
-spec generate_ws_key() ->
                             binary().
generate_ws_key() ->
    base64:encode(crypto:rand_bytes(16)).

%% @doc Send http upgrade request and validate handshake response challenge
-spec send_handshake(WSReq :: websocket_req:req(), [{string(), string()}]) ->
    {ok, binary()}
    | {error, term()}.
send_handshake(WSReq, ExtraHeaders) ->
    [Protocol, Path, Host, Key, Transport, Socket] =
        websocket_req:get([protocol, path, host, key, transport, socket], WSReq),
    Handshake = ["GET ", Path, " HTTP/1.1\r\n"
                 "Host: ", Host, "\r\n"
                 "Connection: Upgrade\r\n"
                 "Origin: ", atom_to_binary(Protocol, utf8), "://", Host, "\r\n"
                 "Sec-WebSocket-Version: 13\r\n"
                 "Sec-WebSocket-Key: ", Key, "\r\n"
                 "Upgrade: websocket\r\n",
                 [ [Header, ": ", Value, "\r\n"] || {Header, Value} <- ExtraHeaders],
                 "\r\n"],
    (Transport#transport.mod):send(Socket, Handshake).

%% @doc Send frame to server
encode_and_send(Frame, WSReq) ->
    [Socket, Transport] = websocket_req:get([socket, transport], WSReq),
    (Transport#transport.mod):send(Socket, encode_frame(Frame)).

%% @doc Encodes the data with a header (including a masking key) and
%% masks the data
-spec encode_frame(websocket_req:frame()) -> binary().
encode_frame({Type, Payload}) ->
    Opcode = websocket_req:name_to_opcode(Type),
    Len = iolist_size(Payload),
    BinLen = payload_length_to_binary(Len),
    MaskingKeyBin = crypto:rand_bytes(4),
    << MaskingKey:32 >> = MaskingKeyBin,
    Header = << 1:1, 0:3, Opcode:4, 1:1, BinLen/bits, MaskingKeyBin/bits >>,
    MaskedPayload = mask_payload(MaskingKey, Payload),
    << Header/binary, MaskedPayload/binary >>;
encode_frame(Type) when is_atom(Type) ->
    encode_frame({Type, <<>>}).

-spec websocket_close(WSReq :: websocket_req:req(),
                      Handler :: module(),
                      HandlerState :: any(),
                      Reason :: tuple()) -> ok.
websocket_close(WSReq, Handler, HandlerState, Reason) ->
    try
        Handler:websocket_terminate(Reason, WSReq, HandlerState)
    catch Class:Reason2 ->
      error_logger:error_msg(
        "** Websocket handler ~p terminating in ~p/~p~n"
        "   for the reason ~p:~p~n"
        "** Handler state was ~p~n"
        "** Stacktrace: ~p~n~n",
        [Handler, websocket_terminate, 3, Class, Reason2, HandlerState,
          erlang:get_stacktrace()])
    end.
%% TODO {stop, Reason, Context}

%% @doc Handles return values from the callback module
handle_response({reply, Frame, HandlerState}, Handler, Buffer, WSReq) ->
    case encode_and_send(Frame, WSReq) of
        ok ->
           %% we can still have more messages in buffer
           case websocket_req:remaining(WSReq) of
               %% buffer should not contain uncomplete messages
               undefined -> retrieve_frame(WSReq, Handler, HandlerState, Buffer);
               %% buffer contain uncomplete message that shouldnt be parsed
               _ -> {ok, WSReq, HandlerState, Buffer}
           end;
        Reason -> {close, Reason, WSReq, Handler, HandlerState}
    end;
handle_response({ok, HandlerState}, Handler, Buffer, WSReq) ->
    %% we can still have more messages in buffer
    case websocket_req:remaining(WSReq) of
        %% buffer should not contain uncomplete messages
        undefined -> retrieve_frame(WSReq, Handler, HandlerState, Buffer);
        %% buffer contain uncomplete message that shouldnt be parsed
        _ -> {ok, WSReq, HandlerState, Buffer}
    end;
handle_response({close, Payload, HandlerState}, Handler, _, WSReq) ->
    ok = encode_and_send({close, Payload}, WSReq),
    {close, normal, WSReq, Handler, HandlerState}.

%% @doc Validate handshake response challenge
-spec validate_handshake(HandshakeResponse :: binary(), Key :: binary()) -> {ok, binary()} | {error, term()}.
validate_handshake(HandshakeResponse, Key) ->
    Challenge = base64:encode(
                  crypto:hash(sha, << Key/binary, "258EAFA5-E914-47DA-95CA-C5AB0DC85B11" >>)),
    %% Consume the response...
    {ok, Status, Header, Buffer} = consume_response(HandshakeResponse),
    {_Version, Code, Message} = Status,
    case Code of
        % 101 means Switching Protocol
        101 ->
            %% ...and make sure the challenge is valid.
            case proplists:get_value(<<"Sec-Websocket-Accept">>, Header) of
                Challenge -> {ok, Buffer};
                _Invalid   -> {error, invalid_handshake}
            end;
        _ -> {error, {Code, Message}}
    end.

%% @doc Consumes the HTTP response and extracts status, header and the body.
consume_response(Response) ->
    {ok, {http_response, Version, Code, Message}, Header} =
        erlang:decode_packet(http_bin, Response, []),
    consume_response({Version, Code, Message}, Header, []).
consume_response(Status, Response, HeaderAcc) ->
    case erlang:decode_packet(httph_bin, Response, []) of
        {ok, {http_header, _Length, Field, _Reserved, Value}, Rest} ->
            consume_response(Status, Rest, [{Field, Value} | HeaderAcc]);
        {ok, http_eoh, Body} ->
            {ok, Status, HeaderAcc, Body}
    end.

%% @doc Start or continue continuation payload with length less than 126 bytes
retrieve_frame(WSReq, Handler, HState,
               << 0:4, Opcode:4, 0:1, Len:7, Rest/bits >>)
  when Len < 126 ->
    WSReq1 = set_continuation_if_empty(WSReq, Opcode),
    WSReq2 = websocket_req:fin(0, WSReq1),
    retrieve_frame(WSReq2, Handler, HState, Opcode, Len, Rest, <<>>);
%% @doc Start or continue continuation payload with length a 2 byte int
retrieve_frame(WSReq, Handler, HState,
               << 0:4, Opcode:4, 0:1, 126:7, Len:16, Rest/bits >>)
  when Len > 125, Opcode < 8 ->
    WSReq1 = set_continuation_if_empty(WSReq, Opcode),
    WSReq2 = websocket_req:fin(0, WSReq1),
    retrieve_frame(WSReq2, Handler, HState, Opcode, Len, Rest, <<>>);
%% @doc Start or continue continuation payload with length a 64 bit int
retrieve_frame(WSReq, Handler, HState,
               << 0:4, Opcode:4, 0:1, 127:7, 0:1, Len:63, Rest/bits >>)
  when Len > 16#ffff, Opcode < 8 ->
    WSReq1 = set_continuation_if_empty(WSReq, Opcode),
    WSReq2 = websocket_req:fin(0, WSReq1),
    retrieve_frame(WSReq2, Handler, HState, Opcode, Len, Rest, <<>>);
%% @doc Length is less 126 bytes
retrieve_frame(WSReq, Handler, HState,
               << 1:1, 0:3, Opcode:4, 0:1, Len:7, Rest/bits >>)
  when Len < 126 ->
    WSReq1 = websocket_req:fin(1, WSReq),
    retrieve_frame(WSReq1, Handler, HState, Opcode, Len, Rest, <<>>);
%% @doc Length is a 2 byte integer
retrieve_frame(WSReq, Handler, HState,
               << 1:1, 0:3, Opcode:4, 0:1, 126:7, Len:16, Rest/bits >>)
  when Len > 125, Opcode < 8 ->
    WSReq1 = websocket_req:fin(1, WSReq),
    retrieve_frame(WSReq1, Handler, HState, Opcode, Len, Rest, <<>>);
%% @doc Length is a 64 bit integer
retrieve_frame(WSReq, Handler, HState,
               << 1:1, 0:3, Opcode:4, 0:1, 127:7, 0:1, Len:63, Rest/bits >>)
  when Len > 16#ffff, Opcode < 8 ->
    WSReq1 = websocket_req:fin(1, WSReq),
    retrieve_frame(WSReq1, Handler, HState, Opcode, Len, Rest, <<>>);
%% @doc Need more data to read length properly
retrieve_frame(WSReq, _Handler, HState, Data) ->
    {ok, WSReq, HState, Data}.

%% @doc Length known and still missing data
retrieve_frame(WSReq, _Handler, HState, Opcode, Len, Data, Buffer)
  when byte_size(Data) < Len ->
    Remaining = Len - byte_size(Data),
    WSReq1 = websocket_req:remaining(Remaining, WSReq),
    WSReq2  = websocket_req:opcode(Opcode, WSReq1),
    {ok, WSReq2, HState, << Buffer/bits, Data/bits >>};
%% @doc Length known and remaining data is appended to the buffer
retrieve_frame(WSReq, Handler, HState, Opcode, Len, Data, Buffer) ->
    [Continuation, ContinuationOpcode] =
        websocket_req:get([continuation, continuation_opcode], WSReq),
    Fin = websocket_req:fin(WSReq),
    << Payload:Len/binary, Rest/bits >> = Data,
    FullPayload = << Buffer/binary, Payload/binary >>,
    OpcodeName = websocket_req:opcode_to_name(Opcode),
    case OpcodeName of
        ping ->
            %% If a ping is received, send a pong automatically
            ok = encode_and_send({pong, FullPayload}, WSReq);
        _ ->
            ok
    end,
    case OpcodeName of
        close when byte_size(FullPayload) >= 2 ->
            << CodeBin:2/binary, ClosePayload/binary >> = FullPayload,
            Code = binary:decode_unsigned(CodeBin),
            Reason = case Code of
                         1000 -> {normal, ClosePayload};
                         1002 -> {error, badframe, ClosePayload};
                         1007 -> {error, badencoding, ClosePayload};
                         1011 -> {error, handler, ClosePayload};
                         _ -> {remote, Code, ClosePayload}
                     end,
            {close, Reason, WSReq, Handler, HState};
        close ->
            {close, {remote, <<>>}, WSReq, Handler, HState};
        %% Non-control continuation frame
        _ when Opcode < 8, Continuation =/= undefined, Fin == 0 ->
            %% Append to previously existing continuation payloads and continue
            Continuation1 = << Continuation/binary, FullPayload/binary >>,
            WSReq1 = websocket_req:continuation(Continuation1, WSReq),
            retrieve_frame(WSReq1, Handler, HState, Rest);
        %% Terminate continuation frame sequence with non-control frame
        _ when Opcode < 8, Continuation =/= undefined, Fin == 1 ->
            DefragPayload = << Continuation/binary, FullPayload/binary >>,
            WSReq1 = websocket_req:continuation(undefined, WSReq),
            WSReq2 = websocket_req:continuation_opcode(undefined, WSReq1),
            ContinuationOpcodeName = websocket_req:opcode_to_name(ContinuationOpcode),
            try Handler:websocket_handle(
                                {ContinuationOpcodeName, DefragPayload},
                                WSReq2, HState) of
              HandlerResponse ->
                handle_response(HandlerResponse,
                                Handler, Rest, websocket_req:remaining(undefined, WSReq1))
            catch Class:Reason ->
              error_logger:error_msg(
                "** Websocket client ~p terminating in ~p/~p~n"
                "   for the reason ~p:~p~n"
                "** Websocket message was ~p~n"
                "** Handler state was ~p~n"
                "** Stacktrace: ~p~n~n",
                [Handler, websocket_handle, 3, Class, Reason, {ContinuationOpcodeName, DefragPayload}, HState,
                  erlang:get_stacktrace()]),
              {close, Reason, WSReq, Handler, HState}
            end;
        _ ->
            try Handler:websocket_handle(
                                {OpcodeName, FullPayload},
                                WSReq, HState) of
              HandlerResponse ->
                handle_response(HandlerResponse,
                                Handler, Rest, websocket_req:remaining(undefined, WSReq))
            catch Class:Reason ->
              error_logger:error_msg(
                "** Websocket client ~p terminating in ~p/~p~n"
                "   for the reason ~p:~p~n"
                "** Handler state was ~p~n"
                "** Stacktrace: ~p~n~n",
                [Handler, websocket_handle, 3, Class, Reason, HState,
                  erlang:get_stacktrace()]),
              {close, Reason, WSReq, Handler, HState}
            end
    end.

%% @doc The payload is masked using a masking key byte by byte.
%% Can do it in 4 byte chunks to save time until there is left than 4 bytes left
mask_payload(MaskingKey, Payload) ->
    mask_payload(MaskingKey, Payload, <<>>).
mask_payload(_, <<>>, Acc) ->
    Acc;
mask_payload(MaskingKey, << D:32, Rest/bits >>, Acc) ->
    T = D bxor MaskingKey,
    mask_payload(MaskingKey, Rest, << Acc/binary, T:32 >>);
mask_payload(MaskingKey, << D:24 >>, Acc) ->
    << MaskingKeyPart:24, _:8 >> = << MaskingKey:32 >>,
    T = D bxor MaskingKeyPart,
    << Acc/binary, T:24 >>;
mask_payload(MaskingKey, << D:16 >>, Acc) ->
    << MaskingKeyPart:16, _:16 >> = << MaskingKey:32 >>,
    T = D bxor MaskingKeyPart,
    << Acc/binary, T:16 >>;
mask_payload(MaskingKey, << D:8 >>, Acc) ->
    << MaskingKeyPart:8, _:24 >> = << MaskingKey:32 >>,
    T = D bxor MaskingKeyPart,
    << Acc/binary, T:8 >>.

%% @doc Encode the payload length as binary in a variable number of bits.
%% See RFC Doc for more details
payload_length_to_binary(Len) when Len =<125 ->
    << Len:7 >>;
payload_length_to_binary(Len) when Len =< 16#ffff ->
    << 126:7, Len:16 >>;
payload_length_to_binary(Len) when Len =< 16#7fffffffffffffff ->
    << 127:7, Len:64 >>.

%% @doc If this is the first continuation frame, set the opcode and initialize
%% continuation to an empty binary. Otherwise, return the request object untouched.
-spec set_continuation_if_empty(WSReq :: websocket_req:req(),
                                Opcode :: websocket_req:opcode()) ->
                                       websocket_req:req().
set_continuation_if_empty(WSReq, Opcode) ->
    case websocket_req:continuation(WSReq) of
        undefined ->
            WSReq1 = websocket_req:continuation_opcode(Opcode, WSReq),
            websocket_req:continuation(<<>>, WSReq1);
        _ ->
            WSReq
    end.
