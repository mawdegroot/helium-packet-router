-module(hpr_routing_SUITE).

-include_lib("eunit/include/eunit.hrl").
-include("../src/grpc/autogen/multi_buy_pb.hrl").
-include("hpr.hrl").

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
    multi_buy_without_service_test/1,
    multi_buy_with_service_test/1,
    active_locked_route_test/1,
    success_test/1,
    no_routes_test/1,
    maybe_report_packet_test/1
]).

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
        multi_buy_without_service_test,
        multi_buy_with_service_test,
        active_locked_route_test,
        success_test,
        no_routes_test,
        maybe_report_packet_test
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
    #{secret := PrivKey, public := PubKey} = libp2p_crypto:generate_keys(ed25519),
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
    #{secret := PrivKey, public := PubKey} = libp2p_crypto:generate_keys(ed25519),
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
    #{public := PubKey} = libp2p_crypto:generate_keys(ed25519),
    Gateway = libp2p_crypto:pubkey_to_bin(PubKey),

    JoinPacketBadSig = test_utils:join_packet_up(#{
        gateway => Gateway, sig_fun => fun(_) -> <<"bad_sig">> end
    }),
    ?assertEqual({error, bad_signature}, hpr_routing:handle_packet(JoinPacketBadSig)),
    ok.

mic_check_test(_Config) ->
    #{secret := PrivKey, public := PubKey} = libp2p_crypto:generate_keys(ed25519),
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

    %% TEST 1: Join always works
    JoinPacketUpValid = test_utils:join_packet_up(#{
        gateway => Gateway, sig_fun => SigFun
    }),
    ?assertEqual(ok, hpr_routing:handle_packet(JoinPacketUpValid)),

    %% TEST 2:  No SFK for devaddr
    ?assertEqual(ok, hpr_routing:handle_packet(PacketUp)),

    %% TEST 3:  Good key but no routes
    SKFNoRoutes = hpr_skf:test_new(#{
        route_id => "empty",
        devaddr => DevAddr,
        session_key => hpr_utils:bin_to_hex_string(NwkSessionKey)
    }),
    hpr_route_ets:insert_skf(SKFNoRoutes),
    ok = test_utils:wait_until(
        fun() ->
            1 =:= ets:info(hpr_route_skfs_ets, size)
        end
    ),

    ?assertEqual({error, invalid_mic}, hpr_routing:handle_packet(PacketUp)),

    ok = hpr_route_ets:delete_skf(SKFNoRoutes),

    %% TEST 4:  Bad key and no routes
    BadSessionKey = hpr_utils:bin_to_hex_string(crypto:strong_rand_bytes(16)),
    SKFBadKeyNoRoute = hpr_skf:test_new(#{
        route_id => "empty", devaddr => DevAddr, session_key => BadSessionKey
    }),
    hpr_route_ets:insert_skf(SKFBadKeyNoRoute),

    ok = test_utils:wait_until(
        fun() ->
            1 =:= ets:info(hpr_route_skfs_ets, size)
        end
    ),
    ?assertEqual({error, invalid_mic}, hpr_routing:handle_packet(PacketUp)),

    ok = hpr_route_ets:delete_skf(SKFBadKeyNoRoute),

    %% TEST 5: Bad key and route exist
    Route = hpr_route:test_new(#{
        id => "11ea6dfd-3dce-4106-8980-d34007ab689b",
        net_id => 0,
        oui => 1,
        server => #{
            host => "lns1.testdomain.com",
            port => 80,
            protocol => {http_roaming, #{}}
        },
        max_copies => 1
    }),
    RouteID = hpr_route:id(Route),
    ?assertEqual(ok, hpr_route_ets:insert_route(Route)),

    SKFBadKeyAndRouteExitst = hpr_skf:test_new(#{
        route_id => RouteID, devaddr => DevAddr, session_key => BadSessionKey
    }),
    hpr_route_ets:insert_skf(SKFBadKeyAndRouteExitst),

    ok = test_utils:wait_until(
        fun() ->
            1 =:= ets:info(hpr_route_skfs_ets, size)
        end
    ),

    ?assertEqual({error, invalid_mic}, hpr_routing:handle_packet(PacketUp)),

    ok = hpr_route_ets:delete_skf(SKFBadKeyAndRouteExitst),

    %% TEST 6:  Good key and route exist
    %% We leave old route inserted and do not delete good skf for next test

    SKFGoodKeyAndRouteExitst = hpr_skf:test_new(#{
        route_id => RouteID,
        devaddr => DevAddr,
        session_key => hpr_utils:bin_to_hex_string(NwkSessionKey)
    }),
    hpr_route_ets:insert_skf(SKFGoodKeyAndRouteExitst),

    ok = test_utils:wait_until(
        fun() ->
            1 =:= ets:info(hpr_route_skfs_ets, size)
        end
    ),

    ?assertEqual(ok, hpr_routing:handle_packet(PacketUp)),

    %% TEST 7:  Good key and route exist
    %% Adding a bad key to make sure it still works

    hpr_route_ets:insert_skf(SKFBadKeyNoRoute),

    ok = test_utils:wait_until(
        fun() ->
            2 =:= ets:info(hpr_route_skfs_ets, size)
        end
    ),

    ?assertEqual(ok, hpr_routing:handle_packet(PacketUp)),

    ok.

