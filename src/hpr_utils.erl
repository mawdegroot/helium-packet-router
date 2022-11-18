-module(hpr_utils).

-export([
    gateway_name/1,
    gateway_mac/1,
    int_to_hex/1,
    bin_to_hex/1,
    hex_to_bin/1,
    pubkeybin_to_mac/1,
    net_id_display/1
]).

-spec gateway_name(PubKeyBin :: libp2p_crypto:pubkey_bin() | string()) -> string().
gateway_name(PubKeyBin) when is_binary(PubKeyBin) ->
    B58 = libp2p_crypto:bin_to_b58(PubKeyBin),
    gateway_name(B58);
gateway_name(B58) when is_list(B58) ->
    {ok, Name} = erl_angry_purple_tiger:animal_name(B58),
    Name.

-spec gateway_mac(PubKeyBin :: libp2p_crypto:pubkey_bin()) -> string().
gateway_mac(PubKeyBin) ->
    erlang:binary_to_list(binary:encode_hex(pubkeybin_to_mac(PubKeyBin))).

-spec int_to_hex(Integer :: integer()) -> string().
int_to_hex(Integer) ->
    io_lib:format("~.16B", [Integer]).

-spec bin_to_hex(binary()) -> string().
bin_to_hex(Bin) ->
    lists:flatten([[io_lib:format("~2.16.0b", [X]) || <<X:8>> <= Bin]]).

-spec hex_to_bin(binary()) -> binary().
hex_to_bin(Hex) ->
    <<
        begin
            {ok, [V], []} = io_lib:fread("~16u", [X, Y]),
            <<V:8/integer-little>>
        end
     || <<X:8/integer, Y:8/integer>> <= Hex
    >>.

-spec pubkeybin_to_mac(binary()) -> binary().
pubkeybin_to_mac(PubKeyBin) ->
    <<(xxhash:hash64(PubKeyBin)):64/unsigned-integer>>.

-spec net_id_display(non_neg_integer()) -> string().
net_id_display(Num) ->
    string:right(erlang:integer_to_list(Num, 16), 6, $0).
