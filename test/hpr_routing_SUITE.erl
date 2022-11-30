-module(hpr_routing_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    gateway_limit_exceeded_test/1,
    invalid_packet_type_test/1,
    bad_signature_test/1,
    mic_check_test/1,
    success_test/1,
    max_copies_test/1
]).

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
        gateway_limit_exceeded_test,
        invalid_packet_type_test,
        bad_signature_test,
        mic_check_test,
        success_test,
        max_copies_test
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

gateway_limit_exceeded_test(_Config) ->
    %% Limit is DEFAULT_GATEWAY_THROTTLE = 25 per second
    Limit = 25,
    #{secret := PrivKey, public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
    SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
    Gateway = libp2p_crypto:pubkey_to_bin(PubKey),
    JoinPacketUpValid = test_utils:join_packet_up(#{
        gateway => Gateway, sig_fun => SigFun
    }),
    Self = self(),
    lists:foreach(
        fun(_) ->
            erlang:spawn(
                fun() ->
                    R = hpr_routing:handle_packet(JoinPacketUpValid),
                    Self ! {gateway_limit_exceeded_test, R}
                end
            )
        end,
        lists:seq(1, Limit + 1)
    ),
    ?assertEqual({25, 1}, receive_gateway_limit_exceeded_test({0, 0})),
    ok.

invalid_packet_type_test(_Config) ->
    #{secret := PrivKey, public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
    SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
    Gateway = libp2p_crypto:pubkey_to_bin(PubKey),
    JoinPacketUpInvalid = test_utils:join_packet_up(#{
        gateway => Gateway, sig_fun => SigFun, payload => <<>>
    }),
    ?assertEqual(
        {error, invalid_packet_type}, hpr_routing:handle_packet(JoinPacketUpInvalid)
    ),
    ok.

bad_signature_test(_Config) ->
    #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
    Gateway = libp2p_crypto:pubkey_to_bin(PubKey),

    JoinPacketBadSig = test_utils:join_packet_up(#{
        gateway => Gateway, sig_fun => fun(_) -> <<"bad_sig">> end
    }),
    ?assertEqual({error, bad_signature}, hpr_routing:handle_packet(JoinPacketBadSig)),
    ok.

mic_check_test(_Config) ->
    #{secret := PrivKey, public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
    SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
    Gateway = libp2p_crypto:pubkey_to_bin(PubKey),

    AppSessionKey = crypto:strong_rand_bytes(16),
    NwkSessionKey = crypto:strong_rand_bytes(16),
    DevAddr = 16#00000001,
    PacketUp = test_utils:uplink_packet_up(#{
        app_session_key => AppSessionKey,
        nwk_session_key => NwkSessionKey,
        devaddr => DevAddr,
        gateway => Gateway,
        sig_fun => SigFun
    }),

    JoinPacketUpValid = test_utils:join_packet_up(#{
        gateway => Gateway, sig_fun => SigFun
    }),
    ?assertEqual(ok, hpr_routing:handle_packet(JoinPacketUpValid)),

    hpr_skf_ets:insert(
        hpr_skf:from_map(#{devaddr => DevAddr, session_keys => [crypto:strong_rand_bytes(16)]})
    ),
    ?assertEqual({error, invalid_mic}, hpr_routing:handle_packet(PacketUp)),

    hpr_skf_ets:delete(
        hpr_skf:from_map(#{devaddr => DevAddr, session_keys => [NwkSessionKey]})
    ),
    ?assertEqual(ok, hpr_routing:handle_packet(PacketUp)),

    hpr_skf_ets:insert(
        hpr_skf:from_map(#{devaddr => DevAddr, session_keys => [NwkSessionKey]})
    ),
    ?assertEqual(ok, hpr_routing:handle_packet(PacketUp)),

    ok.

max_copies_test(_Config) ->
    MaxCopies = 2,
    DevAddr = 16#00000000,
    {ok, NetID} = lora_subnet:parse_netid(DevAddr, big),
    Route = hpr_route:new(#{
        id => <<"7d502f32-4d58-4746-965e-8c7dfdcfc624">>,
        net_id => NetID,
        devaddr_ranges => [#{start_addr => 16#00000000, end_addr => 16#0000000A}],
        euis => [#{app_eui => 1, dev_eui => 1}, #{app_eui => 1, dev_eui => 2}],
        oui => 1,
        server => #{
            host => <<"127.0.0.1">>,
            port => 80,
            protocol => {packet_router, #{}}
        },
        max_copies => MaxCopies,
        nonce => 1
    }),
    ok = hpr_route_ets:insert(Route),

    meck:new(hpr_protocol_router, [passthrough]),
    meck:expect(hpr_protocol_router, send, fun(_, _) -> ok end),

    AppSessionKey = crypto:strong_rand_bytes(16),
    NwkSessionKey = crypto:strong_rand_bytes(16),

    #{secret := PrivKey1, public := PubKey1} = libp2p_crypto:generate_keys(ecc_compact),
    SigFun1 = libp2p_crypto:mk_sig_fun(PrivKey1),
    Gateway1 = libp2p_crypto:pubkey_to_bin(PubKey1),

    UplinkPacketUp1 = test_utils:uplink_packet_up(#{
        gateway => Gateway1,
        sig_fun => SigFun1,
        devaddr => DevAddr,
        fcnt => 1,
        app_session_key => AppSessionKey,
        nwk_session_key => NwkSessionKey
    }),

    #{secret := PrivKey2, public := PubKey2} = libp2p_crypto:generate_keys(ecc_compact),
    SigFun2 = libp2p_crypto:mk_sig_fun(PrivKey2),
    Gateway2 = libp2p_crypto:pubkey_to_bin(PubKey2),

    UplinkPacketUp2 = test_utils:uplink_packet_up(#{
        gateway => Gateway2,
        sig_fun => SigFun2,
        devaddr => DevAddr,
        fcnt => 1,
        app_session_key => AppSessionKey,
        nwk_session_key => NwkSessionKey
    }),

    #{secret := PrivKey3, public := PubKey3} = libp2p_crypto:generate_keys(ecc_compact),
    SigFun3 = libp2p_crypto:mk_sig_fun(PrivKey3),
    Gateway3 = libp2p_crypto:pubkey_to_bin(PubKey3),

    UplinkPacketUp3 = test_utils:uplink_packet_up(#{
        gateway => Gateway3,
        sig_fun => SigFun3,
        devaddr => DevAddr,
        fcnt => 1,
        app_session_key => AppSessionKey,
        nwk_session_key => NwkSessionKey
    }),

    ?assertEqual(ok, hpr_routing:handle_packet(UplinkPacketUp1)),
    ?assertEqual(ok, hpr_routing:handle_packet(UplinkPacketUp2)),
    ?assertEqual(ok, hpr_routing:handle_packet(UplinkPacketUp3)),

    Self = self(),
    Received1 =
        {Self,
            {hpr_protocol_router, send, [
                UplinkPacketUp1,
                hpr_route_ets:remove_euis_dev_ranges(Route)
            ]},
            ok},
    Received2 =
        {Self,
            {hpr_protocol_router, send, [
                UplinkPacketUp2,
                hpr_route_ets:remove_euis_dev_ranges(Route)
            ]},
            ok},

    ?assertEqual([Received1, Received2], meck:history(hpr_protocol_router)),

    UplinkPacketUp4 = test_utils:uplink_packet_up(#{
        gateway => Gateway3,
        sig_fun => SigFun3,
        devaddr => DevAddr,
        fcnt => 2,
        app_session_key => AppSessionKey,
        nwk_session_key => NwkSessionKey
    }),

    ?assertEqual(ok, hpr_routing:handle_packet(UplinkPacketUp4)),

    Received3 =
        {Self,
            {hpr_protocol_router, send, [
                UplinkPacketUp4,
                hpr_route_ets:remove_euis_dev_ranges(Route)
            ]},
            ok},

    ?assertEqual([Received1, Received2, Received3], meck:history(hpr_protocol_router)),

    ?assert(meck:validate(hpr_protocol_router)),
    meck:unload(hpr_protocol_router),
    ok.

