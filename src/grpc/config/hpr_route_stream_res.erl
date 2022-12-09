-module(hpr_route_stream_res).

-include("../autogen/config_pb.hrl").

-export([
    action/1,
    route/1
]).

-ifdef(TEST).

-export([test_new/1]).

-endif.

-type res() :: #config_route_stream_res_v1_pb{}.
-type action() :: create | update | delete.

-export_type([res/0, action/0]).

-spec action(RouteStreamRes :: res()) -> action().
action(RouteStreamRes) ->
    RouteStreamRes#config_route_stream_res_v1_pb.action.

-spec route(RouteStreamRes :: res()) -> hpr_route:route().
route(RouteStreamRes) ->
    RouteStreamRes#config_route_stream_res_v1_pb.route.

%% ------------------------------------------------------------------
%% Tests Functions
%% ------------------------------------------------------------------
-ifdef(TEST).

-spec test_new(map()) -> res().
test_new(Map) ->
    #config_route_stream_res_v1_pb{
        action = maps:get(action, Map),
        route = maps:get(route, Map)
    }.

-endif.

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

action_test() ->
    ?assertEqual(
        create,
        ?MODULE:action(#config_route_stream_res_v1_pb{
            action = create,
            route = undefined
        })
    ),
    ok.

route_test() ->
    Route = hpr_route:test_new(#{
        id => <<"7d502f32-4d58-4746-965e-8c7dfdcfc624">>,
        net_id => 0,
        devaddr_ranges => [
            #{start_addr => 16#00000001, end_addr => 16#0000000A},
            #{start_addr => 16#00000010, end_addr => 16#0000001A}
        ],
        euis => [#{app_eui => 1, dev_eui => 2}, #{app_eui => 3, dev_eui => 4}],
        oui => 1,
        server => #{
            host => <<"lns1.testdomain.com">>,
            port => 80,
            protocol => {http_roaming, #{}}
        },
        max_copies => 1,
        nonce => 1
    }),
    ?assertEqual(
        Route,
        ?MODULE:route(#config_route_stream_res_v1_pb{
            action = create,
            route = Route
        })
    ),
    ok.

new_test() ->
    Route = hpr_route:test_new(#{
        id => <<"7d502f32-4d58-4746-965e-8c7dfdcfc624">>,
        net_id => 0,
        devaddr_ranges => [
            #{start_addr => 16#00000001, end_addr => 16#0000000A},
            #{start_addr => 16#00000010, end_addr => 16#0000001A}
        ],
        euis => [#{app_eui => 1, dev_eui => 2}, #{app_eui => 3, dev_eui => 4}],
        oui => 1,
        server => #{
            host => <<"lns1.testdomain.com">>,
            port => 80,
            protocol => {http_roaming, #{}}
        },
        max_copies => 1,
        nonce => 1
    }),
    ?assertEqual(
        #config_route_stream_res_v1_pb{
            action = create,
            route = Route
        },
        ?MODULE:test_new(#{action => create, route => Route})
    ),
    ok.

-endif.