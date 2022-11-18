%%%-------------------------------------------------------------------
%%% @author jonathanruttenberg
%%% @copyright (C) 2022, Nova Labs
%%% @doc
%%%
%%% @end
%%% Created : 17. Sep 2022 3:40 PM
%%%-------------------------------------------------------------------
-module(hpr_http_roaming).
-author("jonathanruttenberg").

%% Uplinking
-export([
    make_uplink_payload/6,
    select_best/1
]).

%% Downlinking
-export([
    handle_message/1,
    handle_prstart_ans/1,
    handle_xmitdata_req/1
]).

%% Tokens
-export([
    make_uplink_token/5,
    parse_uplink_token/1
]).

-export([new_packet/2]).

-define(NO_ROAMING_AGREEMENT, <<"NoRoamingAgreement">>).

%% Default Delays
-define(JOIN1_DELAY, 5_000_000).
-define(JOIN2_DELAY, 6_000_000).
-define(RX2_DELAY, 2_000_000).
-define(RX1_DELAY, 1_000_000).

%% Roaming MessageTypes
-type prstart_req() :: map().
-type prstart_ans() :: map().
-type xmitdata_req() :: map().
-type xmitdata_ans() :: map().

-type netid_num() :: non_neg_integer().
-type gateway_time() :: non_neg_integer().

-type downlink() :: {
    PubKeyBin :: libp2p_crypto:pubkey_bin(),
    PacketDown :: hpr_packet_down:downlink_packet()
}.

-type region() :: atom().
-type token() :: binary().
-type dest_url() :: binary().
-type flow_type() :: sync | async.

-define(TOKEN_SEP, <<"::">>).

-record(packet, {
    packet_up :: hpr_packet_up:packet(),
    gateway_time :: gateway_time()
}).
-type packet() :: #packet{}.

-type downlink_packet() :: hpr_packet_down:packet().

-export_type([
    netid_num/0,
    packet/0,
    gateway_time/0,
    downlink/0,
    downlink_packet/0
]).

%% ------------------------------------------------------------------
%% Uplink
%% ------------------------------------------------------------------

-spec new_packet(
    PacketUp :: hpr_packet_up:packet(),
    GatewayTime :: gateway_time()
) -> #packet{}.
new_packet(PacketUp, GatewayTime) ->
    #packet{
        packet_up = PacketUp,
        gateway_time = GatewayTime
    }.

-spec make_uplink_payload(
    NetID :: netid_num(),
    Uplinks :: list(packet()),
    TransactionID :: integer(),
    DedupWindowSize :: non_neg_integer(),
    Destination :: binary(),
    FlowType :: sync | async
) -> prstart_req().
make_uplink_payload(
    NetID,
    Uplinks,
    TransactionID,
    DedupWindowSize,
    Destination,
    FlowType
) ->
    #packet{
        packet_up = PacketUp,
        gateway_time = GatewayTime
    } = select_best(Uplinks),
    Payload = hpr_packet_up:payload(PacketUp),
    PacketTime = hpr_packet_up:timestamp(PacketUp),

    PubKeyBin = hpr_packet_up:gateway(PacketUp),
    Region = hpr_packet_up:region(PacketUp),
    DataRate = hpr_packet_up:datarate(PacketUp),
    Frequency = hpr_packet_up:frequency_mhz(PacketUp),

    {RoutingKey, RoutingValue} = routing_key_and_value(PacketUp),

    Token = make_uplink_token(PubKeyBin, Region, PacketTime, Destination, FlowType),

    VersionBase = #{
        'ProtocolVersion' => <<"1.1">>,
        'SenderNSID' => <<"">>,
        'DedupWindowSize' => DedupWindowSize
    },

    VersionBase#{
        'SenderID' => <<"0xC00053">>,
        'ReceiverID' => hpr_http_roaming_utils:hexstring(NetID),
        'TransactionID' => TransactionID,
        'MessageType' => <<"PRStartReq">>,
        'PHYPayload' => hpr_http_roaming_utils:binary_to_hexstring(Payload),
        'ULMetaData' => #{
            RoutingKey => RoutingValue,
            'DataRate' => hpr_lorawan:datarate_to_index(Region, DataRate),
            'ULFreq' => Frequency,
            'RecvTime' => hpr_http_roaming_utils:format_time(GatewayTime),
            'RFRegion' => Region,
            'FNSULToken' => Token,
            'GWCnt' => erlang:length(Uplinks),
            'GWInfo' => lists:map(fun gw_info/1, Uplinks)
        }
    }.

