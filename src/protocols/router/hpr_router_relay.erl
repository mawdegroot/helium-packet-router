-module(hpr_router_relay).

-behaviour(gen_server).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start/2
]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------
-export([
    init/1,
    handle_continue/2,
    handle_call/3,
    handle_cast/2
]).

-record(state, {
    monitor_process :: pid(),
    gateway_stream :: hpr_router_stream_manager:gateway_stream(),
    router_stream :: grpc_client:client_stream()
}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

-spec start(
    hpr_router_stream_manager:gateway_stream(),
    grpc_client:client_stream()
) -> {ok, pid()}.
%% @doc Start this service.
start(GatewayStream, RouterStream) ->
    gen_server:start(?MODULE, [GatewayStream, RouterStream], []).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

-spec init(list()) -> {ok, #state{}, {continue, relay}}.
init([GatewayStream, RouterStream]) ->
    {ok, MonitorPid} =
        hpr_router_relay_monitor:start(
            self(), GatewayStream, RouterStream
        ),
    {
        ok,
        #state{
            monitor_process = MonitorPid,
            gateway_stream = GatewayStream,
            router_stream = RouterStream
        },
        {continue, relay}
    }.

-spec handle_continue(relay, #state{}) ->
    {noreply, #state{}, {continue, relay}}
    | {stop, normal, #state{}}
    | {stop, {error, any()}, #state{}}.
handle_continue(relay, State) ->
    case grpc_client:rcv(State#state.router_stream) of
        {data, Reply} ->
            State#state.gateway_stream ! {router_reply, Reply},
            {noreply, State, {continue, relay}};
        {headers, _} ->
            {noreply, State, {continue, relay}};
        eof ->
            {stop, normal, State};
        {error, _} = Error ->
            {stop, Error, State}
    end.

-spec handle_call(Msg, {pid(), any()}, #state{}) -> {stop, {unimplemented_call, Msg}, #state{}}.
handle_call(Msg, _From, State) ->
    {stop, {unimplemented_call, Msg}, State}.

-spec handle_cast(Msg, #state{}) -> {stop, {unimplemented_cast, Msg}, #state{}}.
handle_cast(Msg, State) ->
    {stop, {unimplemented_cast, Msg}, State}.

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

all_test_() ->
    {foreach, fun foreach_setup/0, fun foreach_cleanup/1, [
        ?_test(test_relay_data()),
        ?_test(test_relay_headers()),
        ?_test(test_relay_eof()),
        ?_test(test_relay_error())
    ]}.

foreach_setup() ->
    ok.

foreach_cleanup(ok) ->
    meck:unload().

test_relay_data() ->
    meck:new(grpc_client),
    State = state(),
    meck:expect(grpc_client, rcv, [State#state.router_stream], {data, fake_data()}),
    Reply = handle_continue(relay, State),
    ?assertEqual({noreply, State, {continue, relay}}, Reply),
    ?assertEqual(1, meck:num_calls(grpc_client, rcv, 1)),
    RelayMessage = receive_relay(),
    ?assertEqual(fake_data(), RelayMessage).

test_relay_headers() ->
    meck:new(grpc_client),
    State = state(),
    meck:expect(grpc_client, rcv, [State#state.router_stream], {headers, #{fake => headers}}),
    Reply = handle_continue(relay, State),
    ?assertEqual({noreply, State, {continue, relay}}, Reply),
    ?assertEqual(1, meck:num_calls(grpc_client, rcv, 1)),
    ?assertEqual(empty, check_messages()).

test_relay_eof() ->
    meck:new(grpc_client),
    State = state(),
    meck:expect(grpc_client, rcv, [State#state.router_stream], eof),
    Reply = handle_continue(relay, State),
    ?assertEqual({stop, normal, State}, Reply),
    ?assertEqual(1, meck:num_calls(grpc_client, rcv, 1)),
    ?assertEqual(empty, check_messages()).

test_relay_error() ->
    meck:new(grpc_client),
    State = state(),
    Error = {error, fake_error},
    meck:expect(grpc_client, rcv, [State#state.router_stream], Error),
    Reply = handle_continue(relay, State),
    ?assertEqual({stop, Error, State}, Reply),
    ?assertEqual(1, meck:num_calls(grpc_client, rcv, 1)),
    ?assertEqual(empty, check_messages()).

% ------------------------------------------------------------------------------
% Unit test utils
% ------------------------------------------------------------------------------

fake_data() ->
    #{fake => data}.

fake_stream() ->
    Self = self(),
    spawn(
        fun Loop() ->
            monitor(process, Self),
            receive
                {'DOWN', _, process, Self, _} ->
                    ok;
                {router_reply, _} = Reply ->
                    Self ! Reply,
                    Loop();
                Msg ->
                    % sanity check on pattern matches
                    exit({unexpected_message, Msg})
            end
        end
    ).

fake_monitor() ->
    spawn(
        fun() ->
            receive
                stop -> ok
            end
        end
    ).

receive_relay() ->
    receive
        {router_reply, Message} ->
            Message
    after 50 ->
        timeout
    end.

check_messages() ->
    receive
        Msg -> Msg
    after 0 ->
        empty
    end.

state() ->
    #state{
        monitor_process = fake_monitor(),
        gateway_stream = fake_stream(),
        router_stream = fake_stream()
    }.

-endif.
