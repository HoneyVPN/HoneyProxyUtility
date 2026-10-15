using System;
using System.Collections.Generic;
using System.Globalization;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.RegularExpressions;

// The authenticated service accepts provider predicates, never a provider's
// file, download, executable, outbound, or arbitrary sing-box configuration.
// These checks remain independent of the client cache and routing compiler.
public sealed class ProviderGeoRuleSetValidator {
    public const int MaxProviderJsonBytes = 640 * 1024;
    public const int MaxProviderSets = 3;
    public const int MaxAtomsPerSet = 64;
    public const int MaxStrings = 30000;
    private static readonly Regex TagPattern = new Regex(@"\Apgeo-([a-f0-9]{16})-([a-f0-9]{16})-(block|proxy|direct)\z", RegexOptions.CultureInvariant);
    private readonly Dictionary<string, string> roles = new Dictionary<string, string>(StringComparer.Ordinal);
    private readonly HashSet<string> referenced = new HashSet<string>(StringComparer.Ordinal);
    private readonly List<object> definitions = new List<object>();
    private readonly List<object> references = new List<object>();
    private string identity;
    private int stringCount;
    private int lastRole = -1;

    public static bool IsProviderTag(string tag) { return tag != null && TagPattern.IsMatch(tag); }

    public void AddSet(Dictionary<string, object> set) {
        SafeTunConfiguration.Keys(set, "type,tag,rules");
        if (!Object.Equals(SafeTunConfiguration.Required(set, "type"), "inline")) Fail();
        var tag = SafeTunConfiguration.GetText(set, "tag", 64);
        var match = TagPattern.Match(tag);
        if (!match.Success || roles.Count >= MaxProviderSets || roles.ContainsKey(tag)) Fail();
        var currentIdentity = match.Groups[1].Value + ":" + match.Groups[2].Value;
        if (identity != null && identity != currentIdentity) Fail();
        identity = currentIdentity;
        int atoms = 0;
        foreach (var item in Items(SafeTunConfiguration.Required(set, "rules"), MaxAtomsPerSet)) {
            var rule = SafeTunConfiguration.Map(item);
            if (rule.ContainsKey("type")) {
                SafeTunConfiguration.Keys(rule, "type,mode,rules");
                if (!Object.Equals(rule["type"], "logical") || !Object.Equals(SafeTunConfiguration.Required(rule, "mode"), "or")) Fail();
                foreach (var child in Items(SafeTunConfiguration.Required(rule, "rules"), MaxAtomsPerSet)) {
                    ValidateBasic(SafeTunConfiguration.Map(child), ref atoms);
                }
            } else ValidateBasic(rule, ref atoms);
        }
        roles.Add(tag, match.Groups[3].Value);
        definitions.Add(set);
        CheckJsonBudget();
    }

    public void AddReference(Dictionary<string, object> rule) {
        var tag = SafeTunConfiguration.GetText(rule, "rule_set", 64);
        string role;
        if (!roles.TryGetValue(tag, out role) || !referenced.Add(tag)) Fail();
        int priority = role == "block" ? 0 : role == "proxy" ? 1 : 2;
        if (priority <= lastRole) Fail();
        lastRole = priority;
        if (role == "block") {
            SafeTunConfiguration.Keys(rule, "rule_set,action");
            if (!Object.Equals(SafeTunConfiguration.Required(rule, "action"), "reject")) Fail();
        } else {
            SafeTunConfiguration.Keys(rule, "rule_set,outbound");
            if (!Object.Equals(SafeTunConfiguration.Required(rule, "outbound"), role)) Fail();
        }
        references.Add(rule);
        CheckJsonBudget();
    }

    public void Complete() {
        if (referenced.Count != roles.Count) Fail();
        CheckJsonBudget();
    }

    private void CheckJsonBudget() {
        var payload = new Dictionary<string, object> { { "rule_set", definitions.ToArray() }, { "rules", references.ToArray() } };
        var json = SafeTunConfiguration.Serializer().Serialize(payload);
        if (Encoding.UTF8.GetByteCount(json) > MaxProviderJsonBytes) Fail();
    }

