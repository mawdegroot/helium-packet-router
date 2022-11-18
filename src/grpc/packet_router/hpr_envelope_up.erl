-module(hpr_envelope_up).

-include("../autogen/server/packet_router_pb.hrl").

-export([
    new/1,
    data/1,
    to_map/1
]).

-type envelope() :: #envelope_up_v1_pb{}.

-export_type([envelope/0]).

-spec new(hpr_packet_up:packet() | hpr_register:register()) -> envelope().
new(#packet_router_register_v1_pb{} = Reg) ->
    #envelope_up_v1_pb{data = {register, Reg}};
new(#packet_router_packet_up_v1_pb{} = Packet) ->
    #envelope_up_v1_pb{data = {packet, Packet}}.

-spec data(Env :: envelope()) ->
    {register, hpr_register:register()} | {packet, hpr_packet_up:packet()}.
data(Env) ->
    Env#envelope_up_v1_pb.data.

-spec to_map(Env :: envelope()) -> map().
to_map(Env) ->
    client_packet_router_pb:decode_msg(
        packet_router_pb:encode_msg(Env, envelope_up_v1_pb),
        envelope_up_v1_pb
    ).

%% ------------------------------------------------------------------
%% EUnit tests
%% ------------------------------------------------------------------
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

new_test() ->
    Packet = hpr_packet_up:new(#{}),
    ?assertEqual(#envelope_up_v1_pb{data = {packet, Packet}}, ?MODULE:new(Packet)),
    ok.

data_test() ->
    Packet = hpr_packet_up:new(#{}),
    EnvUp = ?MODULE:new(Packet),
    ?assertEqual({packet, Packet}, ?MODULE:data(EnvUp)),
    ok.

to_map_test() ->
    Packet = hpr_packet_up:new(#{}),
    EnvUp = ?MODULE:new(Packet),
    ?assertEqual(
        #{
            data =>
                {packet, hpr_packet_up:to_map(Packet)}
        },
        ?MODULE:to_map(EnvUp)
    ),
    ok.

-endif.
