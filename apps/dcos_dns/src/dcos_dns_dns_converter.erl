-module(dcos_dns_dns_converter).
-author("Christopher Meiklejohn <christopher.meiklejohn@gmail.com>").

%% We can't include these because of name clashes.
% -include_lib("kernel/src/inet_dns.hrl").
% -include_lib("kernel/src/inet_res.hrl").

-include_lib("dns/include/dns_terms.hrl").
-include_lib("dns/include/dns_records.hrl").

-export([convert_message/2]).

%% @private
%% @doc
%%
%% Convert a inet_dns response to a dns response so that it's cachable
%% and encodable via the erldns application.
%%
%% This first formal argument is a #dns_rec, from inet_dns, but we can't
%% load because it will cause a conflict with the naming in the dns
%% application used by erldns.
%%
convert_message(#dns_message{} = Message, _Id) ->
    Message;
convert_message(Message, Id) ->
    Header = inet_dns:msg(Message, header),
    Questions = inet_dns:msg(Message, qdlist),
    Answers = inet_dns:msg(Message, anlist),
    Authorities = inet_dns:msg(Message, nslist),
    Resources = inet_dns:msg(Message, arlist),
    #dns_message{
              id = Id,
              qr = inet_dns:header(Header, qr),
              oc = opcode(inet_dns:header(Header, opcode)),
              aa = inet_dns:header(Header, aa),
              tc = inet_dns:header(Header, tc),
              rd = inet_dns:header(Header, rd),
              ra = inet_dns:header(Header, ra),
              ad = 0, %% @todo Could be wrong.
              cd = 0, %% @todo Could be wrong.
              rc = inet_dns:header(Header, rcode), %% @todo Could be wrong.
              qc = 0,
              anc = 0,
              auc = 0,
              adc = 0,
              questions = convert(qdlist, Questions),
              answers = convert(anlist, Answers),
              authority = convert(nslist, Authorities),
              additional = convert(arlist, Resources)}.

%% @private
convert(qdlist, Questions) ->
    [convert(qd, Question) || Question <- Questions];
convert(anlist, Answers) ->
    [convert(an, Answer) || Answer <- Answers];
convert(nslist, _Authorities) ->
    [];
convert(arlist, _Resources) ->
    [];

%% [{dns_query,"google.com",a,in}] -> [{dns_query,<<"2.zk">>,1,1}]
convert(qd, Question) ->
    Domain = inet_dns:dns_query(Question, domain),
    Type = inet_dns:dns_query(Question, type),
    Class = inet_dns:dns_query(Question, class),
    #dns_query{name = name(Domain),
               class = class(Class),
               type = type(Type)};

%% [{dns_rr,"google.com",a,in,0,78,{74,125,239,142},undefined,[],false}] %% ->
%%    [{dns_rr,<<"2.zk">>,1,1,3600,{dns_rrdata_a,{10,0,4,161}}}]
convert(an, Answer) ->
    Domain = inet_dns:rr(Answer, domain),
    Type = inet_dns:rr(Answer, type),
    Class = inet_dns:rr(Answer, class),
    TTL = inet_dns:rr(Answer, ttl),
    Data = inet_dns:rr(Answer, data),
    #dns_rr{name = name(Domain),
            class = class(Class),
            type = type(Type),
            ttl = TTL,
            data = convert(data, Type, Class, Data)}.

%% @private
convert(data, _Type, _Class, {_, _, _, _, _, _, _, _}=IpAddress) ->
    #dns_rrdata_aaaa{ip=IpAddress};
convert(data, _Type, _Class, {_, _, _, _}=IpAddress) ->
    #dns_rrdata_a{ip=IpAddress}.

%% @private
class_to_integer(Bin) when is_binary(Bin) ->
    case Bin of
        ?DNS_CLASS_IN_BSTR -> ?DNS_CLASS_IN_NUMBER;
        ?DNS_CLASS_CS_BSTR -> ?DNS_CLASS_CS_NUMBER;
        ?DNS_CLASS_CH_BSTR -> ?DNS_CLASS_CH_NUMBER;
        ?DNS_CLASS_HS_BSTR -> ?DNS_CLASS_HS_NUMBER;
        ?DNS_CLASS_NONE_BSTR -> ?DNS_CLASS_NONE_NUMBER;
        ?DNS_CLASS_ANY_BSTR -> ?DNS_CLASS_ANY_NUMBER;
        _ -> undefined
    end.

