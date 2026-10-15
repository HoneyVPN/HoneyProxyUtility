using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

// This is the SYSTEM boundary, not merely a client-side schema check. Unknown
// options fail closed, and filesystem/controller locations are rebuilt here.
public static class SafeTunConfiguration {
    public const int MaxMessageBytes = 1048576;
    public static JavaScriptSerializer Serializer() {
        return new JavaScriptSerializer { MaxJsonLength = MaxMessageBytes, RecursionLimit = 16 };
    }
    private static readonly string[] RuleTags = { "ru-blocked", "ru-blocked-community", "re-filter", "ru" };

    public static Dictionary<string, object> Prepare(object input, string install, string session, string nonce) {
        if (!Regex.IsMatch(nonce ?? "", "^[a-f0-9]{64}$")) Fail();
        var cfg = Map(input);
        Keys(cfg, "log,dns,experimental,inbounds,endpoints,outbounds,route");
        var log = Map(Required(cfg, "log")); Keys(log, "level");
        Choice(log, "level", "trace,debug,info,warn,error,fatal,panic");
        var dnsStrategy = ValidateDns(Map(Required(cfg, "dns")));
        var inboundList = List(Required(cfg, "inbounds"), 1, 1);
        var tun = Map(inboundList[0]);
        Keys(tun, "type,tag,address,auto_route,strict_route,stack,route_exclude_address");
        Equal(tun, "type", "tun"); Equal(tun, "tag", "tun-in");
        Equal(tun, "auto_route", true); Equal(tun, "strict_route", false);
        Choice(tun, "stack", "system,gvisor,mixed");
        var addresses = Strings(Required(tun, "address"), 2, 2, 80);
        if (addresses[0] != "198.18.0.1/16" || addresses[1] != "fdfe:dcba:9876::1/126") Fail();
        if (tun.ContainsKey("route_exclude_address")) {
            foreach (var cidr in Strings(tun["route_exclude_address"], 0, 32, 80)) {
                var parts = cidr.Split('/'); IPAddress address;
                if (parts.Length != 2 || parts[1] != "32" || !IPAddress.TryParse(parts[0], out address) ||
                    address.AddressFamily != System.Net.Sockets.AddressFamily.InterNetwork) Fail();
            }
        }
        var outbounds = List(Required(cfg, "outbounds"), 1, 2);
        bool ordinaryProxy = false; bool direct = false;
        foreach (var item in outbounds) {
            var outbound = Map(item);
            if (GetText(outbound, "type", 32) == "direct") {
                Keys(outbound, "type,tag"); Equal(outbound, "tag", "direct");
                if (direct) Fail(); direct = true;
            } else { if (ordinaryProxy) Fail(); ValidateProxy(outbound); ordinaryProxy = true; }
        }
        if (!direct) Fail();
        if (cfg.ContainsKey("endpoints")) {
            if (ordinaryProxy) Fail();
            var endpoints = List(cfg["endpoints"], 1, 1); ValidateWireGuard(Map(endpoints[0]), dnsStrategy);
        } else if (!ordinaryProxy) Fail();
        ValidateRoute(Map(Required(cfg, "route")), install, dnsStrategy);
        var experimental = Map(Required(cfg, "experimental"));
        Keys(experimental, "clash_api,cache_file");
        var api = Map(Required(experimental, "clash_api"));
        Keys(api, "external_controller,secret");
        Equal(api, "external_controller", "127.0.0.1:9090");
        // Neither controller location nor authentication comes from the caller.
        experimental["clash_api"] = new Dictionary<string, object> {
            { "external_controller", "127.0.0.1:9090" }, { "secret", nonce }
        };
        if (experimental.ContainsKey("cache_file")) {
            var cache = Map(experimental["cache_file"]); Keys(cache, "enabled,path");
            Equal(cache, "enabled", true); OptionalText(cache, "path", 32768);
            experimental["cache_file"] = new Dictionary<string, object> {
                { "enabled", true }, { "path", Path.Combine(session, "cache.db") }
            };
        }
        return cfg;
    }

    private static string ValidateDns(Dictionary<string, object> dns) {
        Keys(dns, "servers,rules,final,strategy"); Equal(dns, "final", "remote");
        Choice(dns, "strategy", "ipv4_only,ipv6_only,prefer_ipv4");
        var strategy = GetText(dns, "strategy", 32);
        bool remote = false; bool local = false;
        foreach (var item in List(Required(dns, "servers"), 2, 2)) {
            var server = Map(item);
            var tag = GetText(server, "tag", 16);
            if (tag == "local") {
                Keys(server, "tag,type,detour");
                if (local) Fail(); local = true;
                Equal(server, "type", "local"); Equal(server, "detour", "direct");
            } else if (tag == "remote") {
                Keys(server, "tag,type,server,server_port,path,domain_resolver,detour");
                if (remote) Fail(); remote = true; Equal(server, "detour", "proxy");
                Choice(server, "type", "https,tls"); Host(server, "server");
                if (Uri.CheckHostName(GetText(server, "server", 256)) == UriHostNameType.Unknown) Fail();
                if (server.ContainsKey("server_port")) Number(server, "server_port", 1, 65535);
                ValidateDomainResolver(Map(Required(server, "domain_resolver")), strategy);
                if (GetText(server, "type", 16) == "https") ValidateDnsPath(GetText(server, "path", 4096));
                else if (server.ContainsKey("path")) Fail();
            } else Fail();
        }
        if (!remote || !local) Fail();
        List(Required(dns, "rules"), 0, 0);
        return strategy;
    }