multi_buy_without_service_test(_Config) ->
    meck:new(hpr_protocol_router, [passthrough]),
    meck:expect(hpr_protocol_router, send, fun(_, _) -> ok end),

    meck:new(hpr_packet_reporter, [passthrough]),
    meck:expect(hpr_packet_reporter, report_packet, fun(_, _, _) -> ok end),

    application:set_env(
        hpr,
        test_multi_buy_service_inc,
        fun(_Ctx, _Req) ->
            {grpc_error, {<<"12">>, <<"UNIMPLEMENTED">>}}
        end
    ),

    MaxCopies = 2,
    DevAddr = 16#00000000,
    {ok, NetID} = lora_subnet:parse_netid(DevAddr, big),
    RouteID = "7d502f32-4d58-4746-965e-8c7dfdcfc624",
    Route = hpr_route:test_new(#{
        id => RouteID,
        net_id => NetID,
        oui => 1,
        server => #{
            host => "127.0.0.1",
            port => 80,
            protocol => {packet_router, #{}}
        },
        max_copies => MaxCopies
    }),
    EUIPairs = [
        hpr_eui_pair:test_new(#{
            route_id => RouteID, app_eui => 1, dev_eui => 1
        }),
        hpr_eui_pair:test_new(#{
            route_id => RouteID, app_eui => 1, dev_eui => 2
        })
    ],
    DevAddrRanges = [
        hpr_devaddr_range:test_new(#{
            route_id => RouteID, start_addr => 16#00000000, end_addr => 16#0000000A
        })
    ],
    ok = hpr_route_ets:insert_route(Route),
    ok = lists:foreach(fun hpr_route_ets:insert_eui_pair/1, EUIPairs),
    ok = lists:foreach(fun hpr_route_ets:insert_devaddr_range/1, DevAddrRanges),

    AppSessionKey = crypto:strong_rand_bytes(16),
    NwkSessionKey = crypto:strong_rand_bytes(16),

    #{secret := PrivKey1, public := PubKey1} = libp2p_crypto:generate_keys(ed25519),
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

    #{secret := PrivKey2, public := PubKey2} = libp2p_crypto:generate_keys(ed25519),
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

    #{secret := PrivKey3, public := PubKey3} = libp2p_crypto:generate_keys(ed25519),
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
                Route
            ]},
            ok},
    Received2 =
        {Self,
            {hpr_protocol_router, send, [
                UplinkPacketUp2,
                Route
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
                Route
            ]},
            ok},

    ?assertEqual([Received1, Received2, Received3], meck:history(hpr_protocol_router)),

    %% Checking that packet got reported free
    [
        {_, {hpr_packet_reporter, report_packet, [_, _, IsFree1]}, _},
        {_, {hpr_packet_reporter, report_packet, [_, _, IsFree2]}, _},
        {_, {hpr_packet_reporter, report_packet, [_, _, IsFree3]}, _}
    ] = meck:history(
        hpr_packet_reporter
    ),
    ?assert(IsFree1),
    ?assert(IsFree2),
    ?assert(IsFree3),
    %% We sent 2 packets fnt 1 and 2
    ?assertEqual(2, ets:info(hpr_multi_buy_ets, size)),

    application:unset_env(hpr, test_multi_buy_service_inc),

    ?assert(meck:validate(hpr_protocol_router)),
    meck:unload(hpr_protocol_router),
    ?assert(meck:validate(hpr_packet_reporter)),
    meck:unload(hpr_packet_reporter),

    ok.