-spec routing_key_and_value(PacketUp :: hpr_packet_up:packet()) -> {atom(), binary()}.
routing_key_and_value(PacketUp) ->
    PacketType = hpr_packet_up:type(PacketUp),
    {RoutingKey, RoutingValue} =
        case PacketType of
            {join_req, {_AppEUI, DevEUI}} ->
                {'DevEUI', encode_deveui(DevEUI)};
            {uplink, DevAddr} ->
                {'DevAddr', encode_devaddr(DevAddr)}
        end,
    {RoutingKey, RoutingValue}.

%% ------------------------------------------------------------------
%% Downlink
%% ------------------------------------------------------------------

-spec handle_message(prstart_ans() | xmitdata_req()) ->
    ok
    | {downlink, xmitdata_ans(), downlink(), {dest_url(), flow_type()}}
    | {join_accept, downlink()}
    | {error, any()}.
handle_message(#{<<"MessageType">> := MT} = M) ->
    case MT of
        <<"PRStartAns">> ->
            handle_prstart_ans(M);
        <<"XmitDataReq">> ->
            handle_xmitdata_req(M);
        _Err ->
            throw({bad_message, M})
    end.

-spec handle_prstart_ans(prstart_ans()) -> ok | {join_accept, downlink()} | {error, any()}.
handle_prstart_ans(#{
    <<"Result">> := #{<<"ResultCode">> := <<"Success">>},
    <<"MessageType">> := <<"PRStartAns">>,

    <<"PHYPayload">> := Payload,
    <<"DevEUI">> := _DevEUI,

    <<"DLMetaData">> := #{
        <<"DLFreq1">> := FrequencyMhz,
        <<"DataRate1">> := DR,
        <<"FNSULToken">> := Token
    } = DLMeta
}) ->
    {ok, PubKeyBin, Region, PacketTime, _, _} = parse_uplink_token(Token),

    DownlinkPacket = hpr_packet_down:new_downlink(
        hpr_http_roaming_utils:hexstring_to_binary(Payload),
        hpr_http_roaming_utils:uint32(PacketTime + ?JOIN1_DELAY),
        FrequencyMhz * 1000000,
        hpr_lorawan:index_to_datarate(Region, DR),
        rx2_from_dlmetadata(DLMeta, PacketTime, Region, ?JOIN2_DELAY)
    ),
    {join_accept, {PubKeyBin, DownlinkPacket}};
handle_prstart_ans(#{
    <<"Result">> := #{<<"ResultCode">> := <<"Success">>},
    <<"MessageType">> := <<"PRStartAns">>,

    <<"PHYPayload">> := Payload,
    <<"DevEUI">> := _DevEUI,

    <<"DLMetaData">> := #{
        <<"DLFreq2">> := FrequencyMhz,
        <<"DataRate2">> := DR,
        <<"FNSULToken">> := Token
    }
}) ->
    case parse_uplink_token(Token) of
        {error, _} = Err ->
            Err;
        {ok, PubKeyBin, Region, PacketTime, _, _} ->
            DataRate = hpr_lorawan:index_to_datarate(Region, DR),
            DownlinkPacket = hpr_packet_down:new_downlink(
                hpr_http_roaming_utils:hexstring_to_binary(Payload),
                hpr_http_roaming_utils:uint32(PacketTime + ?JOIN2_DELAY),
                FrequencyMhz * 1000000,
                DataRate,
                undefined
            ),
            {join_accept, {PubKeyBin, DownlinkPacket}}
    end;
handle_prstart_ans(#{
    <<"MessageType">> := <<"PRStartAns">>,
    <<"Result">> := #{<<"ResultCode">> := <<"Success">>}
}) ->
    ok;
handle_prstart_ans(#{
    <<"MessageType">> := <<"PRStartAns">>,
    <<"Result">> := #{<<"ResultCode">> := ?NO_ROAMING_AGREEMENT},
    <<"SenderID">> := SenderID
}) ->
    NetID = hpr_http_roaming_utils:hexstring_to_int(SenderID),

    lager:info("stop buying [net_id: ~p] [reason: no roaming agreement]", [NetID]),

    ok;
handle_prstart_ans(#{
    <<"MessageType">> := <<"PRStartAns">>,
    <<"Result">> := #{<<"ResultCode">> := ResultCode} = Result,
    <<"SenderID">> := SenderID
}) ->
    %% Catchall for properly formatted messages with results we don't yet support
    lager:info(
        "[result: ~p] [sender: ~p] [description: ~p]",
        [ResultCode, SenderID, maps:get(<<"Description">>, Result, "No Description")]
    ),
    ok;