    private void ValidateBasic(Dictionary<string, object> rule, ref int atoms) {
        SafeTunConfiguration.Keys(rule, "domain,domain_suffix,domain_keyword,domain_regex,ip_cidr,invert");
        if (++atoms > MaxAtomsPerSet) Fail();
        if (rule.ContainsKey("invert") && !(rule["invert"] is bool)) Fail();
        // Inline entries form a union; a mixed domain/IP atom would instead
        // introduce an AND condition, and inversion would negate both sides.
        if (rule.ContainsKey("ip_cidr")) {
            foreach (var key in rule.Keys) if (key != "ip_cidr" && key != "invert") Fail();
        }
        bool predicate = false;
        foreach (var field in new[] { "domain", "domain_suffix", "domain_keyword", "domain_regex", "ip_cidr" }) {
            if (!rule.ContainsKey(field)) continue;
            predicate = true;
            foreach (var value in Items(rule[field], MaxStrings)) {
                if (++stringCount > MaxStrings) Fail();
                var text = value as string;
                int limit = field == "ip_cidr" ? 80 : field == "domain" || field == "domain_suffix" ? 253 : 512;
                Text(text, limit);
                if (field == "domain" || field == "domain_suffix") Domain(text, field == "domain_suffix");
                else if (field == "ip_cidr") Cidr(text);
                else if (field == "domain_regex") new SafeRegexSyntax(text).Validate();
            }
        }
        if (!predicate) Fail();
    }

    private static object[] Items(object value, int max) {
        var items = value as object[];
        if (items == null || items.Length < 1 || items.Length > max) Fail();
        return items;
    }

    private static void Text(string text, int max) {
        if (text == null || text.Length < 1 || text.Length > max || String.IsNullOrWhiteSpace(text)) Fail();
        for (int i = 0; i < text.Length; i++) {
            if (Char.IsControl(text[i])) Fail();
            if (Char.IsHighSurrogate(text[i])) {
                if (++i >= text.Length || !Char.IsLowSurrogate(text[i])) Fail();
            } else if (Char.IsLowSurrogate(text[i])) Fail();
        }
    }

