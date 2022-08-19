-module(hpr_routing_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    join_req_test/1
]).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

%%--------------------------------------------------------------------
%% COMMON TEST CALLBACK FUNCTIONS
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% @public
%% @doc
%%   Running tests for this suite
%% @end
%%--------------------------------------------------------------------
all() ->
    [
        join_req_test
    ].

%%--------------------------------------------------------------------
%% TEST CASE SETUP
%%--------------------------------------------------------------------
init_per_testcase(TestCase, Config) ->
    test_utils:init_per_testcase(TestCase, Config).

%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------
end_per_testcase(TestCase, Config) ->
    test_utils:end_per_testcase(TestCase, Config).

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

join_req_test(_Config) ->
    Self = self(),

    #{secret := PrivKey, public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
    SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
    Hotspot = libp2p_crypto:pubkey_to_bin(PubKey),

    JoinPacketBadSig = test_utils:join_packet_up(#{
        hotspot => Hotspot, sig_fun => fun(_) -> <<"bad_sig">> end
    }),
    ?assertEqual({error, bad_signature}, hpr_routing:handle_packet(JoinPacketBadSig, Self)),

    JoinPacketUpInvalid = test_utils:join_packet_up(#{
        hotspot => Hotspot, sig_fun => SigFun, payload => <<>>
    }),
    ?assertEqual(
        {error, invalid_packet_type}, hpr_routing:handle_packet(JoinPacketUpInvalid, Self)
    ),

    meck:new(hpr_protocol_router, [passthrough]),
    meck:expect(hpr_protocol_router, send, fun(_, _, _) -> ok end),

    DevAddr = 16#00000000,
    {ok, NetID} = lora_subnet:parse_netid(DevAddr, big),
    Route = hpr_route:new(
        NetID,
        [{16#00000000, 16#0000000A}],
        [{1, 1}, {1, 2}],
        <<"127.0.0.1">>,
        router,
        1
    ),
    ok = hpr_routing_config_worker:insert(Route),

    JoinPacketUpValid = test_utils:join_packet_up(#{
        hotspot => Hotspot, sig_fun => SigFun
    }),
    ?assertEqual(ok, hpr_routing:handle_packet(JoinPacketUpValid, Self)),

    Received1 =
        {Self,
            {hpr_protocol_router, send, [
                JoinPacketUpValid,
                Self,
                Route
            ]},
            ok},
    ?assertEqual([Received1], meck:history(hpr_protocol_router)),

    UplinkPacketUp = test_utils:uplink_packet_up(#{
        hotspot => Hotspot, sig_fun => SigFun, devadrr => DevAddr
    }),
    ?assertEqual(ok, hpr_routing:handle_packet(UplinkPacketUp, Self)),

    Received2 =
        {Self,
            {hpr_protocol_router, send, [
                UplinkPacketUp,
                Self,
                Route
            ]},
            ok},

    ?assertEqual([Received1, Received2], meck:history(hpr_protocol_router)),

    ?assert(meck:validate(hpr_protocol_router)),
    meck:unload(hpr_protocol_router),

    ok.