handle_prstart_ans(Res) ->
    lager:error("unrecognized prstart_ans: ~p", [Res]),
    throw({bad_response, Res}).

-spec handle_xmitdata_req(xmitdata_req()) ->
    {downlink, xmitdata_ans(), downlink(), {dest_url(), flow_type()}} | {error, any()}.
%% Class A ==========================================
handle_xmitdata_req(#{
    <<"MessageType">> := <<"XmitDataReq">>,
    <<"ProtocolVersion">> := ProtocolVersion,
    <<"TransactionID">> := IncomingTransactionID,
    <<"SenderID">> := SenderID,
    <<"PHYPayload">> := Payload,
    <<"DLMetaData">> := #{
        <<"ClassMode">> := <<"A">>,
        <<"FNSULToken">> := Token,
        <<"DataRate1">> := DR1,
        <<"DLFreq1">> := FrequencyMhz1,
        <<"RXDelay1">> := Delay0
    } = DLMeta
}) ->
    PayloadResponse = #{
        'ProtocolVersion' => ProtocolVersion,
        'MessageType' => <<"XmitDataAns">>,
        'ReceiverID' => SenderID,
        'SenderID' => <<"0xC00053">>,
        'Result' => #{'ResultCode' => <<"Success">>},
        'TransactionID' => IncomingTransactionID,
        'DLFreq1' => FrequencyMhz1
    },

    %% Make downlink packet
    case parse_uplink_token(Token) of
        {error, _} = Err ->
            Err;
        {ok, PubKeyBin, Region, PacketTime, DestURL, FlowType} ->
            DataRate1 = hpr_lorawan:index_to_datarate(Region, DR1),
            Delay1 =
                case Delay0 of
                    N when N < 2 -> 1;
                    N -> N
                end,
            DownlinkPacket = hpr_packet_down:new_downlink(
                hpr_http_roaming_utils:hexstring_to_binary(Payload),
                hpr_http_roaming_utils:uint32(PacketTime + (Delay1 * ?RX1_DELAY)),
                FrequencyMhz1 * 1000000,
                DataRate1,
                rx2_from_dlmetadata(DLMeta, PacketTime, Region, ?RX2_DELAY)
            ),
            {downlink, PayloadResponse, {PubKeyBin, DownlinkPacket}, {DestURL, FlowType}}
    end;
%% Class C ==========================================
handle_xmitdata_req(#{
    <<"MessageType">> := <<"XmitDataReq">>,
    <<"ProtocolVersion">> := ProtocolVersion,
    <<"TransactionID">> := IncomingTransactionID,
    <<"SenderID">> := SenderID,
    <<"PHYPayload">> := Payload,
    <<"DLMetaData">> := #{
        <<"ClassMode">> := DeviceClass,
        <<"FNSULToken">> := Token,
        <<"DLFreq2">> := FrequencyMhz,
        <<"DataRate2">> := DR,
        <<"RXDelay1">> := Delay0
    }
}) ->
    PayloadResponse = #{
        'ProtocolVersion' => ProtocolVersion,
        'MessageType' => <<"XmitDataAns">>,
        'ReceiverID' => SenderID,
        'SenderID' => <<"0xC00053">>,
        'Result' => #{'ResultCode' => <<"Success">>},
        'TransactionID' => IncomingTransactionID,
        'DLFreq2' => FrequencyMhz
    },

    case parse_uplink_token(Token) of
        {error, _} = Err ->
            Err;
        {ok, PubKeyBin, Region, PacketTime, DestURL, FlowType} ->
            DataRate = hpr_lorawan:index_to_datarate(Region, DR),
            Delay1 =
                case Delay0 of
                    N when N < 2 -> 1;
                    N -> N
                end,
            Timeout =
                case DeviceClass of
                    <<"C">> ->
                        immediate;
                    <<"A">> ->
                        hpr_http_roaming_utils:uint32(
                            PacketTime + (Delay1 * ?RX1_DELAY) + ?RX1_DELAY
                        )
                end,
            DownlinkPacket = hpr_packet_down:new_downlink(
                hpr_http_roaming_utils:hexstring_to_binary(Payload),
                Timeout,
                FrequencyMhz * 1000000,
                DataRate,
                undefined
            ),
            {downlink, PayloadResponse, {PubKeyBin, DownlinkPacket}, {DestURL, FlowType}}
    end.

