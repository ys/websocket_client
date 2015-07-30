-module(wsc_lib_SUITE).

-compile([export_all]).

-include_lib("proper/include/proper.hrl").
-include_lib("common_test/include/ct.hrl").
-include("../src/websocket_req.hrl").

-define(PROPTEST(M,F), true = proper:quickcheck(M:F())).

all() ->
    [
     t_prop_single_frame_codec,
     t_prop_mask
     %{group, codec}
    ].

suite() ->
    [{ct_hooks,[cth_surefire]}, {timetrap, {seconds, 30}}].

groups() ->
    [
     {codec, [],
      [
       t_prop_single_frame_codec
      ]}
    ].

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
                undefined, Transport,
                wsc_lib:generate_ws_key()
            ),
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
      undefined, Transport, wsc_lib:generate_ws_key()).
