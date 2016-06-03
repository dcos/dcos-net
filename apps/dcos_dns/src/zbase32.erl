%%% @author  John Kemp <john@jkemp.net> [http://jkemp.net/]
%%% @doc Implementation of z-base-32 in Erlang.
%%% @reference See <a href="http://zooko.com/repos/z-base-32/base32/DESIGN">Z-Base-32</a>. Find the code <a href="http://github.com/frumioj/erl-base">here</a>.
%%% @since 26 August 2009
%%%
%%% @copyright 2009 John Kemp, All rights reserved. Open source, BSD License
%%% @version 1.1
%%%

%%%
%%% Copyright (c) 2009 John Kemp
%%% All rights reserved.
%%%
%%% Redistribution and use in source and binary forms, with or without
%%% modification, are permitted provided that the following conditions
%%% are met:
%%% 1. Redistributions of source code must retain the above copyright
%%%    notice, this list of conditions and the following disclaimer.
%%% 2. Redistributions in binary form must reproduce the above copyright
%%%    notice, this list of conditions and the following disclaimer in the
%%%    documentation and/or other materials provided with the distribution.
%%% 3. Neither the name of the copyright holder nor the names of contributors
%%%    may be used to endorse or promote products derived from this software
%%%    without specific prior written permission.
%%% 
%%% THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTOR(S) ``AS IS'' AND
%%% ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
%%% IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
%%% ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTOR(S) BE LIABLE
%%% FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
%%% DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
%%% OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
%%% HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
%%% LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
%%% OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
%%% SUCH DAMAGE.
%%%

-module(zbase32).

-export([encode/1, decode/1,
	 encode_to_string/1, decode_to_string/1]).

%%-------------------------------------------------------------------------
%% The following type is a subtype of string() for return values
%% of (some) functions of this module.
%%-------------------------------------------------------------------------

-type ascii_string() :: [1..255].

%%-------------------------------------------------------------------------
%% encode_to_string(ASCII) -> Base32String
%%	ASCII - string() | binary()
%%	Base32String - string()
%%                                   
%% Description: Encodes a plain ASCII string (or binary) into base32.
%%-------------------------------------------------------------------------

-spec encode_to_string(string() | binary()) -> ascii_string().

encode_to_string(Bin) when is_binary(Bin) ->
    encode_to_string(binary_to_list(Bin));
encode_to_string(List) when is_list(List) ->
    encode_l(List).

%%-------------------------------------------------------------------------
%% encode(ASCII) -> Base32
%%	ASCII - string() | binary()
%%	Base32 - binary()
%%                                   
%% Description: Encodes a plain ASCII string (or binary) into base32.
%%-------------------------------------------------------------------------

-spec encode(string() | binary()) -> binary().

encode(Bin) when is_binary(Bin) ->
    encode_binary(Bin);
encode(List) when is_list(List) ->
    list_to_binary(encode_l(List)).

-spec encode_l(string()) -> ascii_string().

encode_l([]) ->
    [];
encode_l([A]) ->
    [b32e(A bsr 3),
     b32e((A band 7) bsl 2)];
encode_l([A,B]) ->
    [b32e(A bsr 3),
     b32e(((A band 7) bsl 2) bor ((B band 192) bsr 6)), 
     b32e((B band 62) bsr 1),
     b32e((B band 1) bsl 4)];
encode_l([A,B,C]) ->
    [b32e(A bsr 3),
     b32e(((A band 7) bsl 2) bor ((B band 192) bsr 6)), 
     b32e((B band 62) bsr 1),
     b32e(((B band 1) bsl 4) bor (C bsr 4)),
     b32e((C band 15) bsl 1)];
encode_l([A,B,C,D]) ->
    [b32e(A bsr 3),
     b32e(((A band 7) bsl 2) bor ((B band 192) bsr 6)),
     b32e((B band 62) bsr 1),
     b32e(((B band 1) bsl 4) bor (C bsr 4)),
     b32e(((C band 15) bsl 1) bor (D band 128)),
     b32e((D band 124) bsr 2),
     b32e((D band 3) bsl 3)];

encode_l([A,B,C,D,E]) ->
    [b32e(A bsr 3),
     b32e(((A band 7) bsl 2) bor ((B band 192) bsr 6)),
     b32e((B band 62) bsr 1),
     b32e(((B band 1) bsl 4) bor (C bsr 4)),
     b32e(((C band 15) bsl 1) bor (D band 128)),
     b32e((D band 124) bsr 2),
     b32e(((D band 3) bsl 3) bor (E bsr 5)),
     b32e(E band 31)];

encode_l([A,B,C,D,E|Ls]) ->
    BB = (A bsl 32) bor (B bsl 24) bor (C bsl 16) bor (D bsl 8) bor E,
    [b32e(BB bsr 35),
     b32e((BB bsr 30) band 31), 
     b32e((BB bsr 25) band 31),
     b32e((BB bsr 20) band 31),
     b32e((BB bsr 15) band 31),
     b32e((BB bsr 10) band 31),
     b32e((BB bsr 5) band 31),
     b32e(BB band 31) | encode_l(Ls)].

%% @TODO: support non-byte lengths (ie. 10 bits)?

encode_binary(Bin) ->
    Split = 5*(byte_size(Bin) div 5),
    <<Main0:Split/binary,Rest/binary>> = Bin,
    Main = << <<(b32e(E)):8>> || <<E:5>> <= Main0 >>,
    case Rest of
	<<A:5,B:5,C:5,D:5,E:5,F:5,G:2>> ->
	    <<Main/binary,(b32e(A)):8,(b32e(B)):8,(b32e(C)):8,(b32e(D)):8,(b32e(E)):8,(b32e(F)):8,(b32e(G bsl 3)):8>>;
	<<A:5,B:5,C:5,D:5,E:4>> ->
	    <<Main/binary,(b32e(A)):8,(b32e(B)):8,(b32e(C)):8,(b32e(D)):8,(b32e(E bsl 1)):8>>;
	<<A:5,B:5,C:5,D:1>> ->
	    <<Main/binary,(b32e(A)):8,(b32e(B)):8,(b32e(C)):8,(b32e(D bsl 4)):8>>;
	<<A:5,B:3>> ->
	    <<Main/binary,(b32e(A)):8,(b32e(B bsl 2)):8>>;
	<<>> ->
	    Main
    end.

-spec decode(string() | binary()) -> binary().

decode(Bin) when is_binary(Bin) ->
    list_to_binary(decode_l(binary_to_list(Bin)));
decode(List) when is_list(List) ->
    list_to_binary(decode_l(List)).

-spec decode_to_string(string() | binary()) -> string().

decode_to_string(Bin) when is_binary(Bin) ->
    decode_l(binary_to_list(Bin));
decode_to_string(List) when is_list(List) ->
    decode_l(List).

%% One-based decode map.
-define(DECODE_MAP,
	{bad,bad,bad,bad,bad,bad,bad,bad,ws,ws,bad,bad,ws,bad,bad, %1-15
	 bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,bad, %16-31
	 ws,bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,63, %32-47
	 bad,bad,bad,25,26,27,30,29,7,31,bad,bad,bad,bad,bad,bad, %48-63
	 bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,bad, %64-79
	 bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,
	 bad,24,1,12,3,8,5,6,28,21,9,10,18,11,2,16, %96-111
	 13,14,4,22,17,19,bad,20,15,0,23,bad,bad,bad,bad,bad, %112-127
	 bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,
	 bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,
	 bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,
	 bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,
	 bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,
	 bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,
	 bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,
	 bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,bad,bad}).

%% @TODO: support other lengths of encoded strings (for different
%% sub-byte binary lengths)

decode_l([A,B]) ->
    [((b32d(A) bsl 3) bor (b32d(B) bsr 2))];

decode_l([A,B,C,D]) ->
    [(b32d(A) bsl 3) bor (b32d(B) bsr 2),
     ((b32d(B) band 3) bsl 6) bor (b32d(C) bsl 1) bor (b32d(D) bsr 4)];

decode_l([A,B,C,D,E]) ->
    [(b32d(A) bsl 3) bor (b32d(B) bsr 2),
     ((b32d(B) band 3) bsl 6) bor (b32d(C) bsl 1) bor (b32d(D) bsr 4),
     ((b32d(D) band 15) bsl 4) bor (b32d(E) bsr 1)];

decode_l([A,B,C,D,E,F,G]) ->
    [(b32d(A) bsl 3) bor (b32d(B) bsr 2),
     ((b32d(B) band 3) bsl 6) bor (b32d(C) bsl 1) bor (b32d(D) bsr 4),
     ((b32d(D) band 15) bsl 4) bor (b32d(E) bsr 1),
     ((b32d(E) band 1) bsl 7) bor (b32d(F) bsl 2) bor (b32d(G) bsr 3)];

decode_l([A,B,C,D,E,F,G,H]) ->
    [(b32d(A) bsl 3) bor (b32d(B) bsr 2),
     ((b32d(B) band 3) bsl 6) bor (b32d(C) bsl 1) bor (b32d(D) bsr 4),
     ((b32d(D) band 15) bsl 4) bor (b32d(E) bsr 1),
     ((b32d(E) band 1) bsl 7) bor (b32d(F) bsl 2) bor (b32d(G) bsr 3),
     ((b32d(G) band 7) bsl 5) bor b32d(H)];

decode_l([A,B,C,D,E,F,G,H | List]) ->
    [decode_l([A,B,C,D,E,F,G,H]) ++ decode_l(List)].    

%% accessors 
b32e(X) ->
    element(X+1,
	    {$y, $b, $n, $d, $r, $f, $g, $8, $e, $j, $k, $m, $c, $p,
	     $q, $x, $o, $t, $l, $u, $w, $i, $s, $z, $a, $3,
	     $4, $5, $h, $7, $6, $9}).



b32d(X) ->
    b32d_ok(element(X, ?DECODE_MAP)).

b32d_ok(I) when is_integer(I) -> I.
