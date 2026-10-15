using System;
using System.Collections.Generic;
using System.IO;

// Pure managed schema fixtures. No service, network, VPN, registry, device or
// filesystem action is started by these tests; paths below are inert strings.
public static class ProviderGeoRuleSetTests {
    private static int passed;
    private const string Namespace = "pgeo-0123456789abcdef-fedcba9876543210-";
    private const string Nonce = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    private const string Install = @"C:\Program Files\HoneyProxyUtility";
    private const string Session = @"C:\ProgramData\HoneyVPN\WindowsTunnel\owned-session";

    public static int Main(string[] args) {
        try {
            PositiveAndBuiltinCompatibility();
            BuiltinRussiaIPv4Only();
            RejectDefinitionInjection();
            RejectReferencesAndNamespaces();
            RejectInvalidPredicates();
            RegexSubset();
            ResourceBudgets();
            if (args.Length == 1) ComposerFixtures(args[0]);
            Console.WriteLine("PASS " + passed + " provider geo typed-inline Windows boundary cases");
            return 0;
        } catch (Exception failure) {
            Console.Error.WriteLine("FAIL " + failure.GetType().Name + ": " + failure.Message);
            return 1;
        }
    }
    private static Dictionary<string, object> M(params object[] pairs) {
        var result = new Dictionary<string, object>(StringComparer.Ordinal);
        for (int i = 0; i < pairs.Length; i += 2) result.Add((string)pairs[i], pairs[i + 1]);
        return result;
    }
    private static Dictionary<string, object> Map(object item) { return SafeTunConfiguration.Map(item); }
    private static Dictionary<string, object> Basic(string field, params object[] values) { return M(field, values); }
    private static Dictionary<string, object> Set(string role, params object[] rules) { return M("type", "inline", "tag", Namespace + role, "rules", rules); }
    private static Dictionary<string, object> Reference(string role) {
        return role == "block" ? M("rule_set", Namespace + role, "action", "reject") : M("rule_set", Namespace + role, "outbound", role);
    }
    private static void Check(bool value, string label) { if (!value) throw new Exception(label); passed++; }
    private static void Reject(Action action, string label) {
        try { action(); } catch (InvalidOperationException failure) {
            if (failure.Message != "startFailed") throw;
            passed++; return;
        }
        throw new Exception("Accepted: " + label);
    }
    private static void Validate(Dictionary<string, object> set) {
        var validator = new ProviderGeoRuleSetValidator();
        validator.AddSet(set);
        var tag = (string)set["tag"];
        var role = tag.Substring(tag.LastIndexOf('-') + 1);
        validator.AddReference(role == "block" ? M("rule_set", tag, "action", "reject") : M("rule_set", tag, "outbound", role));
        validator.Complete();
    }
    private static Dictionary<string, object> Fresh() {
        var resolver = M("server", "local", "strategy", "prefer_ipv4");
        return M(
            "log", M("level", "warn"),
            "dns", M("servers", new object[] {
                M("tag", "remote", "type", "https", "server", "1.1.1.1", "path", "/dns-query", "domain_resolver", resolver, "detour", "proxy"),
                M("tag", "local", "type", "local", "detour", "direct")
            }, "rules", new object[] {}, "final", "remote", "strategy", "prefer_ipv4"),
            "experimental", M("clash_api", M("external_controller", "127.0.0.1:9090"), "cache_file", M("enabled", true, "path", "caller-cache.db")),
            "inbounds", new object[] { M("type", "tun", "tag", "tun-in", "address", new object[] { "198.18.0.1/16", "fdfe:dcba:9876::1/126" }, "auto_route", true, "strict_route", false, "stack", "mixed") },
            "outbounds", new object[] { M("type", "vless", "tag", "proxy", "server", "node.example.test", "server_port", 443, "uuid", "synthetic", "tls", M("enabled", true, "server_name", "cover.example.test")), M("type", "direct", "tag", "direct") },
            "route", M("rules", new object[] { M("action", "sniff"), M("protocol", "dns", "action", "hijack-dns"), M("ip_is_private", true, "outbound", "direct") }, "rule_set", new object[] { M("type", "remote", "tag", "ru", "format", "binary", "url", "https://invalid.example/secret.srs", "path", @"C:\Windows\System32\config\SAM") }, "final", "proxy", "default_domain_resolver", resolver, "auto_detect_interface", true)
        );
    }
    private static Dictionary<string, object> Prepare(Dictionary<string, object> cfg) { return SafeTunConfiguration.Prepare(cfg, Install, Session, Nonce); }
    private static void AppendSet(Dictionary<string, object> cfg, Dictionary<string, object> set) {
        var route = Map(cfg["route"]); var values = new List<object>((object[])route["rule_set"]); values.Add(set); route["rule_set"] = values.ToArray();
    }
    private static void PositiveAndBuiltinCompatibility() {
        var cfg = Fresh();
        var block = Set("block", Basic("domain", "ads.example.test"));
        var proxy = Set("proxy", Basic("domain", "example.test"), Basic("domain_suffix", ".example.test"), Basic("ip_cidr", "10.0.0.0/8"));
        var reverse = Basic("ip_cidr", "192.0.2.0/24", "2001:db8::/32", "2001:db8:0:0:0:0:0:0/32"); reverse["invert"] = true;
        var direct = Set("direct", M("type", "logical", "mode", "or", "rules", new object[] { Basic("domain_keyword", "example"), reverse }));
        AppendSet(cfg, block); AppendSet(cfg, proxy); AppendSet(cfg, direct);
        var route = Map(cfg["route"]);
        route["rules"] = new object[] {
            M("action", "sniff"), M("protocol", "dns", "action", "hijack-dns"), M("ip_is_private", true, "outbound", "direct"),
            Reference("block"), Reference("proxy"), M("rule_set", "ru-blocked", "outbound", "proxy"),
            Reference("direct"), M("rule_set", "ru", "outbound", "direct")
        };
        var before = SafeTunConfiguration.Serializer().Serialize(new object[] { block, proxy, direct, route["rules"] });
        Prepare(cfg);
        Check(before == SafeTunConfiguration.Serializer().Serialize(new object[] { block, proxy, direct, route["rules"] }), "Validated inline rules and route consumers are preserved");
        var builtin = Map(((object[])route["rule_set"])[0]);
        Check((string)builtin["path"] == Path.Combine(Install, "data", "flutter_assets", "assets", "geo", "ru.srs"), "Built-in caller path is rebuilt");
        Check(!builtin.ContainsKey("url") && (string)builtin["type"] == "local", "Built-in remote download remains forbidden to SYSTEM");
        Check((string)Map(Map(cfg["experimental"])["clash_api"])["secret"] == Nonce, "Service still chooses controller secret");
        Check((string)Map(Map(cfg["experimental"])["cache_file"])["path"] == Path.Combine(Session, "cache.db"), "Service still chooses cache path");
        Prepare(Fresh()); passed++;
        var noSets = Fresh(); Map(noSets["route"]).Remove("rule_set"); Prepare(noSets); passed++;
        foreach (var role in new[] { "block", "proxy", "direct" }) { Validate(Set(role, Basic("domain", "node.test"))); passed++; }
        var guards = Fresh(); AppendSet(guards, Set("proxy", Basic("domain", "node.test")));
        Map(guards["route"])["rules"] = new object[] { Reference("proxy") };
        Map(Map(((object[])guards["outbounds"])[0])["tls"])["certificate_path"] = @"C:\Windows\secret";
        Reject(delegate { Prepare(guards); }, "Provider predicates cannot bypass existing TLS file guard");
        var reject = Fresh(); Map(reject["route"])["rules"] = new object[] { M("action", "reject") };
        Reject(delegate { Prepare(reject); }, "Reject action allowed only on a matching provider-block consumer");
    }
    private static void BuiltinRussiaIPv4Only() {
        foreach (var value in new object[] { 4, 4L }) {
            var cfg = Fresh(); var route = Map(cfg["route"]);
            route["rules"] = new object[] { M("rule_set", "ru", "outbound", "direct", "ip_version", value) };
            Prepare(cfg);
            Check(Convert.ToInt64(Map(((object[])route["rules"])[0])["ip_version"]) == 4, "RU IPv4 constraint is retained by the service");
        }
        foreach (var value in new object[] { 0, 6, "4", true, 4.0, 4.0m, null }) {
            var cfg = Fresh(); Map(cfg["route"])["rules"] = new object[] { M("rule_set", "ru", "outbound", "direct", "ip_version", value) };
            Reject(delegate { Prepare(cfg); }, "Only the integral RU IPv4 family is accepted");
        }
        foreach (var rule in new[] {
            M("rule_set", "ru-blocked", "outbound", "direct", "ip_version", 4),
            M("rule_set", "ru", "outbound", "proxy", "ip_version", 4),
            M("ip_is_private", true, "outbound", "direct", "ip_version", 4)
        }) {
            var cfg = Fresh(); Map(cfg["route"])["rules"] = new object[] { rule };
            Reject(delegate { Prepare(cfg); }, "IP family field cannot widen another builtin rule");
        }
    }
    private static void RejectDefinitionInjection() {
        foreach (var field in new[] { "path", "url", "format", "download_detour", "update_interval", "action", "outbound", "__type" }) {
            var set = Set("proxy", Basic("domain", "node.test")); set[field] = @"C:\Windows\System32\config\SAM";
            Reject(delegate { Validate(set); }, "No provider set privileged field " + field);
        }
        foreach (var type in new object[] { "remote", "local", "process", false, null }) {
            var set = Set("proxy", Basic("domain", "node.test")); set["type"] = type;
            Reject(delegate { Validate(set); }, "Provider set type must be inline");
        }
        foreach (var tag in new object[] { "ru", "provider", "pgeo-0123456789ABCDEF-fedcba9876543210-proxy", "pgeo-0123456789abcdef-fedcba987654321-proxy", "pgeo-0123456789abcdef-fedcba9876543210-file", "pgeo-0123456789abcdef-fedcba9876543210-proxy\n" }) {
            var set = Set("proxy", Basic("domain", "node.test")); set["tag"] = tag;
            Reject(delegate { Validate(set); }, "Provider tag must have exact lowerhex namespace and role");
        }
        var cfg = Fresh(); AppendSet(cfg, M("type", "inline", "tag", "ru", "rules", new object[] { Basic("domain", "node.test") }));
        Reject(delegate { Prepare(cfg); }, "Inline cannot replace a fixed built-in set");
    }
    private static void RejectReferencesAndNamespaces() {
        var missing = new ProviderGeoRuleSetValidator();
        Reject(delegate { missing.AddReference(Reference("proxy")); }, "Missing definition");
        var unused = new ProviderGeoRuleSetValidator(); unused.AddSet(Set("proxy", Basic("domain", "node.test")));
        Reject(delegate { unused.Complete(); }, "Unused definition");
        var duplicate = new ProviderGeoRuleSetValidator(); duplicate.AddSet(Set("proxy", Basic("domain", "node.test")));
        Reject(delegate { duplicate.AddSet(Set("proxy", Basic("domain", "other.test"))); }, "Duplicate definition");
        duplicate.AddReference(Reference("proxy"));
        Reject(delegate { duplicate.AddReference(Reference("proxy")); }, "Duplicate consumer");
        foreach (var tag in new[] { "pgeo-1111111111111111-fedcba9876543210-direct", "pgeo-0123456789abcdef-2222222222222222-direct" }) {
            var validator = new ProviderGeoRuleSetValidator(); validator.AddSet(Set("proxy", Basic("domain", "node.test")));
            var other = Set("direct", Basic("domain", "other.test")); other["tag"] = tag;
            Reject(delegate { validator.AddSet(other); }, "No cross-subscription or cross-cache identity mix");
        }
        var order = new ProviderGeoRuleSetValidator(); order.AddSet(Set("block", Basic("domain", "a.test"))); order.AddSet(Set("proxy", Basic("domain", "b.test"))); order.AddReference(Reference("proxy"));
        Reject(delegate { order.AddReference(Reference("block")); }, "Relative provider priority is block/proxy/direct");
        foreach (var role in new[] { "block", "proxy", "direct" }) {
            foreach (var field in new[] { "path", "url", "protocol", "ip_is_private", "tls_fragment", "rules", "__type", role == "block" ? "outbound" : "action" }) {
                var validator = new ProviderGeoRuleSetValidator(); validator.AddSet(Set(role, Basic("domain", "node.test")));
                var reference = Reference(role); reference[field] = "untrusted";
                Reject(delegate { validator.AddReference(reference); }, "Provider consumer exact keys " + field);
            }
            var mismatch = new ProviderGeoRuleSetValidator(); mismatch.AddSet(Set(role, Basic("domain", "node.test")));
            var wrong = Reference(role); wrong[role == "block" ? "action" : "outbound"] = role == "block" ? "sniff" : role == "proxy" ? "direct" : "proxy";
            Reject(delegate { mismatch.AddReference(wrong); }, "Consumer action agrees with namespaced role");
        }
        var missingCfg = Fresh(); Map(missingCfg["route"])["rules"] = new object[] { Reference("proxy") };
        Reject(delegate { Prepare(missingCfg); }, "Missing provider definition rejected through privileged integration");
        var unrecognizedCfg = Fresh(); Map(unrecognizedCfg["route"])["rules"] = new object[] { M("rule_set", "arbitrary-provider", "outbound", "proxy") };
        Reject(delegate { Prepare(unrecognizedCfg); }, "Arbitrary off-tag set rejected through privileged integration");
    }
    private static void RejectInvalidPredicates() {
        foreach (var field in new[] { "action", "outbound", "rule_set", "path", "url", "process_name", "source_ip_cidr", "port", "__type" }) {
            var basic = Basic("domain", "node.test"); basic[field] = "untrusted";
            Reject(delegate { Validate(Set("proxy", basic)); }, "No arbitrary policy field inside provider headless rule " + field);
        }
        foreach (var value in new object[] { new object[] {}, "node.test", new object[] { null }, new object[] { 42 }, new object[] { "" }, new object[] { "node\ttest" }, new object[] { "node.test\0" }, new object[] { "\ud800" } }) {
            var basic = M("domain", value);
            Reject(delegate { Validate(Set("proxy", basic)); }, "Nonempty typed string arrays required");
        }
        foreach (var domain in new[] { "https://node.test", "file:///secret", "node.test/path", "user@node.test", "node.test:443", "node..test", "-node.test", "node-.test", new string('a', 64) + ".test", ".node.test", "node.test." }) {
            Reject(delegate { Validate(Set("proxy", Basic("domain", domain))); }, "Exact domain predicate syntax");
        }
        Validate(Set("proxy", Basic("domain_suffix", ".node.test"))); passed++;
        foreach (var cidr in new[] { "10.1/16", "10.0.0.1/8", "01.0.0.0/8", "0x7f000001/32", "127.1/32", "127.0.0.1/033", "192.0.2.0/-1", "192.0.2.0/33", "192.0.2.0", "2001:db8::1/32", "fe80::%2/64", "[2001:db8::]/32", "::/129", "::/+0", "::/00" }) {
            Reject(delegate { Validate(Set("direct", Basic("ip_cidr", cidr))); }, "CIDR must have plain parsed address, canonical prefix and no host bits");
        }
        foreach (var cidr in new[] { "0.0.0.0/0", "192.0.2.12/32", "192.0.2.0/24", "::/0", "2001:db8::/32", "2001:db8::1/128", "::ffff:192.0.2.0/120" }) {
            Validate(Set("direct", Basic("ip_cidr", cidr))); passed++;
        }
        Reject(delegate { Validate(Set("proxy", M("invert", true))); }, "Invert cannot become an empty match-all rule");
        Reject(delegate { Validate(Set("proxy", M("domain", new object[] { "node.test" }, "invert", "true"))); }, "Invert is a boolean");
        foreach (var invert in new[] { false, true }) {
            Reject(delegate { Validate(Set("proxy", M("domain", new object[] { "node.test" }, "ip_cidr", new object[] { "192.0.2.0/24" }, "invert", invert))); }, "No mixed domain AND IP atom");
        }
        foreach (var mode in new[] { "and", "xor", "OR" }) {
            Reject(delegate { Validate(Set("proxy", M("type", "logical", "mode", mode, "rules", new object[] { Basic("domain", "node.test") }))); }, "Only one-level logical OR is accepted");
        }
        var nested = M("type", "logical", "mode", "or", "rules", new object[] { Basic("domain", "node.test") });
        Reject(delegate { Validate(Set("proxy", M("type", "logical", "mode", "or", "rules", new object[] { nested }))); }, "Nested logical structure is rejected");
        Reject(delegate { Validate(Set("proxy", M("type", "logical", "mode", "or", "rules", new object[] {}))); }, "No empty logical match-all");
        Reject(delegate { Validate(Set("proxy", M("type", "logical", "mode", "or", "rules", new object[] { Basic("domain", "node.test") }, "invert", true))); }, "No uncontracted logical inversion");
    }
    private static void RegexSubset() {
        foreach (var regex in new[] { @"(^|\.)example\.com$", @"^([a-z0-9-]+\.)?example\.com$", @"(?i)^(?:api|cdn)\d{1,3}\.test$", @"(?i-s:example)\.test", @"^[[:alpha:]][[:alnum:]_-]*\.test$", @"^\x41{1,1000}\x{42}+$", @"^\Afoo\z$", @"^a{0,}b{2,4}?$", @"(a{100}){10}", @"(a{1000}){0,}", @"(a{1000})*" }) {
            Validate(Set("proxy", Basic("domain_regex", regex))); passed++;
        }
        foreach (var regex in new[] { @"(a)\1", @"\k<name>", @"\g{1}", @"(?=example)", @"(?!example)", @"(?<=example)", @"(?<!example)", @"(?P<name>example)", @"(?<name>example)", @"(?>example)", @"(?x)example", @"(?i-)example", @"(?-:example)", @"a{1001}", @"a{2,1001}", @"a{2,1}", @"a{01}", @"a**", @"a++", @"[z-a]", @"[a-\d]", @"[abc", @"[[:unknown:]]", @"(abc", @"abc)", @"\q", @"\x1", @"\x{110000}", @"\x{d800}", @"\p{L}", @"\Qexample\E", @"^*", @"abc\", @"(a{1000}){2}", @"(a{100}){11}", @"((a{10}){10}){11}" }) {
            Reject(delegate { Validate(Set("proxy", Basic("domain_regex", regex))); }, "Unsupported or malformed RE2 regex subset");
        }
        Reject(delegate { Validate(Set("proxy", Basic("domain_regex", new string('a', 513)))); }, "Regex text cap");
        Validate(Set("proxy", Basic("domain_regex", new string('a', 512)))); passed++;
        Validate(Set("proxy", Basic("domain_regex", @"((a{1000}){0}){1000}"))); passed++;
        foreach (var regex in new[] { @"((){1000}){2}", @"((?i){1000}){2}", @"((a{0}){1000}){2}", @"((a{1000}){0,}){2}" }) {
            Reject(delegate { Validate(Set("proxy", Basic("domain_regex", regex))); }, "Nested empty or open repeat follows RE2 count validation");
        }
    }
    private static void ResourceBudgets() {
        var sixtyFour = new object[64]; for (int i = 0; i < sixtyFour.Length; i++) sixtyFour[i] = Basic("domain", "node.test");
        Validate(Set("proxy", sixtyFour)); passed++;
        Validate(Set("proxy", M("type", "logical", "mode", "or", "rules", sixtyFour))); passed++;
        var sixtyFive = new object[65]; for (int i = 0; i < sixtyFive.Length; i++) sixtyFive[i] = Basic("domain", "node.test");
        Reject(delegate { Validate(Set("proxy", sixtyFive)); }, "At most 64 root atoms");
        Reject(delegate { Validate(Set("proxy", M("type", "logical", "mode", "or", "rules", sixtyFour), Basic("domain", "node.test"))); }, "Logical children consume the same total atom budget");
        var maximum = new object[30000]; for (int i = 0; i < maximum.Length; i++) maximum[i] = "a";
        Validate(Set("proxy", M("domain_keyword", maximum))); passed++;
        var acrossSets = new ProviderGeoRuleSetValidator(); acrossSets.AddSet(Set("proxy", M("domain_keyword", maximum)));
        Reject(delegate { acrossSets.AddSet(Set("direct", Basic("domain_keyword", "a"))); }, "String budget shared across sets");
        var oversized = new object[1300]; for (int i = 0; i < oversized.Length; i++) oversized[i] = new string('a', 512);
        Reject(delegate { Validate(Set("proxy", M("domain_keyword", oversized))); }, "640 KiB total serialized provider JSON budget");
        var unicodeOversized = new object[700]; for (int i = 0; i < unicodeOversized.Length; i++) unicodeOversized[i] = new string('\u4e00', 512);
        Reject(delegate { Validate(Set("proxy", M("domain_keyword", unicodeOversized))); }, "UTF-8 bytes, not UTF-16 characters, count toward JSON budget");
        var longDomain = new string('a', 63) + "." + new string('b', 63) + "." + new string('c', 63) + "." + new string('d', 61);
        Check(longDomain.Length == 253, "Domain fixture reaches exact 253-character limit");
        Validate(Set("proxy", Basic("domain", longDomain))); passed++;
        Reject(delegate { Validate(Set("proxy", Basic("domain_suffix", "." + longDomain))); }, "Leading suffix dot is included in text cap");
        var cfg = Fresh(); var ordinary = new List<object>(); for (int i = 0; i < 16; i++) ordinary.Add(M("action", "sniff"));
        foreach (var role in new[] { "block", "proxy", "direct" }) { AppendSet(cfg, Set(role, Basic("domain", "node.test"))); ordinary.Add(Reference(role)); }
        Map(cfg["route"])["rules"] = ordinary.ToArray(); Prepare(cfg); passed++;
        var allSets = Fresh();
        Map(allSets["route"])["rule_set"] = new object[] {
            M("type", "local", "tag", "ru-blocked", "format", "binary"),
            M("type", "local", "tag", "ru-blocked-community", "format", "binary"),
            M("type", "local", "tag", "re-filter", "format", "binary"),
            M("type", "local", "tag", "ru", "format", "binary")
        };
        foreach (var role in new[] { "block", "proxy", "direct" }) AppendSet(allSets, Set(role, Basic("domain", "node.test")));
        Map(allSets["route"])["rules"] = new object[] { Reference("block"), Reference("proxy"), Reference("direct") };
        Prepare(allSets); passed++;
        var eight = new List<object>((object[])Map(allSets["route"])["rule_set"]); eight.Add(Set("proxy", Basic("domain", "other.test")));
        Map(allSets["route"])["rule_set"] = eight.ToArray();
        Reject(delegate { Prepare(allSets); }, "Four built-in plus at most three provider definitions");
        ordinary.Insert(0, M("action", "sniff")); Map(cfg["route"])["rules"] = ordinary.ToArray();
        Reject(delegate { Prepare(cfg); }, "Provider allowance cannot expand 16 existing route entries");
        var seventeen = Fresh(); var tooMany = new object[17]; for (int i = 0; i < tooMany.Length; i++) tooMany[i] = M("action", "sniff"); Map(seventeen["route"])["rules"] = tooMany;
        Reject(delegate { Prepare(seventeen); }, "Original built-in rule cap retained without providers");
    }
    private static void ComposerFixtures(string directory) {
        int count = 0;
        foreach (var file in Directory.GetFiles(directory, "windowsTunnel-providerGeo-*.json")) {
            var cfg = Map(SafeTunConfiguration.Serializer().DeserializeObject(File.ReadAllText(file)));
            Prepare(cfg); count++;
        }
        Check(count > 0, "Expected locally generated typed provider composer fixtures");
        Console.WriteLine("PASS " + count + " generated provider Windows TUN composer fixtures");
    }
}
