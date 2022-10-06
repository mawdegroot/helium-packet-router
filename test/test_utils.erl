-module(test_utils).

-export([
    init_per_testcase/2,
    end_per_testcase/2,
    join_packet_up/1,
    uplink_packet_up/1,
    wait_until/1, wait_until/3,
    match_map/2
]).

-include("hpr.hrl").

-define(JOIN_REQUEST, 2#000).
-define(UNCONFIRMED_UP, 2#010).
-define(CONFIRMED_UP, 2#100).

init_per_testcase(_TestCase, Config) ->
    %% Start HPR
    application:ensure_all_started(?APP),
    Config.

end_per_testcase(_TestCase, Config) ->
    application:stop(?APP),
    Config.

-spec join_packet_up(
    Opts :: map()
) -> hpr_packet_up:packet().
join_packet_up(Opts0) ->
    DevNonce = maps:get(dev_nonce, Opts0, crypto:strong_rand_bytes(2)),
    AppKey = maps:get(dev_nonce, Opts0, crypto:strong_rand_bytes(16)),
    MType = ?JOIN_REQUEST,
    MHDRRFU = 0,
    Major = 0,
    AppEUI = maps:get(app_eui, Opts0, 1),
    DevEUI = maps:get(dev_eui, Opts0, 1),
    JoinPayload0 =
        <<MType:3, MHDRRFU:3, Major:2, AppEUI:64/integer-unsigned-little,
            DevEUI:64/integer-unsigned-little, DevNonce:2/binary>>,
    MIC = crypto:macN(cmac, aes_128_cbc, AppKey, JoinPayload0, 4),
    JoinPayload1 = <<JoinPayload0/binary, MIC:4/binary>>,
    Opts1 = maps:put(payload, maps:get(payload, Opts0, JoinPayload1), Opts0),
    PacketUp = hpr_packet_up:new(Opts1),
    SigFun = maps:get(sig_fun, Opts0, fun(_) -> <<"signature">> end),
    hpr_packet_up:sign(PacketUp, SigFun).

-spec uplink_packet_up(
    Opts :: map()
) -> hpr_packet_up:packet().
uplink_packet_up(Opts0) ->
    MType = ?UNCONFIRMED_UP,
    MHDRRFU = 0,
    Major = 0,
    DevAddr = maps:get(devaddr, Opts0, 16#00000000),
    ADR = 0,
    ADRACKReq = 0,
    ACK = 0,
    RFU = 0,
    FCntLow = 1,
    FOptsBin = <<>>,
    FOptsLen = erlang:byte_size(FOptsBin),
    Port = 0,
    Data = <<"dataandmic">>,
    Payload =
        <<MType:3, MHDRRFU:3, Major:2, DevAddr:32/integer-unsigned-little, ADR:1, ADRACKReq:1,
            ACK:1, RFU:1, FOptsLen:4, FCntLow:16/little-unsigned-integer, FOptsBin:FOptsLen/binary,
            Port:8/integer, Data/binary>>,
    Opts1 = maps:put(payload, maps:get(payload, Opts0, Payload), Opts0),
    PacketUp = hpr_packet_up:new(Opts1),
    SigFun = maps:get(sig_fun, Opts0, fun(_) -> <<"signature">> end),
    hpr_packet_up:sign(PacketUp, SigFun).

-spec match_map(map(), any()) -> true | {false, term()}.
match_map(Expected, Got) when is_map(Got) ->
    ESize = maps:size(Expected),
    GSize = maps:size(Got),
    case ESize == GSize of
        false ->
            Flavor =
                case ESize > GSize of
                    true -> {missing_keys, maps:keys(Expected) -- maps:keys(Got)};
                    false -> {extra_keys, maps:keys(Got) -- maps:keys(Expected)}
                end,
            {false, {size_mismatch, {expected, ESize}, {got, GSize}, Flavor}};
        true ->
            maps:fold(
                fun
                    (_K, _V, {false, _} = Acc) ->
                        Acc;
                    (K, V, true) when is_function(V) ->
                        case V(maps:get(K, Got, undefined)) of
                            true ->
                                true;
                            false ->
                                {false, {value_predicate_failed, K, maps:get(K, Got, undefined)}}
                        end;
                    (K, '_', true) ->
                        case maps:is_key(K, Got) of
                            true -> true;
                            false -> {false, {missing_key, K}}
                        end;
                    (K, V, true) when is_map(V) ->
                        match_map(V, maps:get(K, Got, #{}));
                    (K, V0, true) when is_list(V0) ->
                        V1 = lists:zip(lists:seq(1, erlang:length(V0)), lists:sort(V0)),
                        G0 = maps:get(K, Got, []),
                        G1 = lists:zip(lists:seq(1, erlang:length(G0)), lists:sort(G0)),
                        match_map(maps:from_list(V1), maps:from_list(G1));
                    (K, V, true) ->
                        case maps:get(K, Got, undefined) of
                            V -> true;
                            _ -> {false, {value_mismatch, K, V, maps:get(K, Got, undefined)}}
                        end
                end,
                true,
                Expected
            )
    end;
match_map(_Expected, _Got) ->
    {false, not_map}.

wait_until(Fun) ->
    wait_until(Fun, 100, 100).

wait_until(Fun, Retry, Delay) when Retry > 0 ->
    Res = Fun(),
    case Res of
        true ->
            ok;
        {fail, _Reason} = Fail ->
            Fail;
        _ when Retry == 1 ->
            {fail, Res};
        _ ->
            timer:sleep(Delay),
            wait_until(Fun, Retry - 1, Delay)
    end.