    private static void ValidateDomainResolver(Dictionary<string, object> resolver, string strategy) {
        Keys(resolver, "server,strategy"); Equal(resolver, "server", "local"); Equal(resolver, "strategy", strategy);
    }

    private static void ValidateDnsPath(string path) {
        if (!path.StartsWith("/", StringComparison.Ordinal) || path.IndexOf('?') >= 0 ||
            path.IndexOf('#') >= 0 || path.IndexOf('\\') >= 0) Fail();
        for (int i = 0; i < path.Length; i++) {
            if (path[i] <= 31 || path[i] == 127) Fail();
            if (path[i] == '%') {
                if (i + 2 >= path.Length || !Uri.IsHexDigit(path[i + 1]) || !Uri.IsHexDigit(path[i + 2])) Fail();
                i += 2;
            }
        }
    }

    private static void ValidateProxy(Dictionary<string, object> proxy) {
        var kind = GetText(proxy, "type", 32);
        var common = "type,tag,server,server_port,bind_interface,tls,transport,multiplex";
        switch (kind) {
            case "vless": Keys(proxy, common + ",uuid,flow,encryption"); GetText(proxy, "uuid", 128);
                OptionalText(proxy, "flow", 128); OptionalText(proxy, "encryption", 16384); break;
            case "vmess": Keys(proxy, common + ",uuid,alter_id,security"); GetText(proxy, "uuid", 128);
                Number(proxy, "alter_id", 0, 65535); GetText(proxy, "security", 128); break;
            case "trojan": Keys(proxy, common + ",password"); GetText(proxy, "password", 16384); break;
            case "shadowsocks": Keys(proxy, common + ",method,password"); GetText(proxy, "method", 128);
                GetText(proxy, "password", 16384); break;
            case "hysteria2": Keys(proxy, common + ",password,server_ports,hop_interval,obfs");
                GetText(proxy, "password", 16384); OptionalText(proxy, "hop_interval", 128);
                if (proxy.ContainsKey("server_ports")) Strings(proxy["server_ports"], 1, 128, 32);
                if (proxy.ContainsKey("obfs")) { var obfs = Map(proxy["obfs"]); Keys(obfs, "type,password");
                    Equal(obfs, "type", "salamander"); GetText(obfs, "password", 16384); }
                break;
            case "tuic": Keys(proxy, common + ",uuid,password,congestion_control,udp_relay_mode");
                GetText(proxy, "uuid", 128); GetText(proxy, "password", 16384);
                Choice(proxy, "congestion_control", "cubic,new_reno,bbr"); Choice(proxy, "udp_relay_mode", "native,quic"); break;
            default: Fail(); break;
        }
        Equal(proxy, "tag", "proxy"); Host(proxy, "server"); Number(proxy, "server_port", 1, 65535);
        OptionalText(proxy, "bind_interface", 256);
        if (proxy.ContainsKey("tls")) ValidateTls(Map(proxy["tls"]));
        if (proxy.ContainsKey("transport")) ValidateTransport(Map(proxy["transport"]));
        if (proxy.ContainsKey("multiplex")) {
            var mux = Map(proxy["multiplex"]); Keys(mux, "enabled,protocol,max_connections,min_streams");
            Equal(mux, "enabled", true); Equal(mux, "protocol", "smux");
            Number(mux, "max_connections", 1, 16); Number(mux, "min_streams", 1, 16);
        }
    }

    private static void ValidateTls(Dictionary<string, object> tls) {
        // certificate/key/ECH/session-ticket file options are intentionally not
        // part of the allowlist: a caller cannot make SYSTEM read such a file.
        Keys(tls, "enabled,server_name,insecure,alpn,utls,reality"); Equal(tls, "enabled", true);
        OptionalText(tls, "server_name", 256); OptionalBoolean(tls, "insecure");
        if (tls.ContainsKey("alpn")) Strings(tls["alpn"], 0, 16, 128);
        if (tls.ContainsKey("utls")) { var utls = Map(tls["utls"]); Keys(utls, "enabled,fingerprint");
            Equal(utls, "enabled", true); GetText(utls, "fingerprint", 128); }
        if (tls.ContainsKey("reality")) { var reality = Map(tls["reality"]); Keys(reality, "enabled,public_key,short_id");
            Equal(reality, "enabled", true); GetText(reality, "public_key", 256); GetText(reality, "short_id", 128); }
    }