success_test(_Config) ->
    Self = self(),
    #{secret := PrivKey, public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
    SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
    Gateway = libp2p_crypto:pubkey_to_bin(PubKey),

    meck:new(hpr_protocol_router, [passthrough]),
    meck:expect(hpr_protocol_router, send, fun(_, _) -> ok end),

    DevAddr = 16#00000000,
    {ok, NetID} = lora_subnet:parse_netid(DevAddr, big),
    Route = hpr_route:new(#{
        id => <<"7d502f32-4d58-4746-965e-8c7dfdcfc624">>,
        net_id => NetID,
        devaddr_ranges => [#{start_addr => 16#00000000, end_addr => 16#0000000A}],
        euis => [#{app_eui => 1, dev_eui => 1}, #{app_eui => 1, dev_eui => 2}],
        oui => 1,
        server => #{
            host => <<"127.0.0.1">>,
            port => 80,
            protocol => {packet_router, #{}}
        },
        max_copies => 1,
        nonce => 1
    }),
    ok = hpr_route_ets:insert(Route),

    JoinPacketUpValid = test_utils:join_packet_up(#{
        gateway => Gateway, sig_fun => SigFun
    }),
    ?assertEqual(ok, hpr_routing:handle_packet(JoinPacketUpValid)),

    Received1 =
        {Self,
            {hpr_protocol_router, send, [
                JoinPacketUpValid,
                hpr_route_ets:remove_euis_dev_ranges(Route)
            ]},
            ok},
    ?assertEqual([Received1], meck:history(hpr_protocol_router)),

    UplinkPacketUp = test_utils:uplink_packet_up(#{
        gateway => Gateway, sig_fun => SigFun, devaddr => DevAddr
    }),
    ?assertEqual(ok, hpr_routing:handle_packet(UplinkPacketUp)),

    Received2 =
        {Self,
            {hpr_protocol_router, send, [
                UplinkPacketUp,
                hpr_route_ets:remove_euis_dev_ranges(Route)
            ]},
            ok},
    ?assertEqual(
        [
            Received1,
            Received2
        ],
        meck:history(hpr_protocol_router)
    ),

    ?assert(meck:validate(hpr_protocol_router)),
    meck:unload(hpr_protocol_router),
    ok.

%% ===================================================================
%% Helpers
%% ===================================================================

-spec receive_gateway_limit_exceeded_test(Acc :: {non_neg_integer(), non_neg_integer()}) ->
    {non_neg_integer(), non_neg_integer()}.
receive_gateway_limit_exceeded_test({OK, Error} = Acc) ->
    receive
        {gateway_limit_exceeded_test, {error, gateway_limit_exceeded}} ->
            receive_gateway_limit_exceeded_test({OK, Error + 1});
        {gateway_limit_exceeded_test, ok} ->
            receive_gateway_limit_exceeded_test({OK + 1, Error})
    after 100 ->
        Acc
    end.
