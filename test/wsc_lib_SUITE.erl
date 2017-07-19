-module(wsc_lib_SUITE).

-compile([export_all]).

-include_lib("proper/include/proper.hrl").
-include_lib("common_test/include/ct.hrl").
-include("../src/websocket_req.hrl").

-define(PROPTEST(M,F), true = proper:quickcheck(M:F())).

all() ->
    [
     t_prop_single_frame_codec,
     t_prop_mask,
     t_prop_batched_binaries
    ].

suite() ->
    [{ct_hooks,[cth_surefire]}, {timetrap, {seconds, 30}}].

init_per_suite(Config) ->
    {Protocol, Host, Port, Path} = {tcp, "localhost", 8080, "/"},
    Transport = #transport{
                   mod = gen_tcp,
                   name = tcp,
                   closed = tcp_closed,
                   error = tcp_error,
                   opts = [
                           binary,
                           {active, true},
                           {packet, 0}
                          ]},
    WSReq = websocket_req:new(
                Protocol, Host, Port, Path,
                Transport, wsc_lib:generate_ws_key()),
    [{wsreq, WSReq} | Config].

end_per_suite(_Config) -> ok.


t_prop_mask(_) ->
    proper:quickcheck(prop_mask()) orelse
        ct:fail(proper:counterexample()).
prop_mask() ->
    ?FORALL({MaskBin, Payload}, {binary(4), binary()},
            begin
                << Mask:32 >> = MaskBin,
                Payload =:= wsc_lib:mask_payload(Mask, wsc_lib:mask_payload(Mask, Payload))
            end).

t_prop_single_frame_codec(_) ->
    proper:quickcheck(prop_single_frame_codec()) orelse
        ct:fail(proper:counterexample()).
prop_single_frame_codec() ->
    WSReq = wsreq(),
    ?FORALL({Type, Payload}, {oneof([text, binary, ping, pong]), binary()},
            begin
                Encoded = wsc_lib:encode_frame({Type, Payload}),
                case wsc_lib:decode_frame(WSReq, Encoded) of 
                    {frame, {Type, Payload}, #websocket_req{}, <<>>} -> true;
                    _ -> false
                end
            end).

t_prop_batched_binaries(_) ->
    proper:quickcheck(prop_batched_binaries()) orelse
        ct:fail(proper:counterexample()).
prop_batched_binaries() ->
    WSReq = wsreq(),
    ?FORALL(Messages, non_empty(list({oneof([text, binary, ping, pong]), binary()})),
            begin
                Encoded = [wsc_lib:encode_frame(Msg) || Msg <- Messages],
                Batch = list_to_binary(Encoded),
                {frames, Decoded, _WSReq1} = maybe_frames(WSReq, Batch, []),
                Messages == Decoded
            end).

maybe_frames(WSReq0, Payload, Frames) ->
    % {recv, websocket_req:req(), IncompleteFrame :: binary()}
    % | {frame, {OpcodeName :: atom(), Payload :: binary()},
    %                websocket_req:req(), Rest :: binary()}
    % | {close, Reason :: term(), websocket_req:req()}.
    case wsc_lib:decode_frame(WSReq0, Payload) of
        {close, Reason, WSReq1} ->
            % Anything that might be left is discarded
            % But anything received before is processed
            {frames, lists:reverse([{close, Reason} | Frames]), WSReq1};
        {recv, WSReq1, Incomplete} ->
            {frames, lists:reverse([{recv, Incomplete} | Frames]), WSReq1};
        {frame, Frame, WSReq1, <<>>} ->
            {frames, lists:reverse([Frame|Frames]), WSReq1};
        {frame, Frame, WSReq1, Buffer} ->
            maybe_frames(WSReq1, Buffer, [Frame | Frames])
    end.



wsreq() ->
    {Protocol, Host, Port, Path} = {tcp, "localhost", 8080, "/"},
    Transport = #transport{
                   mod = gen_tcp,
                   name = tcp,
                   closed = tcp_closed,
                   error = tcp_error,
                   opts = [
                           binary,
                           {active, true},
                           {packet, 0}
                          ]},
    websocket_req:new(
      Protocol, Host, Port, Path,
      Transport, wsc_lib:generate_ws_key()).