    private static void ValidateTransport(Dictionary<string, object> transport) {
        var kind = GetText(transport, "type", 32);
        switch (kind) {
            case "ws": Keys(transport, "type,path,headers");
                if (transport.ContainsKey("headers")) { var headers = Map(transport["headers"]); Keys(headers, "Host"); Host(headers, "Host"); } break;
            case "http": Keys(transport, "type,path,host");
                if (transport.ContainsKey("host")) Strings(transport["host"], 0, 8, 256); break;
            case "grpc": Keys(transport, "type,service_name"); GetText(transport, "service_name", 4096); break;
            case "httpupgrade": Keys(transport, "type,path,host"); OptionalText(transport, "host", 256); break;
            case "xhttp": Keys(transport, "type,path,host,mode,x_padding_bytes"); OptionalText(transport, "host", 256);
                Choice(transport, "mode", "auto,packet-up,stream-up,stream-one"); GetText(transport, "x_padding_bytes", 128); break;
            default: Fail(); break;
        }
        OptionalText(transport, "path", 8192);
    }

    private static void ValidateWireGuard(Dictionary<string, object> endpoint, string dnsStrategy) {
        Keys(endpoint, "type,tag,system,domain_resolver,address,private_key,listen_port,mtu,peers,amnezia,bind_interface");
        Equal(endpoint, "type", "wireguard"); Equal(endpoint, "tag", "proxy");
        if (endpoint.ContainsKey("system")) Equal(endpoint, "system", false);
        ValidateDomainResolver(Map(Required(endpoint, "domain_resolver")), dnsStrategy);
        GetText(endpoint, "private_key", 256); Number(endpoint, "listen_port", 0, 0); Number(endpoint, "mtu", 576, 9000);
        OptionalText(endpoint, "bind_interface", 256);
        foreach (var cidr in Strings(Required(endpoint, "address"), 1, 16, 80)) Cidr(cidr);
        foreach (var item in List(Required(endpoint, "peers"), 1, 1)) {
            var peer = Map(item); Keys(peer, "address,port,public_key,allowed_ips,pre_shared_key");
            Host(peer, "address"); Number(peer, "port", 1, 65535); GetText(peer, "public_key", 256);
            OptionalText(peer, "pre_shared_key", 256);
            var allowed = Strings(Required(peer, "allowed_ips"), 2, 2, 80);
            if (allowed[0] != "0.0.0.0/0" || allowed[1] != "::/0") Fail();
        }
        if (endpoint.ContainsKey("amnezia")) {
            var awg = Map(endpoint["amnezia"]); Keys(awg, "jc,jmin,jmax,s1,s2,s3,s4,h1,h2,h3,h4");
            foreach (var item in awg) ScalarNumber(item.Value, 0, UInt32.MaxValue);
        }
    }

    private static void ValidateRoute(Dictionary<string, object> route, string install, string dnsStrategy) {
        Keys(route, "rules,rule_set,final,default_domain_resolver,auto_detect_interface"); Equal(route, "final", "proxy");
        ValidateDomainResolver(Map(Required(route, "default_domain_resolver")), dnsStrategy);
        Equal(route, "auto_detect_interface", true);
        var provider = new ProviderGeoRuleSetValidator();
        var builtinSets = new List<Dictionary<string, object>>();
        if (route.ContainsKey("rule_set")) {
            var seen = new HashSet<string>(StringComparer.Ordinal);
            foreach (var item in List(route["rule_set"], 1, 7)) {
                var rules = Map(item);
                var tag = GetText(rules, "tag", 64);
                if (!seen.Add(tag)) Fail();
                if (ProviderGeoRuleSetValidator.IsProviderTag(tag)) {
                    provider.AddSet(rules);
                    continue;
                }
                Keys(rules, "type,tag,format,path,url,download_detour,update_interval");
                if (Array.IndexOf(RuleTags, tag) < 0 || builtinSets.Count >= 4) Fail();
                Choice(rules, "type", "local,remote"); Equal(rules, "format", "binary");
                OptionalText(rules, "path", 32768); OptionalText(rules, "url", 4096);
                OptionalText(rules, "download_detour", 16); OptionalText(rules, "update_interval", 64);
                builtinSets.Add(rules);
            }
        }
        int builtinRuleCount = 0;
        foreach (var item in List(Required(route, "rules"), 1, 19)) {
            var rule = Map(item);
            if (rule.ContainsKey("rule_set") && ProviderGeoRuleSetValidator.IsProviderTag(GetText(rule, "rule_set", 64))) {
                provider.AddReference(rule);
                continue;
            }
            if (++builtinRuleCount > 16) Fail();
            Keys(rule, "action,protocol,ip_is_private,rule_set,outbound,ip_version,tls_fragment,tls_fragment_fallback_delay");
            if (rule.ContainsKey("action")) Choice(rule, "action", "sniff,route-options,hijack-dns");
            if (rule.ContainsKey("protocol")) Equal(rule, "protocol", "dns");
            OptionalBoolean(rule, "ip_is_private"); OptionalBoolean(rule, "tls_fragment");
            if (rule.ContainsKey("ip_version")) {
                var family = Required(rule, "ip_version");
                if (!(family is int) && !(family is long)) Fail();
                if (Convert.ToInt64(family) != 4) Fail();
                Equal(rule, "rule_set", "ru"); Equal(rule, "outbound", "direct");
            }
            OptionalText(rule, "tls_fragment_fallback_delay", 32);
            if (rule.ContainsKey("outbound")) Choice(rule, "outbound", "proxy,direct");
            if (rule.ContainsKey("rule_set") && Array.IndexOf(RuleTags, GetText(rule, "rule_set", 64)) < 0) Fail();
        }
        provider.Complete();
        foreach (var rules in builtinSets) {
            var tag = GetText(rules, "tag", 64);
            rules.Clear(); rules["type"] = "local"; rules["tag"] = tag; rules["format"] = "binary";
            rules["path"] = Path.Combine(install, "data", "flutter_assets", "assets", "geo", tag + ".srs");
        }
    }