multi_buy_with_service_test(_Config) ->
    meck:new(hpr_protocol_router, [passthrough]),
    meck:expect(hpr_protocol_router, send, fun(_, _) -> ok end),

    meck:new(hpr_packet_reporter, [passthrough]),
    meck:expect(hpr_packet_reporter, report_packet, fun(_, _, _) -> ok end),

    MaxCopies = 2,
    DevAddr = 16#00000000,
    {ok, NetID} = lora_subnet:parse_netid(DevAddr, big),
    RouteID = "7d502f32-4d58-4746-965e-8c7dfdcfc624",
    Route = hpr_route:test_new(#{
        id => RouteID,
        net_id => NetID,
        oui => 1,
        server => #{
            host => "127.0.0.1",
            port => 80,
            protocol => {packet_router, #{}}
        },
        max_copies => MaxCopies
    }),
    EUIPairs = [
        hpr_eui_pair:test_new(#{
            route_id => RouteID, app_eui => 1, dev_eui => 1
        }),
        hpr_eui_pair:test_new(#{
            route_id => RouteID, app_eui => 1, dev_eui => 2
        })
    ],
    DevAddrRanges = [
        hpr_devaddr_range:test_new(#{
            route_id => RouteID, start_addr => 16#00000000, end_addr => 16#0000000A
        })
    ],
    ok = hpr_route_ets:insert_route(Route),
    ok = lists:foreach(fun hpr_route_ets:insert_eui_pair/1, EUIPairs),
    ok = lists:foreach(fun hpr_route_ets:insert_devaddr_range/1, DevAddrRanges),

    AppSessionKey = crypto:strong_rand_bytes(16),
    NwkSessionKey = crypto:strong_rand_bytes(16),

    #{secret := PrivKey1, public := PubKey1} = libp2p_crypto:generate_keys(ed25519),
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

    #{secret := PrivKey2, public := PubKey2} = libp2p_crypto:generate_keys(ed25519),
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

    #{secret := PrivKey3, public := PubKey3} = libp2p_crypto:generate_keys(ed25519),
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
                Route
            ]},
            ok},
    Received2 =
        {Self,
            {hpr_protocol_router, send, [
                UplinkPacketUp2,
                Route
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
                Route
            ]},
            ok},

    ?assertEqual([Received1, Received2, Received3], meck:history(hpr_protocol_router)),

    %% Checking that packet dit not get reported free
    [
        {_, {hpr_packet_reporter, report_packet, [_, _, IsFree1]}, _},
        {_, {hpr_packet_reporter, report_packet, [_, _, IsFree2]}, _},
        {_, {hpr_packet_reporter, report_packet, [_, _, IsFree3]}, _}
    ] = meck:history(
        hpr_packet_reporter
    ),
    ?assertNot(IsFree1),
    ?assertNot(IsFree2),
    ?assertNot(IsFree3),
    %% We sent 2 packets fnt 1 and 2 but nothing should be in ets
    ?assertEqual(0, ets:info(hpr_multi_buy_ets, size)),

    ?assert(meck:validate(hpr_protocol_router)),
    meck:unload(hpr_protocol_router),
    ?assert(meck:validate(hpr_packet_reporter)),
    meck:unload(hpr_packet_reporter),
    ok.