-spec rx2_from_dlmetadata(
    DownlinkMetadata :: map(), non_neg_integer(), region(), non_neg_integer()
) ->
    undefined | packet_router_pb:window_v1_pb().
rx2_from_dlmetadata(
    #{
        <<"DataRate2">> := DR,
        <<"DLFreq2">> := FrequencyMhz
    },
    PacketTime,
    Region,
    Timeout
) ->
    try hpr_lorawan:index_to_datarate(Region, DR) of
        DataRate ->
            hpr_packet_down:window(
                hpr_http_roaming_utils:uint32(PacketTime + Timeout),
                FrequencyMhz * 1000000,
                DataRate
            )
    catch
        Err ->
            lager:warning("skipping rx2, bad dr_to_datar(~p, ~p) [err: ~p]", [Region, DR, Err]),
            undefined
    end;
rx2_from_dlmetadata(_, _, _, _) ->
    lager:debug("skipping rx2, no details"),
    undefined.

%% ------------------------------------------------------------------
%% Tokens
%% ------------------------------------------------------------------

-spec make_uplink_token(
    PubKeyBin :: libp2p_crypto:pubkey_bin(), region(), non_neg_integer(), binary(), atom()
) -> token().
make_uplink_token(PubKeyBin, Region, PacketTime, DestURL, FlowType) ->
    Parts = [
        PubKeyBin,
        erlang:atom_to_binary(Region),
        erlang:integer_to_binary(PacketTime),
        DestURL,
        erlang:atom_to_binary(FlowType)
    ],
    Token0 = lists:join(?TOKEN_SEP, Parts),
    Token1 = erlang:iolist_to_binary(Token0),
    hpr_http_roaming_utils:binary_to_hexstring(Token1).

-spec parse_uplink_token(token()) ->
    {ok, libp2p_crypto:pubkey_bin(), region(), non_neg_integer(), dest_url(), flow_type()}
    | {error, any()}.
parse_uplink_token(<<"0x", Token/binary>>) ->
    parse_uplink_token(Token);
parse_uplink_token(Token) ->
    Bin = binary:decode_hex(Token),
    case binary:split(Bin, ?TOKEN_SEP, [global]) of
        [PubKeyBin, RegionBin, PacketTimeBin, DestURLBin, FlowTypeBin] ->
            Region = erlang:binary_to_existing_atom(RegionBin),
            PacketTime = erlang:binary_to_integer(PacketTimeBin),
            FlowType = erlang:binary_to_existing_atom(FlowTypeBin),
            {ok, PubKeyBin, Region, PacketTime, DestURLBin, FlowType};
        _ ->
            {error, malformed_token}
    end.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec select_best(list(packet())) -> packet().
select_best(Copies) ->
    [Best | _] = lists:sort(
        fun(#packet{packet_up = PacketUpA}, #packet{packet_up = PacketUpB}) ->
            RSSIA = hpr_packet_up:rssi(PacketUpA),
            RSSIB = hpr_packet_up:rssi(PacketUpB),
            RSSIA > RSSIB
        end,
        Copies
    ),
    Best.

-spec gw_info(packet()) -> map().
gw_info(#packet{packet_up = PacketUp}) ->
    PubKeyBin = hpr_packet_up:gateway(PacketUp),
    Region = hpr_packet_up:region(PacketUp),

    SNR = hpr_packet_up:snr(PacketUp),
    RSSI = hpr_packet_up:rssi(PacketUp),

    GW = #{
        'ID' => hpr_http_roaming_utils:binary_to_hexstring(hpr_utils:pubkeybin_to_mac(PubKeyBin)),
        'RFRegion' => Region,
        'RSSI' => RSSI,
        'SNR' => SNR,
        'DLAllowed' => true
    },
    GW.

-spec encode_deveui(non_neg_integer()) -> binary().
encode_deveui(Num) ->
    hpr_http_roaming_utils:hexstring(Num, 16).

-spec encode_devaddr(non_neg_integer()) -> binary().
encode_devaddr(Num) ->
    hpr_http_roaming_utils:hexstring(Num, 8).

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

encode_deveui_test() ->
    ?assertEqual(encode_deveui(0), <<"0x0000000000000000">>),
    ok.

encode_devaddr_test() ->
    ?assertEqual(encode_devaddr(0), <<"0x00000000">>),
    ok.

-endif.