    public static Dictionary<string, object> Map(object value) {
        var map = value as Dictionary<string, object>; if (map == null || map.Count > 64) Fail(); return map;
    }
    public static object Required(Dictionary<string, object> map, string key) {
        object value; if (!map.TryGetValue(key, out value) || value == null) Fail(); return value;
    }
    public static void Keys(Dictionary<string, object> map, string names) {
        var allowed = new HashSet<string>(names.Split(','), StringComparer.Ordinal);
        foreach (var key in map.Keys) if (!allowed.Contains(key)) Fail();
    }
    public static string GetText(Dictionary<string, object> map, string key, int max) {
        var text = Required(map, key) as string;
        if (text == null || text.Length > max || text.IndexOf('\0') >= 0 || text.IndexOf('\r') >= 0 || text.IndexOf('\n') >= 0) Fail();
        return text;
    }
    private static void OptionalText(Dictionary<string, object> map, string key, int max) { if (map.ContainsKey(key)) GetText(map, key, max); }
    private static void OptionalBoolean(Dictionary<string, object> map, string key) { if (map.ContainsKey(key) && !(map[key] is bool)) Fail(); }
    private static void Equal(Dictionary<string, object> map, string key, object value) { if (!Object.Equals(Required(map, key), value)) Fail(); }
    private static void Choice(Dictionary<string, object> map, string key, string values) { if (Array.IndexOf(values.Split(','), GetText(map, key, 128)) < 0) Fail(); }
    private static void Number(Dictionary<string, object> map, string key, long min, long max) { ScalarNumber(Required(map, key), min, max); }
    private static void ScalarNumber(object value, long min, long max) {
        if (!(value is int) && !(value is long) && !(value is decimal)) Fail();
        var number = Convert.ToDecimal(value); if (number < min || number > max || Decimal.Truncate(number) != number) Fail();
    }
    private static object[] List(object value, int min, int max) {
        var list = value as object[]; if (list == null || list.Length < min || list.Length > max) Fail(); return list;
    }
    private static string[] Strings(object value, int min, int max, int maxLength) {
        var input = List(value, min, max); var output = new string[input.Length];
        for (int i = 0; i < input.Length; i++) {
            var text = input[i] as string; if (text == null || text.Length > maxLength || text.IndexOf('\0') >= 0 || text.IndexOf('\r') >= 0 || text.IndexOf('\n') >= 0) Fail();
            output[i] = text;
        }
        return output;
    }
    private static void Host(Dictionary<string, object> map, string key) {
        var host = GetText(map, key, 256);
        if (String.IsNullOrWhiteSpace(host) || host.IndexOf('/') >= 0 || host.IndexOf('\\') >= 0 || host.IndexOf('@') >= 0 || host.IndexOf(' ') >= 0) Fail();
    }
    private static void Cidr(string value) {
        var pieces = value.Split('/'); IPAddress ip; int prefix;
        if (pieces.Length != 2 || !IPAddress.TryParse(pieces[0], out ip) || !Int32.TryParse(pieces[1], out prefix) ||
            prefix < 0 || prefix > (ip.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork ? 32 : 128)) Fail();
    }
    private static void Fail() { throw new InvalidOperationException("startFailed"); }
}