    private static void Domain(string text, bool suffix) {
        if (suffix && text.StartsWith(".", StringComparison.Ordinal)) text = text.Substring(1);
        foreach (var label in text.Split('.')) {
            if (label.Length < 1 || label.Length > 63 || !AlphaNumeric(label[0]) || !AlphaNumeric(label[label.Length - 1])) Fail();
            foreach (var c in label) if (!AlphaNumeric(c) && c != '-') Fail();
        }
    }
    private static bool AlphaNumeric(char c) { return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9'; }

    private static void Cidr(string text) {
        var parts = text.Split('/');
        if (parts.Length != 2 || !Regex.IsMatch(parts[1], @"\A(?:0|[1-9][0-9]{0,2})\z", RegexOptions.CultureInvariant)) Fail();
        // TryParse alone also accepts IPv4 shorthand/hex and IPv6 scope IDs.
        // Keep only a plain address and a canonical network/prefix pair.
        foreach (var c in parts[0]) if (!(c >= '0' && c <= '9') && !(c >= 'a' && c <= 'f') && !(c >= 'A' && c <= 'F') && c != '.' && c != ':') Fail();
        if (parts[0].IndexOf(':') < 0) ValidateIpv4(parts[0]);
        else if (parts[0].IndexOf('.') >= 0) ValidateIpv4(parts[0].Substring(parts[0].LastIndexOf(':') + 1));
        IPAddress address = null;
        int prefix = 0;
        if (!IPAddress.TryParse(parts[0], out address) || !Int32.TryParse(parts[1], NumberStyles.None, CultureInfo.InvariantCulture, out prefix)) Fail();
        if (address.AddressFamily != AddressFamily.InterNetwork && address.AddressFamily != AddressFamily.InterNetworkV6) Fail();
        var bytes = address.GetAddressBytes();
        if (prefix > bytes.Length * 8) Fail();
        for (int i = 0; i < bytes.Length; i++) {
            int remaining = prefix - i * 8;
            int mask = remaining >= 8 ? 0 : remaining <= 0 ? 255 : (1 << (8 - remaining)) - 1;
            if ((bytes[i] & mask) != 0) Fail();
        }
    }
    private static void ValidateIpv4(string text) {
        var parts = text.Split('.');
        if (parts.Length != 4) Fail();
        foreach (var part in parts) {
            int value;
            if (!Regex.IsMatch(part, @"\A(?:0|[1-9][0-9]{0,2})\z", RegexOptions.CultureInvariant) ||
                !Int32.TryParse(part, NumberStyles.None, CultureInfo.InvariantCulture, out value) || value > 255) Fail();
        }
    }

    // Parse a conservative, bounded RE2 subset without running a provider's
    // pattern in the backtracking .NET engine. Unsupported syntax fails closed.
    // Captures, noncapturing groups, i/m/s/U flags, classes and counted repeats
    // are accepted. Backreferences, lookarounds and named captures are excluded.
    private sealed class SafeRegexSyntax {
        private readonly string pattern;
        private int position;
        private int depth;
        public SafeRegexSyntax(string value) { pattern = value; }
        public void Validate() { Expression(false); if (position != pattern.Length) Fail(); }

        private int Expression(bool grouped) {
            int expansion = 0;
            while (position < pattern.Length && pattern[position] != ')') {
                if (pattern[position] == '|') { position++; continue; }
                int atomExpansion;
                bool repeatable = Atom(out atomExpansion);
                if (position < pattern.Length && IsQuantifier(pattern[position])) {
                    if (!repeatable) Fail();
                    bool empty;
                    int repeat = Quantifier(out empty);
                    // RE2 also bounds the product of nested counted repeats,
                    // e.g. (a{1000}){2} is invalid despite each count <= 1000.
                    if (empty) atomExpansion = 0;
                    else {
                        atomExpansion = Math.Max(1, atomExpansion);
                        if (atomExpansion > 1000 / repeat) Fail();
                        atomExpansion *= repeat;
                    }
                    if (position < pattern.Length && pattern[position] == '?') position++;
                    if (position < pattern.Length && IsQuantifier(pattern[position])) Fail();
                }
                expansion = Math.Max(expansion, atomExpansion);
            }
            if (grouped) {
                if (position >= pattern.Length || pattern[position] != ')') Fail();
                position++;
            }
            return expansion;
        }
        private bool Atom(out int expansion) {
            expansion = 1;
            char c = pattern[position++];
            if (c == '(') {
                if (++depth > 16) Fail();
                if (position < pattern.Length && pattern[position] == '?') {
                    position++;
                    if (position < pattern.Length && pattern[position] == ':') position++;
                    else {
                        bool flag = false, minus = false, afterMinus = false;
                        while (position < pattern.Length && "imsU-".IndexOf(pattern[position]) >= 0) {
                            if (pattern[position++] == '-') { if (minus) Fail(); minus = true; }
                            else { flag = true; if (minus) afterMinus = true; }
                        }
                        if (!flag || minus && !afterMinus || position >= pattern.Length) Fail();
                        if (pattern[position] == ')') { position++; depth--; expansion = 0; return false; }
                        if (pattern[position++] != ':') Fail();
                    }
                }
                expansion = Expression(true); depth--; return true;
            }
            if (c == '[') { CharacterClass(); return true; }
            if (c == '\\') {
                if (position >= pattern.Length) Fail();
                char kind = pattern[position];
                int ignored; Escape(false, out ignored); return "bBAz".IndexOf(kind) < 0;
            }
            if (c == '^' || c == '$') return false;
            if (c == '*' || c == '+' || c == '?' || c == '{' || c == '}' || c == ')') Fail();
            return true;
        }
        private void CharacterClass() {
            if (position < pattern.Length && pattern[position] == '^') position++;
            bool any = false;
            while (position < pattern.Length) {
                if (pattern[position] == ']' && any) { position++; return; }
                int start;
                bool scalar = ClassAtom(out start);
                any = true;
                if (position + 1 < pattern.Length && pattern[position] == '-' && pattern[position + 1] != ']') {
                    position++;
                    int end;
                    if (!scalar || !ClassAtom(out end) || start > end) Fail();
                }
            }
            Fail();
        }
        private bool ClassAtom(out int scalar) {
            if (position >= pattern.Length) Fail();
            char c = pattern[position++];
            if (c == '\\') return Escape(true, out scalar);
            if (c == '[' && position < pattern.Length && pattern[position] == ':') {
                position++;
                int start = position;
                if (position < pattern.Length && pattern[position] == '^') position++;
                while (position < pattern.Length && pattern[position] >= 'a' && pattern[position] <= 'z') position++;
                var name = pattern.Substring(start, position - start).TrimStart('^');
                if (Array.IndexOf(new[] { "alnum", "alpha", "ascii", "blank", "cntrl", "digit", "graph", "lower", "print", "punct", "space", "upper", "word", "xdigit" }, name) < 0 ||
                    position + 1 >= pattern.Length || pattern[position] != ':' || pattern[position + 1] != ']') Fail();
                position += 2; scalar = -1; return false;
            }
            scalar = c; return true;
        }
        private bool Escape(bool inClass, out int scalar) {
            if (position >= pattern.Length) Fail();
            char c = pattern[position++];
            scalar = c;
            if (c >= '0' && c <= '9') Fail();
            if (c == 'x') {
                int count = 2;
                bool braces = position < pattern.Length && pattern[position] == '{';
                if (braces) { position++; count = 0; }
                int value = 0, read = 0;
                while (position < pattern.Length && Uri.IsHexDigit(pattern[position]) && (braces || read < count)) {
                    char digit = pattern[position++];
                    value = value * 16 + (digit <= '9' ? digit - '0' : (Char.ToLowerInvariant(digit) - 'a' + 10));
                    if (++read > 6) Fail();
                }
                if (braces) { if (read < 1 || position >= pattern.Length || pattern[position++] != '}') Fail(); }
                else if (read != count) Fail();
                if (value > 0x10ffff || value >= 0xd800 && value <= 0xdfff) Fail();
                scalar = value; return true;
            }
            if ("dDsSwW".IndexOf(c) >= 0) { scalar = -1; return false; }
            if ("bBAz".IndexOf(c) >= 0) { if (inClass) Fail(); return false; }
            if ("afnrtv".IndexOf(c) >= 0) {
                scalar = c == 'a' ? 7 : c == 'f' ? 12 : c == 'n' ? 10 : c == 'r' ? 13 : c == 't' ? 9 : 11;
                return true;
            }
            if (c >= 32 && c <= 126 && !AlphaNumeric(c)) return true;
            // Unicode properties, quoting and engine-specific escapes are
            // deliberately not in this portable subset.
            Fail(); return false;
        }
        private static bool IsQuantifier(char c) { return c == '*' || c == '+' || c == '?' || c == '{'; }
        private int Quantifier(out bool empty) {
            empty = false;
            if (pattern[position++] != '{') return 1;
            int minimum = Count();
            int maximum = minimum;
            bool unbounded = false;
            if (position < pattern.Length && pattern[position] == ',') {
                position++;
                unbounded = position < pattern.Length && pattern[position] == '}';
                maximum = unbounded ? 1000 : Count();
            }
            if (position >= pattern.Length || pattern[position++] != '}' || minimum > maximum) Fail();
            // {0} prunes its child, whereas {0,} still retains any counted
            // repeats inside it when RE2 validates an enclosing repetition.
            empty = !unbounded && maximum == 0;
            return Math.Max(1, unbounded ? minimum : maximum);
        }
        private int Count() {
            int count = 0, start = position;
            while (position < pattern.Length && pattern[position] >= '0' && pattern[position] <= '9') {
                count = count * 10 + pattern[position++] - '0';
                if (count > 1000 || position - start > 4) Fail();
            }
            if (position == start || position - start > 1 && pattern[start] == '0') Fail();
            return count;
        }
    }

    private static void Fail() { throw new InvalidOperationException("startFailed"); }
}