active_locked_route_test(_Config) ->
    DevAddr = 16#00000000,
    {ok, NetID} = lora_subnet:parse_netid(DevAddr, big),
    RouteID = "7d502f32-4d58-4746-965e-8c7dfdcfc624",
    Route1 = hpr_route:test_new(#{
        id => RouteID,
        net_id => NetID,
        oui => 1,
        server => #{
            host => "127.0.0.1",
            port => 80,
            protocol => {packet_router, #{}}
        },
        max_copies => 999,
        active => true,
        locked => false
    }),
    EUIPairs = [
        hpr_eui_pair:test_new(#{
            route_id => RouteID, app_eui => 1, dev_eui => 1
        })
    ],
    DevAddrRanges = [
        hpr_devaddr_range:test_new(#{
            route_id => RouteID, start_addr => 16#00000000, end_addr => 16#0000000A
        })
    ],
    ok = hpr_route_ets:insert_route(Route1),
    ok = lists:foreach(fun hpr_route_ets:insert_eui_pair/1, EUIPairs),
    ok = lists:foreach(fun hpr_route_ets:insert_devaddr_range/1, DevAddrRanges),

    meck:new(hpr_protocol_router, [passthrough]),
    meck:expect(hpr_protocol_router, send, fun(_, _) -> ok end),

    AppSessionKey = crypto:strong_rand_bytes(16),
    NwkSessionKey = crypto:strong_rand_bytes(16),

    #{secret := PrivKey1, public := PubKey1} = libp2p_crypto:generate_keys(ed25519),
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

    ?assertEqual(ok, hpr_routing:handle_packet(UplinkPacketUp1)),

    Self = self(),
    Received1 =
        {Self,
            {hpr_protocol_router, send, [
                UplinkPacketUp1,
                Route1
            ]},
            ok},

    ?assertEqual([Received1], meck:history(hpr_protocol_router)),
    ok = meck:reset(hpr_protocol_router),

    Route2 = hpr_route:test_new(#{
        id => RouteID,
        net_id => NetID,
        oui => 1,
        server => #{
            host => "127.0.0.1",
            port => 80,
            protocol => {packet_router, #{}}
        },
        max_copies => 999,
        active => false,
        locked => false
    }),
    ok = hpr_route_ets:insert_route(Route2),
    ?assertEqual(ok, hpr_routing:handle_packet(UplinkPacketUp1)),

    ?assertEqual([], meck:history(hpr_protocol_router)),

    Route3 = hpr_route:test_new(#{
        id => RouteID,
        net_id => NetID,
        oui => 1,
        server => #{
            host => "127.0.0.1",
            port => 80,
            protocol => {packet_router, #{}}
        },
        max_copies => 999,
        active => true,
        locked => true
    }),
    ok = hpr_route_ets:insert_route(Route3),
    ?assertEqual(ok, hpr_routing:handle_packet(UplinkPacketUp1)),

    ?assertEqual([], meck:history(hpr_protocol_router)),

    ?assert(meck:validate(hpr_protocol_router)),
    meck:unload(hpr_protocol_router),
    ok.