%% @private
type_to_integer(Bin) when is_binary(Bin) ->
    case Bin of
        ?DNS_TYPE_A_BSTR -> ?DNS_TYPE_A_NUMBER;
        ?DNS_TYPE_NS_BSTR -> ?DNS_TYPE_NS_NUMBER;
        ?DNS_TYPE_MD_BSTR -> ?DNS_TYPE_MD_NUMBER;
        ?DNS_TYPE_MF_BSTR -> ?DNS_TYPE_MF_NUMBER;
        ?DNS_TYPE_CNAME_BSTR -> ?DNS_TYPE_CNAME_NUMBER;
        ?DNS_TYPE_SOA_BSTR -> ?DNS_TYPE_SOA_NUMBER;
        ?DNS_TYPE_MB_BSTR -> ?DNS_TYPE_MB_NUMBER;
        ?DNS_TYPE_MG_BSTR -> ?DNS_TYPE_MG_NUMBER;
        ?DNS_TYPE_MR_BSTR -> ?DNS_TYPE_MR_NUMBER;
        ?DNS_TYPE_NULL_BSTR -> ?DNS_TYPE_NULL_NUMBER;
        ?DNS_TYPE_WKS_BSTR -> ?DNS_TYPE_WKS_NUMBER;
        ?DNS_TYPE_PTR_BSTR -> ?DNS_TYPE_PTR_NUMBER;
        ?DNS_TYPE_HINFO_BSTR -> ?DNS_TYPE_HINFO_NUMBER;
        ?DNS_TYPE_MINFO_BSTR -> ?DNS_TYPE_MINFO_NUMBER;
        ?DNS_TYPE_MX_BSTR -> ?DNS_TYPE_MX_NUMBER;
        ?DNS_TYPE_TXT_BSTR -> ?DNS_TYPE_TXT_NUMBER;
        ?DNS_TYPE_RP_BSTR -> ?DNS_TYPE_RP_NUMBER;
        ?DNS_TYPE_AFSDB_BSTR -> ?DNS_TYPE_AFSDB_NUMBER;
        ?DNS_TYPE_X25_BSTR -> ?DNS_TYPE_X25_NUMBER;
        ?DNS_TYPE_ISDN_BSTR -> ?DNS_TYPE_ISDN_NUMBER;
        ?DNS_TYPE_RT_BSTR -> ?DNS_TYPE_RT_NUMBER;
        ?DNS_TYPE_NSAP_BSTR -> ?DNS_TYPE_NSAP_NUMBER;
        ?DNS_TYPE_SIG_BSTR -> ?DNS_TYPE_SIG_NUMBER;
        ?DNS_TYPE_KEY_BSTR -> ?DNS_TYPE_KEY_NUMBER;
        ?DNS_TYPE_PX_BSTR -> ?DNS_TYPE_PX_NUMBER;
        ?DNS_TYPE_GPOS_BSTR -> ?DNS_TYPE_GPOS_NUMBER;
        ?DNS_TYPE_AAAA_BSTR -> ?DNS_TYPE_AAAA_NUMBER;
        ?DNS_TYPE_LOC_BSTR -> ?DNS_TYPE_LOC_NUMBER;
        ?DNS_TYPE_NXT_BSTR -> ?DNS_TYPE_NXT_NUMBER;
        ?DNS_TYPE_EID_BSTR -> ?DNS_TYPE_EID_NUMBER;
        ?DNS_TYPE_NIMLOC_BSTR -> ?DNS_TYPE_NIMLOC_NUMBER;
        ?DNS_TYPE_SRV_BSTR -> ?DNS_TYPE_SRV_NUMBER;
        ?DNS_TYPE_ATMA_BSTR -> ?DNS_TYPE_ATMA_NUMBER;
        ?DNS_TYPE_NAPTR_BSTR -> ?DNS_TYPE_NAPTR_NUMBER;
        ?DNS_TYPE_KX_BSTR -> ?DNS_TYPE_KX_NUMBER;
        ?DNS_TYPE_CERT_BSTR -> ?DNS_TYPE_CERT_NUMBER;
        ?DNS_TYPE_DNAME_BSTR -> ?DNS_TYPE_DNAME_NUMBER;
        ?DNS_TYPE_SINK_BSTR -> ?DNS_TYPE_SINK_NUMBER;
        ?DNS_TYPE_OPT_BSTR -> ?DNS_TYPE_OPT_NUMBER;
        ?DNS_TYPE_APL_BSTR -> ?DNS_TYPE_APL_NUMBER;
        ?DNS_TYPE_DS_BSTR -> ?DNS_TYPE_DS_NUMBER;
        ?DNS_TYPE_SSHFP_BSTR -> ?DNS_TYPE_SSHFP_NUMBER;
        ?DNS_TYPE_IPSECKEY_BSTR -> ?DNS_TYPE_IPSECKEY_NUMBER;
        ?DNS_TYPE_RRSIG_BSTR -> ?DNS_TYPE_RRSIG_NUMBER;
        ?DNS_TYPE_NSEC_BSTR -> ?DNS_TYPE_NSEC_NUMBER;
        ?DNS_TYPE_DNSKEY_BSTR -> ?DNS_TYPE_DNSKEY_NUMBER;
        ?DNS_TYPE_NSEC3_BSTR -> ?DNS_TYPE_NSEC3_NUMBER;
        ?DNS_TYPE_NSEC3PARAM_BSTR -> ?DNS_TYPE_NSEC3PARAM_NUMBER;
        ?DNS_TYPE_DHCID_BSTR -> ?DNS_TYPE_DHCID_NUMBER;
        ?DNS_TYPE_HIP_BSTR -> ?DNS_TYPE_HIP_NUMBER;
        ?DNS_TYPE_NINFO_BSTR -> ?DNS_TYPE_NINFO_NUMBER;
        ?DNS_TYPE_RKEY_BSTR -> ?DNS_TYPE_RKEY_NUMBER;
        ?DNS_TYPE_TALINK_BSTR -> ?DNS_TYPE_TALINK_NUMBER;
        ?DNS_TYPE_SPF_BSTR -> ?DNS_TYPE_SPF_NUMBER;
        ?DNS_TYPE_UINFO_BSTR -> ?DNS_TYPE_UINFO_NUMBER;
        ?DNS_TYPE_UID_BSTR -> ?DNS_TYPE_UID_NUMBER;
        ?DNS_TYPE_GID_BSTR -> ?DNS_TYPE_GID_NUMBER;
        ?DNS_TYPE_UNSPEC_BSTR -> ?DNS_TYPE_UNSPEC_NUMBER;
        ?DNS_TYPE_TKEY_BSTR -> ?DNS_TYPE_TKEY_NUMBER;
        ?DNS_TYPE_TSIG_BSTR -> ?DNS_TYPE_TSIG_NUMBER;
        ?DNS_TYPE_IXFR_BSTR -> ?DNS_TYPE_IXFR_NUMBER;
        ?DNS_TYPE_AXFR_BSTR -> ?DNS_TYPE_AXFR_NUMBER;
        ?DNS_TYPE_MAILB_BSTR -> ?DNS_TYPE_MAILB_NUMBER;
        ?DNS_TYPE_MAILA_BSTR -> ?DNS_TYPE_MAILA_NUMBER;
        ?DNS_TYPE_ANY_BSTR -> ?DNS_TYPE_ANY_NUMBER;
        ?DNS_TYPE_DLV_BSTR -> ?DNS_TYPE_DLV_NUMBER;
        _ -> undefined
    end.

%% @private
opcode_to_integer(Bin) when is_binary(Bin) ->
    case Bin of
        ?DNS_OPCODE_QUERY_BSTR -> ?DNS_OPCODE_QUERY_NUMBER;
        ?DNS_OPCODE_IQUERY_BSTR -> ?DNS_OPCODE_IQUERY_NUMBER;
        ?DNS_OPCODE_STATUS_BSTR -> ?DNS_OPCODE_STATUS_NUMBER;
        ?DNS_OPCODE_UPDATE_BSTR -> ?DNS_OPCODE_UPDATE_NUMBER;
        _ -> undefined
    end.

%% @private
upcase(Y) ->
    Upcase = fun(X) when $a =< X,  X =< $z -> X + $A - $a; (X) -> X end,
    lists:map(Upcase, Y).

%% @private
name(Domain) ->
    list_to_binary(Domain).

%% @private
class(Class) ->
    class_to_integer(list_to_binary(upcase(atom_to_list(Class)))).

%% @private
type(Type) ->
    type_to_integer(list_to_binary(upcase(atom_to_list(Type)))).

%% @private
opcode(Code) ->
    opcode_to_integer(list_to_binary("'" ++ upcase(atom_to_list(Code)) ++ "'")).
