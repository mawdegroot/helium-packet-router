-module(hpr_route).

-include("../autogen/iot_config_pb.hrl").

-export([
    id/1,
    net_id/1,
    devaddr_ranges/1, devaddr_ranges/2,
    euis/1, euis/2,
    server/1,
    oui/1,
    max_copies/1,
    nonce/1,
    lns/1,
    gwmp_region_lns/2,
    md/1,
    new_packet_router/2
]).

-export([
    host/1,
    port/1,
    protocol/1,
    protocol_type/1,
    http_roaming_flow_type/1,
    http_roaming_dedupe_timeout/1,
    http_roaming_path/1,
    http_auth_header/1
]).

-ifdef(TEST).

-export([test_new/1]).

-endif.

-type route() :: #iot_config_route_v1_pb{}.
-type server() :: #iot_config_server_v1_pb{}.
-type protocol() ::
    {packet_router, #iot_config_protocol_packet_router_v1_pb{}}
    | {gwmp, #iot_config_protocol_gwmp_v1_pb{}}
    | {http_roaming, #iot_config_protocol_http_roaming_v1_pb{}}
    | undefined.
-type protocol_type() :: packet_router | gwmp | http_roaming | undefined.

-export_type([route/0, server/0, protocol/0]).

-spec id(Route :: route()) -> string().
id(Route) ->
    Route#iot_config_route_v1_pb.id.

-spec net_id(Route :: route()) -> non_neg_integer().
net_id(Route) ->
    Route#iot_config_route_v1_pb.net_id.

-spec devaddr_ranges(Route :: route()) -> [{non_neg_integer(), non_neg_integer()}].
devaddr_ranges(Route) ->
    [
        {Start, End}
     || #iot_config_devaddr_range_v1_pb{start_addr = Start, end_addr = End} <-
            Route#iot_config_route_v1_pb.devaddr_ranges
    ].

-spec devaddr_ranges(Route :: route(), DevRanges :: [#iot_config_devaddr_range_v1_pb{}]) -> route().
devaddr_ranges(Route, DevRanges) ->
    Route#iot_config_route_v1_pb{devaddr_ranges = DevRanges}.

-spec euis(Route :: route()) -> [{non_neg_integer(), non_neg_integer()}].
euis(Route) ->
    [
        {AppEUI, DevEUI}
     || #iot_config_eui_v1_pb{app_eui = AppEUI, dev_eui = DevEUI} <-
            Route#iot_config_route_v1_pb.euis
    ].

-spec euis(Route :: route(), EUIs :: [#iot_config_eui_v1_pb{}]) -> route().
euis(Route, EUIs) ->
    Route#iot_config_route_v1_pb{euis = EUIs}.

-spec server(Route :: route()) -> server().
server(Route) ->
    Route#iot_config_route_v1_pb.server.

-spec oui(Route :: route()) -> non_neg_integer().
oui(Route) ->
    Route#iot_config_route_v1_pb.oui.

-spec max_copies(Route :: route()) -> non_neg_integer().
max_copies(Route) ->
    Route#iot_config_route_v1_pb.max_copies.

-spec nonce(Route :: route()) -> non_neg_integer().
nonce(Route) ->
    Route#iot_config_route_v1_pb.nonce.

-spec lns(Route :: route()) -> binary().
lns(Route) ->
    Server = ?MODULE:server(Route),
    Host = erlang:list_to_binary(?MODULE:host(Server)),
    Port = ?MODULE:port(Server),
    case Server#iot_config_server_v1_pb.protocol of
        {http_roaming, _RoamingProtocol} ->
            Path = http_roaming_path(Route),
            <<Host/binary, $:, (erlang:integer_to_binary(Port))/binary, Path/binary>>;
        _ ->
            <<Host/binary, $:, (erlang:integer_to_binary(Port))/binary>>
    end.

-spec gwmp_region_lns(Region :: atom(), Route :: route()) ->
    {Address :: string(), Port :: inet:port_number()}.
gwmp_region_lns(Region, Route) ->
    Server = ?MODULE:server(Route),
    {gwmp, #iot_config_protocol_gwmp_v1_pb{mapping = Mapping}} = ?MODULE:protocol(Server),

    Host = ?MODULE:host(Server),
    Port =
        case lists:keyfind(Region, 2, Mapping) of
            false -> ?MODULE:port(Server);
            #iot_config_protocol_gwmp_mapping_v1_pb{port = P} -> P
        end,
    {Host, Port}.

-spec md(Route :: route()) -> list({atom(), string() | atom() | non_neg_integer()}).
md(Route) ->
    Server = ?MODULE:server(Route),
    [
        {route_id, ?MODULE:id(Route)},
        {oui, ?MODULE:oui(Route)},
        {protocol_type, ?MODULE:protocol_type(Server)},
        {net_id, hpr_utils:int_to_hex(hpr_route:net_id(Route))},
        {lns, erlang:binary_to_list(hpr_route:lns(Route))}
    ].

-spec new_packet_router(Host :: string(), Port :: non_neg_integer() | string()) -> route().
new_packet_router(Host, Port) when is_list(Port) ->
    new_packet_router(Host, erlang:list_to_integer(Port));
new_packet_router(Host, Port) ->
    #iot_config_route_v1_pb{
        id = Host ++ "_id",
        oui = 0,
        net_id = 0,
        devaddr_ranges = [],
        euis = [],
        max_copies = 999,
        nonce = 1,
        server = #iot_config_server_v1_pb{
            host = Host,
            port = Port,
            protocol = {packet_router, #iot_config_protocol_packet_router_v1_pb{}}
        }
    }.

-spec host(Server :: server()) -> string().
host(Server) ->
    Server#iot_config_server_v1_pb.host.

-spec port(Server :: server()) -> non_neg_integer().
port(Server) ->
    Server#iot_config_server_v1_pb.port.

-spec protocol(Server :: server()) -> protocol().
protocol(Server) ->
    Server#iot_config_server_v1_pb.protocol.

-spec protocol_type(Server :: server()) -> protocol_type().
protocol_type(Server) ->
    case Server#iot_config_server_v1_pb.protocol of
        {Type, _} -> Type;
        undefined -> undefined
    end.

-spec http_roaming_flow_type(Route :: route()) -> sync | async.
http_roaming_flow_type(Route) ->
    Server = Route#iot_config_route_v1_pb.server,
    {http_roaming, HttpRoamingProtocol} = Server#iot_config_server_v1_pb.protocol,
    HttpRoamingProtocol#iot_config_protocol_http_roaming_v1_pb.flow_type.

-spec http_roaming_dedupe_timeout(Route :: route()) -> non_neg_integer() | undefined.
http_roaming_dedupe_timeout(Route) ->
    Server = Route#iot_config_route_v1_pb.server,
    {http_roaming, HttpRoamingProtocol} = Server#iot_config_server_v1_pb.protocol,
    HttpRoamingProtocol#iot_config_protocol_http_roaming_v1_pb.dedupe_timeout.

-spec http_roaming_path(Route :: route()) -> binary().
http_roaming_path(Route) ->
    Server = Route#iot_config_route_v1_pb.server,
    case Server#iot_config_server_v1_pb.protocol of
        {http_roaming, HttpRoamingProtocol} ->
            erlang:list_to_binary(
                HttpRoamingProtocol#iot_config_protocol_http_roaming_v1_pb.path
            );
        _ ->
            <<>>
    end.

-spec http_auth_header(Route :: route()) -> null | string().
http_auth_header(Route) ->
    Server = ?MODULE:server(Route),
    {http_roaming, HttpRoamingProtocol} = ?MODULE:protocol(Server),
    case HttpRoamingProtocol#iot_config_protocol_http_roaming_v1_pb.auth_header of
        [] -> null;
        V -> V
    end.

%% ------------------------------------------------------------------
%% Tests Functions
%% ------------------------------------------------------------------
-ifdef(TEST).

-spec test_new(RouteMap :: map()) -> route().
test_new(RouteMap) ->
    #iot_config_route_v1_pb{
        id = maps:get(id, RouteMap),
        oui = maps:get(oui, RouteMap),
        net_id = maps:get(net_id, RouteMap),
        devaddr_ranges = [
            #iot_config_devaddr_range_v1_pb{start_addr = S, end_addr = E}
         || #{start_addr := S, end_addr := E} <- maps:get(devaddr_ranges, RouteMap)
        ],
        euis = [
            #iot_config_eui_v1_pb{dev_eui = D, app_eui = A}
         || #{dev_eui := D, app_eui := A} <- maps:get(euis, RouteMap)
        ],
        max_copies = maps:get(max_copies, RouteMap),
        nonce = maps:get(nonce, RouteMap),
        server = mk_server(maps:get(server, RouteMap))
    }.

-spec mk_server(map()) -> #iot_config_server_v1_pb{}.
mk_server(ServerMap) ->
    #iot_config_server_v1_pb{
        host = maps:get(host, ServerMap),
        port = maps:get(port, ServerMap),
        protocol = mk_protocol(maps:get(protocol, ServerMap))
    }.

-spec mk_protocol({protocol_type(), map()}) -> protocol().
mk_protocol({packet_router, _PacketRouterMap}) ->
    {packet_router, #iot_config_protocol_packet_router_v1_pb{}};
mk_protocol({gwmp, GwmpMap}) ->
    Mapping = [
        #iot_config_protocol_gwmp_mapping_v1_pb{region = Region, port = Port}
     || #{region := Region, port := Port} <- maps:get(mapping, GwmpMap)
    ],
    {gwmp, #iot_config_protocol_gwmp_v1_pb{mapping = Mapping}};
mk_protocol({http_roaming, HttpMap}) ->
    Template = #iot_config_protocol_http_roaming_v1_pb{},
    {http_roaming, #iot_config_protocol_http_roaming_v1_pb{
        flow_type = maps:get(
            flow_type, HttpMap, Template#iot_config_protocol_http_roaming_v1_pb.flow_type
        ),
        dedupe_timeout = maps:get(
            dedupe_timeout, HttpMap, Template#iot_config_protocol_http_roaming_v1_pb.dedupe_timeout
        ),
        path = maps:get(path, HttpMap, Template#iot_config_protocol_http_roaming_v1_pb.path),
        auth_header = maps:get(
            auth_header, HttpMap, Template#iot_config_protocol_http_roaming_v1_pb.auth_header
        )
    }};
mk_protocol(undefined) ->
    undefined.

-endif.
%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

test_new_test() ->
    Route = #iot_config_route_v1_pb{
        id = "7d502f32-4d58-4746-965e-8c7dfdcfc624",
        net_id = 1,
        devaddr_ranges = [
            #iot_config_devaddr_range_v1_pb{start_addr = 1, end_addr = 10},
            #iot_config_devaddr_range_v1_pb{start_addr = 11, end_addr = 20}
        ],
        euis = [
            #iot_config_eui_v1_pb{app_eui = 1, dev_eui = 1},
            #iot_config_eui_v1_pb{app_eui = 2, dev_eui = 0}
        ],
        oui = 10,
        server = #iot_config_server_v1_pb{
            host = "lsn.lora.com",
            port = 80,
            protocol = {gwmp, #iot_config_protocol_gwmp_v1_pb{mapping = []}}
        },
        max_copies = 1,
        nonce = 1
    },
    ?assertEqual(
        Route,
        ?MODULE:test_new(#{
            id => "7d502f32-4d58-4746-965e-8c7dfdcfc624",
            net_id => 1,
            devaddr_ranges => [
                #{start_addr => 1, end_addr => 10}, #{start_addr => 11, end_addr => 20}
            ],
            euis => [#{app_eui => 1, dev_eui => 1}, #{app_eui => 2, dev_eui => 0}],
            oui => 10,
            server => #{
                host => "lsn.lora.com",
                port => 80,
                protocol => {gwmp, #{mapping => []}}
            },
            max_copies => 1,
            nonce => 1
        })
    ),
    ok.

id_test() ->
    Route = test_route(),
    ?assertEqual("7d502f32-4d58-4746-965e-8c7dfdcfc624", ?MODULE:id(Route)),
    ok.

net_id_test() ->
    Route = test_route(),
    ?assertEqual(1, ?MODULE:net_id(Route)),
    ok.

devaddr_ranges_1_test() ->
    Route = test_route(),
    ?assertEqual([{1, 10}, {11, 20}], ?MODULE:devaddr_ranges(Route)),
    ok.

devaddr_ranges_2_test() ->
    Route = test_route(),
    ?assertEqual([], ?MODULE:devaddr_ranges(?MODULE:devaddr_ranges(Route, []))),
    ok.

euis_1_test() ->
    Route = test_route(),
    ?assertEqual([{1, 1}, {2, 0}], ?MODULE:euis(Route)),
    ok.

euis_2_test() ->
    Route = test_route(),
    ?assertEqual([], ?MODULE:euis(?MODULE:euis(Route, []))),
    ok.

region_lns_test() ->
    Route = ?MODULE:test_new(#{
        id => "7d502f32-4d58-4746-965e-8c7dfdcfc624",
        net_id => 1,
        devaddr_ranges => [
            #{start_addr => 1, end_addr => 10}, #{start_addr => 11, end_addr => 20}
        ],
        euis => [#{app_eui => 1, dev_eui => 1}, #{app_eui => 2, dev_eui => 0}],
        oui => 10,
        server => #{
            host => "lsn.lora.com",
            port => 80,
            protocol =>
                {gwmp, #{
                    mapping => [
                        #{region => 'US915', port => 81},
                        #{region => 'EU868', port => 82},
                        #{region => 'AS923_1', port => 83}
                    ]
                }}
        },
        max_copies => 1,
        nonce => 1
    }),
    ?assertEqual({"lsn.lora.com", 81}, ?MODULE:gwmp_region_lns('US915', Route)),
    ?assertEqual({"lsn.lora.com", 82}, ?MODULE:gwmp_region_lns('EU868', Route)),
    ?assertEqual({"lsn.lora.com", 83}, ?MODULE:gwmp_region_lns('AS923_1', Route)),
    ?assertEqual({"lsn.lora.com", 80}, ?MODULE:gwmp_region_lns('AS923_2', Route)),
    ok.

oui_test() ->
    Route = test_route(),
    ?assertEqual(10, ?MODULE:oui(Route)),
    ok.

server_test() ->
    Route = test_route(),
    ?assertEqual(
        #iot_config_server_v1_pb{
            host = "lsn.lora.com",
            port = 80,
            protocol = {gwmp, #iot_config_protocol_gwmp_v1_pb{mapping = []}}
        },
        ?MODULE:server(Route)
    ),
    ok.

max_copies_test() ->
    Route = test_route(),
    ?assertEqual(1, ?MODULE:max_copies(Route)),
    ok.

nonce_test() ->
    Route = test_route(),
    ?assertEqual(1, ?MODULE:nonce(Route)),
    ok.

lns_test() ->
    Route = test_route(),
    ?assertEqual(<<"lsn.lora.com:80">>, ?MODULE:lns(Route)),
    ok.

host_test() ->
    Route = test_route(),
    ?assertEqual("lsn.lora.com", ?MODULE:host(?MODULE:server(Route))),
    ok.

port_test() ->
    Route = test_route(),
    ?assertEqual(80, ?MODULE:port(?MODULE:server(Route))),
    ok.

protocol_test() ->
    Route = test_route(),
    ?assertEqual(
        {gwmp, #iot_config_protocol_gwmp_v1_pb{mapping = []}},
        ?MODULE:protocol(?MODULE:server(Route))
    ),
    ok.

test_route() ->
    ?MODULE:test_new(#{
        id => "7d502f32-4d58-4746-965e-8c7dfdcfc624",
        net_id => 1,
        devaddr_ranges => [
            #{start_addr => 1, end_addr => 10}, #{start_addr => 11, end_addr => 20}
        ],
        euis => [#{app_eui => 1, dev_eui => 1}, #{app_eui => 2, dev_eui => 0}],
        oui => 10,
        server => #{
            host => "lsn.lora.com",
            port => 80,
            protocol => {gwmp, #{mapping => []}}
        },
        max_copies => 1,
        nonce => 1
    }).

-endif.
