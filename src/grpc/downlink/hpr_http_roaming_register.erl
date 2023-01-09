-module(hpr_http_roaming_register).

-include("../autogen/downlink_pb.hrl").

-export([
    new/2,
    region/1,
    timestamp/1,
    signer/1,
    signature/1,
    sign/2,
    verify/1
]).

-type http_roaming_register() :: #http_roaming_register_v1_pb{}.

-export_type([http_roaming_register/0]).

-spec new(Region :: atom(), Signer :: libp2p_crypto:pubkey_bin()) -> http_roaming_register().
new(Region, Signer) ->
    #http_roaming_register_v1_pb{
        region = Region,
        timestamp = erlang:system_time(millisecond),
        signer = Signer
    }.

-spec region(HttpRoamingReg :: http_roaming_register()) -> atom().
region(HttpRoamingReg) ->
    HttpRoamingReg#http_roaming_register_v1_pb.region.

-spec timestamp(HttpRoamingReg :: http_roaming_register()) -> non_neg_integer().
timestamp(HttpRoamingReg) ->
    HttpRoamingReg#http_roaming_register_v1_pb.timestamp.

-spec signer(HttpRoamingReg :: http_roaming_register()) -> libp2p_crypto:pubkey_bin().
signer(HttpRoamingReg) ->
    HttpRoamingReg#http_roaming_register_v1_pb.signer.

-spec signature(HttpRoamingReg :: http_roaming_register()) -> binary().
signature(HttpRoamingReg) ->
    HttpRoamingReg#http_roaming_register_v1_pb.signature.

-spec sign(HttpRoamingReg :: http_roaming_register(), SigFun :: fun()) ->
    http_roaming_register().
sign(HttpRoamingReg, SigFun) ->
    EncodedHttpRoamingReg = downlink_pb:encode_msg(
        HttpRoamingReg, http_roaming_register_v1_pb
    ),
    HttpRoamingReg#http_roaming_register_v1_pb{
        signature = SigFun(EncodedHttpRoamingReg)
    }.

-spec verify(HttpRoamingReg :: http_roaming_register()) -> boolean().
verify(HttpRoamingReg) ->
    EncodedHttpRoamingReg = downlink_pb:encode_msg(
        HttpRoamingReg#http_roaming_register_v1_pb{
            signature = <<>>
        },
        http_roaming_register_v1_pb
    ),
    libp2p_crypto:verify(
        EncodedHttpRoamingReg,
        ?MODULE:signature(HttpRoamingReg),
        libp2p_crypto:bin_to_pubkey(?MODULE:signer(HttpRoamingReg))
    ).

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

region_test() ->
    Region = 'EU868',
    ?assertEqual(
        Region,
        ?MODULE:region(?MODULE:new(Region, <<"Signer">>))
    ),
    ok.

timestamp_test() ->
    Signer = <<"Signer">>,
    Timestamp = erlang:system_time(millisecond),
    ?assert(Timestamp =< ?MODULE:timestamp(?MODULE:new('EU868', Signer))),
    ok.

signer_test() ->
    Signer = <<"Signer">>,
    ?assertEqual(
        Signer,
        ?MODULE:signer(?MODULE:new('EU868', Signer))
    ),
    ok.

signature_test() ->
    Signer = <<"Signer">>,
    ?assertEqual(
        <<>>,
        ?MODULE:signature(?MODULE:new('EU868', Signer))
    ),
    ok.

sign_verify_test() ->
    #{public := PubKey, secret := PrivKey} = libp2p_crypto:generate_keys(ecc_compact),
    SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
    Signer = libp2p_crypto:pubkey_to_bin(PubKey),
    HttpRoamingReg = ?MODULE:new('EU868', Signer),

    SignedHttpRoamingReg = ?MODULE:sign(HttpRoamingReg, SigFun),

    ?assert(?MODULE:verify(SignedHttpRoamingReg)),
    ok.

-endif.