success_test(_Config) ->
    Self = self(),
    #{secret := PrivKey, public := PubKey} = libp2p_crypto:generate_keys(ed25519),
    SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
    Gateway = libp2p_crypto:pubkey_to_bin(PubKey),

    meck:new(hpr_protocol_router, [passthrough]),
    meck:expect(hpr_protocol_router, send, fun(_, _) -> ok end),

    DevAddr = 16#00000000,
    {ok, NetID} = lora_subnet:parse_netid(DevAddr, big),
    RouteID = "7d502f32-4d58-4746-965e-8c7dfdcfc624",
    Route = hpr_route:test_new(#{
        id => RouteID,
        net_id => NetID,
        oui => 1,
        server => #{
            host => "127.0.0.1",
            port => 80,
            protocol => {packet_router, #{}}
        },
        max_copies => 1
    }),
    EUIPairs = [
        hpr_eui_pair:test_new(#{
            route_id => RouteID, app_eui => 1, dev_eui => 1
        }),
        hpr_eui_pair:test_new(#{
            route_id => RouteID, app_eui => 1, dev_eui => 2
        })
    ],
    DevAddrRanges = [
        hpr_devaddr_range:test_new(#{
            route_id => RouteID, start_addr => 16#00000000, end_addr => 16#0000000A
        })
    ],
    ok = hpr_route_ets:insert_route(Route),
    ok = lists:foreach(fun hpr_route_ets:insert_eui_pair/1, EUIPairs),
    ok = lists:foreach(fun hpr_route_ets:insert_devaddr_range/1, DevAddrRanges),

    JoinPacketUpValid = test_utils:join_packet_up(#{
        gateway => Gateway, sig_fun => SigFun
    }),
    ?assertEqual(ok, hpr_routing:handle_packet(JoinPacketUpValid)),

    Received1 =
        {Self,
            {hpr_protocol_router, send, [
                JoinPacketUpValid,
                Route
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
                Route
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

no_routes_test(_Config) ->
    ok = meck:new(hpr_packet_reporter, [passthrough]),
    ok = meck:expect(hpr_packet_reporter, report_packet, 3, ok),

    Port1 = 8180,
    Port2 = 8280,
    application:set_env(
        ?APP,
        no_routes,
        [{"localhost", Port1}, {"127.0.0.1", erlang:integer_to_list(Port2)}],
        [{persistent, true}]
    ),
    %% Startup no route servers
    {ok, ServerPid1} = grpcbox:start_server(#{
        grpc_opts => #{
            service_protos => [packet_router_pb],
            services => #{'helium.packet_router.packet' => hpr_test_packet_router_service}
        },
        listen_opts => #{port => Port1, ip => {0, 0, 0, 0}}
    }),
    {ok, ServerPid2} = grpcbox:start_server(#{
        grpc_opts => #{
            service_protos => [packet_router_pb],
            services => #{'helium.packet_router.packet' => hpr_test_packet_router_service}
        },
        listen_opts => #{port => Port2, ip => {0, 0, 0, 0}}
    }),

    %% Interceptor
    Self = self(),
    application:set_env(
        hpr,
        test_packet_router_service_route,
        fun(Env, StreamState) ->
            {packet, Packet} = hpr_envelope_up:data(Env),
            Self ! {packet_up, Packet},
            StreamState
        end
    ),

    RouteID = "7d502f32-4d58-4746-965e-8c7dfdcfc624",
    Route = hpr_route:test_new(#{
        id => RouteID,
        net_id => 0,
        oui => 4020,
        server => #{
            host => "127.0.0.1",
            port => 8082,
            protocol => {packet_router, #{}}
        },
        max_copies => 2
    }),
    EUIPairs = [
        hpr_eui_pair:test_new(#{
            route_id => RouteID, app_eui => 802041902051071031, dev_eui => 8942655256770396549
        })
    ],
    DevAddrRanges = [
        hpr_devaddr_range:test_new(#{
            route_id => RouteID, start_addr => 16#00000000, end_addr => 16#00000010
        })
    ],
    {ok, GatewayPid} = hpr_test_gateway:start(#{
        forward => self(), route => Route, eui_pairs => EUIPairs, devaddr_ranges => DevAddrRanges
    }),

    %% Send packet and route directly through interface
    ok = hpr_test_gateway:send_packet(GatewayPid, #{devaddr => 16#FFFFFFFF}),

    PacketUp =
        case hpr_test_gateway:receive_send_packet(GatewayPid) of
            {ok, EnvUp} ->
                {packet, PUp} = hpr_envelope_up:data(EnvUp),
                PUp;
            {error, timeout} ->
                ct:fail(receive_send_packet)
        end,

    ok =
        receive
            {packet_up, RvcPacketUp0} -> ?assertEqual(RvcPacketUp0, PacketUp)
        after timer:seconds(2) -> ct:fail(no_msg_rcvd)
        end,

    ok =
        receive
            {packet_up, RvcPacketUp1} -> ?assertEqual(RvcPacketUp1, PacketUp)
        after timer:seconds(2) -> ct:fail(no_msg_rcvd)
        end,

    ok = gen_server:stop(GatewayPid),
    ok = gen_server:stop(ServerPid1),
    ok = gen_server:stop(ServerPid2),

    %% Ensure packets sent to no_routes do not get reported.
    ?assertEqual(0, meck:num_calls(hpr_packet_reporter, report_packet, 3)),
    meck:unload(hpr_packet_reporter),

    application:set_env(
        ?APP,
        no_routes,
        [],
        [{persistent, true}]
    ),
    ok.

maybe_report_packet_test(_Config) ->
    Self = self(),
    #{secret := PrivKey, public := PubKey} = libp2p_crypto:generate_keys(ed25519),
    SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
    Gateway = libp2p_crypto:pubkey_to_bin(PubKey),

    meck:new(hpr_protocol_router, [passthrough]),
    meck:new(hpr_packet_reporter, [passthrough]),

    meck:expect(hpr_protocol_router, send, fun(_, _) -> ok end),

    DevAddr = 16#00000000,
    {ok, NetID} = lora_subnet:parse_netid(DevAddr, big),
    RouteID = "7d502f32-4d58-4746-965e-8c7dfdcfc624",
    Route = hpr_route:test_new(#{
        id => RouteID,
        net_id => NetID,
        oui => 1,
        server => #{
            host => "127.0.0.1",
            port => 80,
            protocol => {packet_router, #{}}
        },
        max_copies => 1
    }),
    EUIPairs = [
        hpr_eui_pair:test_new(#{
            route_id => RouteID, app_eui => 1, dev_eui => 1
        }),
        hpr_eui_pair:test_new(#{
            route_id => RouteID, app_eui => 1, dev_eui => 2
        })
    ],
    DevAddrRanges = [
        hpr_devaddr_range:test_new(#{
            route_id => RouteID, start_addr => 16#00000000, end_addr => 16#0000000A
        })
    ],
    ok = hpr_route_ets:insert_route(Route),
    ok = lists:foreach(fun hpr_route_ets:insert_eui_pair/1, EUIPairs),
    ok = lists:foreach(fun hpr_route_ets:insert_devaddr_range/1, DevAddrRanges),

    JoinPacketUpValid = test_utils:join_packet_up(#{
        gateway => Gateway, sig_fun => SigFun
    }),
    ?assertEqual(ok, hpr_routing:handle_packet(JoinPacketUpValid)),

    Received1 =
        {Self,
            {hpr_protocol_router, send, [
                JoinPacketUpValid,
                Route
            ]},
            ok},
    ?assertEqual([Received1], meck:history(hpr_protocol_router)),

    UplinkPacketUp1 = test_utils:uplink_packet_up(#{
        gateway => Gateway, sig_fun => SigFun, devaddr => DevAddr, fcnt => 1
    }),
    ?assertEqual(ok, hpr_routing:handle_packet(UplinkPacketUp1)),

    Received2 =
        {Self,
            {hpr_protocol_router, send, [
                UplinkPacketUp1,
                Route
            ]},
            ok},
    ?assertEqual(
        [
            Received1,
            Received2
        ],
        meck:history(hpr_protocol_router)
    ),

    ?assertEqual(2, meck:num_calls(hpr_packet_reporter, report_packet, 3)),

    ok = meck:reset(hpr_packet_reporter),

    %% We are adding a route with diff OUI but same dev ranges (This should not be allowed by CS)
    BadRouteID = "11502f32-4d58-4746-965e-8c7dfdcfc624",
    BadRoute = hpr_route:test_new(#{
        id => BadRouteID,
        net_id => NetID,
        oui => 2,
        server => #{
            host => "localhost",
            port => 80,
            protocol => {packet_router, #{}}
        },
        max_copies => 1
    }),
    BadDevAddrRanges = [
        hpr_devaddr_range:test_new(#{
            route_id => BadRouteID, start_addr => 16#00000000, end_addr => 16#0000000A
        })
    ],
    ok = hpr_route_ets:insert_route(BadRoute),
    ok = lists:foreach(fun hpr_route_ets:insert_devaddr_range/1, BadDevAddrRanges),

    UplinkPacketUp2 = test_utils:uplink_packet_up(#{
        gateway => Gateway, sig_fun => SigFun, devaddr => DevAddr, fcnt => 2
    }),
    ?assertEqual(ok, hpr_routing:handle_packet(UplinkPacketUp2)),

    CallExpected3 =
        {hpr_protocol_router, send, [
            UplinkPacketUp2,
            BadRoute
        ]},
    CallExpected4 =
        {hpr_protocol_router, send, [
            UplinkPacketUp2,
            Route
        ]},

    %% Packet is still send to both Routes
    [
        History1,
        History2,
        {Pid3, Call3, Result3},
        {Pid4, Call4, Result4}
    ] = meck:history(hpr_protocol_router),

    ?assertEqual(Received1, History1),
    ?assertEqual(Received2, History2),
    ?assert(erlang:is_pid(Pid3)),
    ?assert(erlang:is_pid(Pid4)),
    %% Order can be messed up due to spanwing
    ?assert(CallExpected3 == Call3 orelse CallExpected3 == Call4),
    ?assert(CallExpected4 == Call3 orelse CallExpected4 == Call4),
    ?assertEqual(ok, Result3),
    ?assertEqual(ok, Result4),

    %% But no report is done
    ?assertEqual(0, meck:num_calls(hpr_packet_reporter, report_packet, 3)),

    ?assert(meck:validate(hpr_protocol_router)),
    meck:unload(hpr_protocol_router),
    ?assert(meck:validate(hpr_packet_reporter)),
    meck:unload(hpr_packet_reporter),
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
