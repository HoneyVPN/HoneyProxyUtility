using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;
using Microsoft.Win32;

public static class HoneyServiceTests {
    [DllImport("kernel32.dll", EntryPoint = "CreateFileW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle OpenDirectory(string path, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
    [DllImport("user32.dll")] private static extern IntPtr GetShellWindow();
    [StructLayout(LayoutKind.Sequential)] private struct AccessRequest { internal uint DesiredAccess; internal IntPtr PrincipalSelfSid; internal IntPtr ObjectTypeList; internal uint ObjectTypeListLength; internal IntPtr OptionalArguments; }
    [StructLayout(LayoutKind.Sequential)] private struct AccessReply { internal uint ResultListLength; internal IntPtr GrantedAccessMask; internal IntPtr SaclEvaluationResults; internal IntPtr Error; }
    [DllImport("authz.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)] private static extern bool AuthzInitializeResourceManager(uint flags, IntPtr access, IntPtr groups, IntPtr freeGroups, string name, out IntPtr manager);
    [DllImport("authz.dll", SetLastError = true)] private static extern bool AuthzInitializeContextFromSid(uint flags, byte[] sid, IntPtr manager, IntPtr expiration, long identifier, IntPtr groups, out IntPtr context);
    [DllImport("authz.dll", SetLastError = true)] private static extern bool AuthzAccessCheck(uint flags, IntPtr context, ref AccessRequest request, IntPtr audit, byte[] descriptor, IntPtr optional, uint count, ref AccessReply reply, IntPtr cached);
    [DllImport("authz.dll")] private static extern bool AuthzFreeContext(IntPtr context);
    [DllImport("authz.dll")] private static extern bool AuthzFreeResourceManager(IntPtr manager);
    private static int passed;
    private const string Install = @"C:\Program Files\HoneyProxyUtility";
    private const string SessionRoot = @"C:\ProgramData\HoneyVPN\WindowsTunnel\aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    private const string Nonce = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    private static readonly string BaseConfiguration = @"{
      ""log"":{""level"":""warn""},
      ""dns"":{""servers"":[{""tag"":""remote"",""type"":""https"",""server"":""1.1.1.1"",""path"":""/dns-query"",""domain_resolver"":{""server"":""local"",""strategy"":""prefer_ipv4""},""detour"":""proxy""},{""tag"":""local"",""type"":""local"",""detour"":""direct""}],""rules"":[],""final"":""remote"",""strategy"":""prefer_ipv4""},
      ""experimental"":{""clash_api"":{""external_controller"":""127.0.0.1:9090""},""cache_file"":{""enabled"":true,""path"":""untrusted-client-cache.db""}},
      ""inbounds"":[{""type"":""tun"",""tag"":""tun-in"",""address"":[""198.18.0.1/16"",""fdfe:dcba:9876::1/126""],""auto_route"":true,""strict_route"":false,""stack"":""mixed""}],
      ""outbounds"":[{""type"":""vless"",""tag"":""proxy"",""server"":""node.example.test"",""server_port"":443,""uuid"":""a3482e88-686a-4a58-8126-99c9df64b7bf"",""tls"":{""enabled"":true,""server_name"":""cover.example.test""}},{""type"":""direct"",""tag"":""direct""}],
      ""route"":{""rules"":[{""action"":""sniff""},{""protocol"":""dns"",""action"":""hijack-dns""},{""ip_is_private"":true,""outbound"":""direct""}],""rule_set"":[{""type"":""local"",""tag"":""ru"",""format"":""binary"",""path"":""C:\\Windows\\System32\\secret""}],""final"":""proxy"",""default_domain_resolver"":{""server"":""local"",""strategy"":""prefer_ipv4""},""auto_detect_interface"":true}
    }";

    public static int Main(string[] args) {
        try {
            if (Environment.OSVersion.Platform == PlatformID.Win32NT && args.Length == 1 && args[0] == "--desktop-restore-failure") {
                DesktopUserIdentity.TestRestoreFailure = true;
                DesktopUserIdentity.TestDebugScope(delegate { });
                return 99; // Restoration failure must terminate this owned child.
            }
            TestConfigurationBoundary();
            TestBootProof();
            if (args.Length != 0) TestGeneratedConfigurations(args[0]);
            TestFrameDeadline();
            if (Environment.OSVersion.Platform == PlatformID.Win32NT) TestWindowsKernelBoundaries();
            else Console.WriteLine("SKIP Windows kernel/ACL/named-pipe fixtures: compiler/config checks only on this platform");
            Console.WriteLine("PASS " + passed + " service boundary cases"); return 0;
        } catch (Exception failure) { Console.Error.WriteLine("FAIL " + failure.GetType().Name + ": " + failure.Message); return 1; }
    }
    private static Dictionary<string, object> Fresh() { return SafeTunConfiguration.Map(SafeTunConfiguration.Serializer().DeserializeObject(BaseConfiguration)); }
    private static Dictionary<string, object> Map(object value) { return SafeTunConfiguration.Map(value); }
    private static Dictionary<string, object> Proxy(Dictionary<string, object> cfg) { return Map(((object[])cfg["outbounds"])[0]); }
    private static Dictionary<string, object> RemoteDns(Dictionary<string, object> cfg) { return Map(((object[])Map(cfg["dns"])["servers"])[0]); }
    private static void Check(bool value, string label) { if (!value) throw new Exception(label); passed++; }
    private static void Reject(Action action, string label) {
        try { action(); } catch (InvalidOperationException) { passed++; return; } catch (ArgumentException) { passed++; return; }
        throw new Exception(label);
    }
    private static Dictionary<string, object> Prepare(Dictionary<string, object> cfg) { return SafeTunConfiguration.Prepare(cfg, Install, SessionRoot, Nonce); }
    private static void TestConfigurationBoundary() {
        var cfg = Prepare(Fresh());
        var experimental = Map(cfg["experimental"]);
        Check((string)Map(experimental["clash_api"])["secret"] == Nonce, "Service must choose controller secret");
        Check((string)Map(experimental["cache_file"])["path"] == Path.Combine(SessionRoot, "cache.db"), "Caller cannot choose SYSTEM cache path");
        var rules = Map(((object[])Map(cfg["route"])["rule_set"])[0]);
        Check((string)rules["path"] == Path.Combine(Install, "data", "flutter_assets", "assets", "geo", "ru.srs"), "Caller cannot choose SYSTEM rule-set path");
        Check(!rules.ContainsKey("url"), "Runtime must not download privileged rule sets");
        foreach (var field in new[] { "certificate_path", "key_path", "certificate_key_path", "ech", "session_ticket_key_path" }) {
            var bad = Fresh(); Map(Proxy(bad)["tls"])[field] = @"C:\Windows\System32\config\SAM";
            Reject(delegate { Prepare(bad); }, "Reject TLS filesystem option " + field);
        }
        foreach (var field in new[] { "providers", "services", "ntp", "certificate", "controller", "process", "exec", "__type" }) {
            var bad = Fresh(); bad[field] = @"C:\Windows\System32\cmd.exe";
            Reject(delegate { Prepare(bad); }, "Reject extra privileged component " + field);
        }
        var log = Fresh(); Map(log["log"])["output"] = @"C:\Windows\System32\injected.dll";
        Reject(delegate { Prepare(log); }, "Reject privileged log output");
        var external = Fresh(); Map(Map(external["experimental"])["clash_api"])["external_ui"] = @"C:\Windows\System32";
        Reject(delegate { Prepare(external); }, "Reject external UI file server");
        var listen = Fresh(); Map(Map(listen["experimental"])["clash_api"])["external_controller"] = "0.0.0.0:9090";
        Reject(delegate { Prepare(listen); }, "Reject exposed privileged controller");
        var plugin = Fresh(); Proxy(plugin)["plugin"] = @"C:\Users\Public\plugin.exe";
        Reject(delegate { Prepare(plugin); }, "Reject plugin process execution");
        var extraRule = Fresh(); Map(((object[])Map(extraRule["route"])["rule_set"])[0])["tag"] = "system-secret";
        Reject(delegate { Prepare(extraRule); }, "Reject unrecognized file-backed rule set");
        var remoteFile = Fresh(); RemoteDns(remoteFile)["server"] = "file:///C:/Windows/System32/config/SAM";
        Reject(delegate { Prepare(remoteFile); }, "Reject file scheme DNS");
        var socket = Fresh(); Map(((object[])socket["inbounds"])[0])["type"] = "http";
        Reject(delegate { Prepare(socket); }, "Service never accepts a proxy/listening inbound");
        foreach (var addresses in new[] {
            new object[] { "198.18.0.1/16" },
            new object[] { "198.18.0.1/16", "::/0" },
            new object[] { "198.18.0.1/16", "fdfe:dcba:9876::1/64" },
            new object[] { "fdfe:dcba:9876::1/126", "198.18.0.1/16" },
            new object[] { "198.18.0.1/16", "fdfe:dcba:9876::1/126", "10.0.0.1/8" }
        }) {
            var bad = Fresh(); Map(((object[])bad["inbounds"])[0])["address"] = addresses;
            Reject(delegate { Prepare(bad); }, "Service only accepts the exact dual-stack TUN address pair");
        }
        var longHost = Fresh(); Proxy(longHost)["server"] = new String('a', 257);
        Reject(delegate { Prepare(longHost); }, "Bounded network strings");
        var malformed = Fresh(); Proxy(malformed)["server_port"] = -1;
        Reject(delegate { Prepare(malformed); }, "Bounded network ports");
        var typeTrick = Fresh(); Map(Proxy(typeTrick)["tls"])["__type"] = "System.Diagnostics.Process";
        Reject(delegate { Prepare(typeTrick); }, "Reject serializer type metadata at nested levels");
        var deep = "0"; for (int i = 0; i < 20; i++) deep = "{\"nested\":" + deep + "}";
        var excessiveDepth = deep;
        Reject(delegate { SafeTunConfiguration.Serializer().DeserializeObject(excessiveDepth); }, "Bound JSON recursion");
        TestTypedDnsBoundary();
        TestWireGuardReservedBoundary();
    }
    private static void TestTypedDnsBoundary() {
        foreach (var kind in new[] { "https", "tls" }) {
            foreach (var host in new[] { "dns.example.test", "8.8.8.8", "2001:db8::53" }) {
                foreach (var port in new[] { 443, 853, 8443, 8853, 65535 }) {
                    var good = Fresh(); var remote = RemoteDns(good);
                    remote["type"] = kind; remote["server"] = host; remote["server_port"] = port;
                    if (kind == "tls") remote.Remove("path"); else remote["path"] = "/custom%2Fdns";
                    Prepare(good); passed++;
                }
            }
        }
        foreach (var strategy in new[] { "ipv4_only", "ipv6_only", "prefer_ipv4" }) {
            var good = Fresh(); Map(good["dns"])["strategy"] = strategy;
            Map(RemoteDns(good)["domain_resolver"])["strategy"] = strategy;
            Map(Map(good["route"])["default_domain_resolver"])["strategy"] = strategy;
            Prepare(good); passed++;
        }
        foreach (var port in new object[] { 0, -1, 65536, 1.5m, "443" }) {
            var bad = Fresh(); RemoteDns(bad)["server_port"] = port;
            Reject(delegate { Prepare(bad); }, "DNS port is a bounded integer");
        }
        foreach (var host in new[] { "", "file:///secret", "https://dns.example.test", "user@dns.example.test", "dns.example.test:443", "dns.example.test\\secret", "bad host", "bad\thost" }) {
            var bad = Fresh(); RemoteDns(bad)["server"] = host;
            Reject(delegate { Prepare(bad); }, "Reject a non-host DNS server");
        }
        foreach (var path in new[] { "", "relative", "/dns?token=x", "/dns#token", "/dns\\secret", "/dns\tsecret", "/dns%wrong", "/dns%2" }) {
            var bad = Fresh(); RemoteDns(bad)["path"] = path;
            Reject(delegate { Prepare(bad); }, "Reject malformed or non-path HTTPS DNS");
        }
        foreach (var field in new[] { "address", "address_resolver", "tls", "headers", "http_client", "certificate_path", "key_path", "__type" }) {
            var bad = Fresh(); RemoteDns(bad)[field] = @"C:\Windows\System32\config\SAM";
            Reject(delegate { Prepare(bad); }, "Reject legacy or privileged DNS field " + field);
        }
        var tlsPath = Fresh(); RemoteDns(tlsPath)["type"] = "tls";
        Reject(delegate { Prepare(tlsPath); }, "TLS DNS cannot carry a path");
        var wrongType = Fresh(); RemoteDns(wrongType)["type"] = "udp";
        Reject(delegate { Prepare(wrongType); }, "Client cannot substitute an unapproved DNS transport");
        var wrongDetour = Fresh(); RemoteDns(wrongDetour)["detour"] = "direct";
        Reject(delegate { Prepare(wrongDetour); }, "Remote DNS stays within the selected proxy");
        var legacyRule = Fresh(); Map(legacyRule["dns"])["rules"] = new object[] { new Dictionary<string, object> { { "outbound", "any" }, { "server", "local" } } };
        Reject(delegate { Prepare(legacyRule); }, "No legacy outbound DNS rules");
        var localInjection = Fresh(); Map(((object[])Map(localInjection["dns"])["servers"])[1])["domain_resolver"] = "remote";
        Reject(delegate { Prepare(localInjection); }, "Local DNS cannot resolve recursively through the proxy");
        foreach (var field in new[] { "server", "strategy", "certificate_path", "__type" }) {
            var bad = Fresh(); Map(RemoteDns(bad)["domain_resolver"])[field] = "untrusted";
            Reject(delegate { Prepare(bad); }, "DNS bootstrap resolver shape remains exact");
            var routeBad = Fresh(); Map(Map(routeBad["route"])["default_domain_resolver"])[field] = "untrusted";
            Reject(delegate { Prepare(routeBad); }, "Route bootstrap resolver shape remains exact");
        }
        var missing = Fresh(); Map(missing["route"]).Remove("default_domain_resolver");
        Reject(delegate { Prepare(missing); }, "Route bootstrap resolver is mandatory");
    }

    private static void TestWireGuardReservedBoundary() {
        var endpointJson = "{\"type\":\"wireguard\",\"tag\":\"proxy\",\"system\":false,\"domain_resolver\":{\"server\":\"local\",\"strategy\":\"prefer_ipv4\"},\"address\":[\"10.20.0.2/32\"],\"private_key\":\"synthetic-private-key\",\"listen_port\":0,\"mtu\":1420,\"peers\":[{\"address\":\"peer.example.test\",\"port\":51820,\"public_key\":\"synthetic-public-key\",\"allowed_ips\":[\"0.0.0.0/0\",\"::/0\"]}]}";
        foreach (var awg in new[] { false, true }) {
            var good = Fresh(); var endpoint = Map(SafeTunConfiguration.Serializer().DeserializeObject(endpointJson));
            if (awg) endpoint["amnezia"] = new Dictionary<string, object> { { "jc", 4 }, { "jmin", 40 }, { "jmax", 70 }, { "h1", 1 }, { "h2", 2 }, { "h3", 3 }, { "h4", 4 } };
            good["outbounds"] = new object[] { new Dictionary<string, object> { { "type", "direct" }, { "tag", "direct" } } };
            good["endpoints"] = new object[] { endpoint }; Prepare(good); passed++;
            var peer = Map(((object[])endpoint["peers"])[0]);
            foreach (var reserved in new object[] { new object[] { 0, 0, 0 }, new object[] { 7, 8, 9 }, new object[] { 0, 0 }, new object[] {}, "reserved" }) {
                peer["reserved"] = reserved;
                Reject(delegate { Prepare(good); }, "Removed Reserved is rejected at the privileged boundary");
                peer.Remove("reserved");
            }
            endpoint["domain_resolver"] = "local";
            Reject(delegate { Prepare(good); }, "Endpoint resolver cannot bypass the explicit IP strategy");
        }
    }

    private static void TestGeneratedConfigurations(string directory) {
        int checkedCount = 0;
        foreach (var file in Directory.GetFiles(directory, "windowsTunnel-*.json")) {
            var cfg = Map(SafeTunConfiguration.Serializer().DeserializeObject(File.ReadAllText(file)));
            // Settings must survive the privileged serialization boundary.
            // The only rebuilt fields are controller/cache and rule-set paths.
            var preserved = new Dictionary<string, string>();
            foreach (var field in new[] { "log", "dns", "inbounds", "outbounds", "endpoints" }) {
                if (cfg.ContainsKey(field)) preserved[field] = SafeTunConfiguration.Serializer().Serialize(cfg[field]);
            }
            var route = Map(cfg["route"]);
            foreach (var field in new[] { "rules", "final", "default_domain_resolver", "auto_detect_interface" }) {
                preserved["route." + field] = SafeTunConfiguration.Serializer().Serialize(route[field]);
            }
            Prepare(cfg);
            foreach (var item in preserved) {
                var value = item.Key.StartsWith("route.", StringComparison.Ordinal)
                    ? Map(cfg["route"])[item.Key.Substring(6)] : cfg[item.Key];
                if (SafeTunConfiguration.Serializer().Serialize(value) != item.Value)
                    throw new Exception("Generated settings changed across service boundary: " + item.Key);
            }
            checkedCount++;
        }
        Check(checkedCount >= 54, "Expected every generated Windows TUN protocol fixture");
        Console.WriteLine("PASS " + checkedCount + " generated Windows TUN configuration allowlists");
    }

    private sealed class SlowStream : Stream {
        public bool WasDisposed;
        public override bool CanRead { get { return true; } } public override bool CanSeek { get { return false; } } public override bool CanWrite { get { return false; } }
        public override long Length { get { throw new NotSupportedException(); } } public override long Position { get { return 0; } set { throw new NotSupportedException(); } }
        public override void Flush() { } public override int Read(byte[] bytes, int offset, int count) { throw new NotSupportedException(); }
        public override Task<int> ReadAsync(byte[] bytes, int offset, int count, CancellationToken token) {
            return Task.Run(delegate { Thread.Sleep(100); bytes[offset] = 1; return 1; });
        }
        public override long Seek(long value, SeekOrigin origin) { throw new NotSupportedException(); } public override void SetLength(long value) { throw new NotSupportedException(); }
        public override void Write(byte[] bytes, int offset, int count) { throw new NotSupportedException(); }
        protected override void Dispose(bool disposing) { WasDisposed = true; base.Dispose(disposing); }
    }
    private static void TestFrameDeadline() {
        var method = typeof(HoneyVpnService).GetMethod("ReadExact", BindingFlags.NonPublic | BindingFlags.Static);
        var stream = new SlowStream(); var clock = Stopwatch.StartNew(); bool bounded = false;
        try { method.Invoke(null, new object[] { stream, 1000, clock }); }
        catch (TargetInvocationException failure) { bounded = failure.InnerException is RpcFailure; }
        Check(bounded && stream.WasDisposed && clock.ElapsedMilliseconds < 6500, "Frame has one total deadline despite trickled chunks");
    }

    private static void TestWindowsKernelBoundaries() {
        var owner = WindowsIdentity.GetCurrent().User.Value;
        TestProcessObservationPolicy();
        TestDesktopPrivilegeScope();
        TestEarlyPipeDisconnect(owner);
        TestBrokerClosedBoundary(owner);
        TestProtectedAncestry();
        TestVolatileRegistryEpoch(owner);
        var name = "honey-service-fixture-" + Guid.NewGuid().ToString("N");
        using (var server = Native.TestServerPipe(owner, true, name)) {
            var pending = Task.Run(delegate {
                server.WaitForConnection(); server.ReadByte();
                using (var caller = Native.Authenticate(server, owner)) {
                    Check(caller.Pid == Process.GetCurrentProcess().Id, "Kernel pipe PID must identify the actual client");
                    Check(caller.Sid == owner && caller.Birth == Process.GetCurrentProcess().StartTime.ToUniversalTime().Ticks.ToString(), "Kernel SID and original process birth are bound");
                }
            });
            using (var client = new NamedPipeClientStream(".", name, (PipeAccessRights)0x12019b, PipeOptions.Asynchronous,
                TokenImpersonationLevel.Identification, HandleInheritability.None)) {
                client.Connect(3000); client.WriteByte(1); Check(pending.Wait(3000), "Kernel identity fixture must finish");
            }
            foreach (PipeAccessRule rule in server.GetAccessControl().GetAccessRules(true, false, typeof(SecurityIdentifier))) {
                if (rule.IdentityReference.Value == owner) Check(((int)rule.PipeAccessRights & 4) == 0, "Owner's client ACE cannot create another server instance");
            }
        }
        name += "-deny";
        using (var server = Native.TestServerPipe(owner, true, name)) {
            var pending = Task.Run(delegate {
                server.WaitForConnection(); server.ReadByte();
                try { using (var caller = Native.Authenticate(server, "S-1-5-19")) { } return false; }
                catch (RpcFailure failure) { return failure.Code == "serviceAccessDenied"; }
            });
            using (var client = new NamedPipeClientStream(".", name, (PipeAccessRights)0x12019b, PipeOptions.Asynchronous,
                TokenImpersonationLevel.Identification, HandleInheritability.None)) {
                client.Connect(3000); client.WriteByte(1); Check(pending.Wait(3000) && pending.Result, "Actual kernel identity cannot satisfy a different SID policy");
            }
        }
        var instances = new List<NamedPipeServerStream>();
        try { for (int i = 0; i < 10; i++) instances.Add(Native.TestServerPipe(owner, i == 0, name + "-slots"));
            Check(instances.Count == 10, "An eighth stalled client must not exhaust the native pipe instance cap");
        } finally { foreach (var pipe in instances) pipe.Dispose(); }
        bool rejected = false; try { ProtectedPaths.ValidateInstallation(); } catch (RpcFailure) { rejected = true; }
        Check(rejected, "A helper outside canonical protected Program Files cannot install a SYSTEM service");
        var temporary = Path.Combine(Path.GetTempPath(), "honey-service-acl-" + Guid.NewGuid().ToString("N"));
        var parent = Path.Combine(temporary, "HoneyVPN"); Directory.CreateDirectory(parent);
        try {
            var acl = new DirectorySecurity(); acl.SetOwner(new SecurityIdentifier(owner)); acl.SetAccessRuleProtection(true, false);
            acl.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(owner), FileSystemRights.FullControl,
                InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
            acl.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(WellKnownSidType.WorldSid, null), FileSystemRights.WriteData,
                InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
            Directory.SetAccessControl(parent, acl);
            ProtectedPaths.TestDataRoot = Path.Combine(parent, "WindowsTunnel");
            using (var held = OpenDirectory(parent, 2, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero)) {
                Check(!held.IsInvalid, "Fixture must retain a pre-existing writable directory handle");
                rejected = false; try { ProtectedPaths.Configure(owner, Install); } catch (RpcFailure) { rejected = true; }
            }
            Check(rejected && !Directory.Exists(ProtectedPaths.TestDataRoot), "Even an empty user-owned namespace cannot be adopted by SYSTEM");
            Check(Directory.GetAccessControl(parent).GetOwner(typeof(SecurityIdentifier)).Value == owner, "Rejecting a planted directory must not change its owner");
        } finally { ProtectedPaths.TestDataRoot = null; Directory.Delete(temporary, true); }
        Console.WriteLine("PASS read-only kernel pipe/identity, private temporary ACL and fixed installation boundary");
    }

    private static void TestEarlyPipeDisconnect(string owner) {
        Check(Native.TestIsEarlyClientDisconnect(new IOException("synthetic", unchecked((int)0x800700e8))),
            "Only documented Win32 ERROR_NO_DATA is recoverable before accept");
        foreach (var error in new[] { 0x80070005u, 0x8007006du, 0x800700e9u, 0x80070057u })
            Check(!Native.TestIsEarlyClientDisconnect(new IOException("synthetic", unchecked((int)error))),
                "Access denied, broken pipe, not connected and unexpected errors remain fatal");
        var name = "honey-early-client-" + Guid.NewGuid().ToString("N");
        var root = Path.Combine(Path.GetTempPath(), "honey-early-client-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        NamedPipeServerStream pending = Native.TestServerPipe(owner, true, name);
        var original = pending;
        using (var ready = new ManualResetEventSlim()) {
            bool stopping = false; int closedClients = 1; int heldNameChecks = 0;
            Native.TestCloseBeforeAccept(name); // Close before ANY server Wait.
            var broker = new Broker(new ProtectedPaths { Install = Install, Root = root, OwnerSid = owner });
            var worker = Task.Run(delegate {
                if (!Native.TestWaitForConnection(ref pending, owner, name,
                    delegate { return stopping; }, delegate(NamedPipeServerStream replacement) {
                        if (!Object.ReferenceEquals(replacement, original)) {
                            if (heldNameChecks == 0) {
                                if (original.SafePipeHandle.IsClosed) throw new Exception("Failed instance closed before replacement publication");
                                bool denied = false;
                                try { using (var impostor = Native.TestServerPipe(owner, true, name)) { } }
                                catch (RpcFailure failure) { denied = failure.Code == "serviceUnavailable"; }
                                if (!denied) throw new Exception("Replacement released the authenticated pipe name");
                                heldNameChecks++;
                            }
                            if (closedClients < 12) { Native.TestCloseBeforeAccept(name); closedClients++; }
                            else ready.Set();
                        }
                        return !stopping;
                    })) return false;
                if (pending.ReadByte() != 1) return false;
                using (var caller = Native.Authenticate(pending, owner)) {
                    if (broker.Dispatch(caller, new Dictionary<string, object> {
                        { "version", 1 }, { "operation", "readActive" }
                    }) != null) return false;
                }
                pending.WriteByte(1); return true;
            });
            try {
                Check(ready.Wait(5000), "A burst of twelve real pre-accept client exits preserves listener availability");
                using (var client = new NamedPipeClientStream(".", name, (PipeAccessRights)0x12019b, PipeOptions.Asynchronous,
                    TokenImpersonationLevel.Identification, HandleInheritability.None)) {
                    client.Connect(3000); client.WriteByte(1);
                    var reply = new byte[1]; var read = client.ReadAsync(reply, 0, 1);
                    Check(read.Wait(3000) && read.Result == 1 && reply[0] == 1,
                        "A subsequent valid kernel-authenticated readActive request succeeds");
                }
                Check(worker.Wait(3000) && worker.Result && heldNameChecks == 1 && closedClients == 12,
                    "Production accept recovery retains ownership and completes the authenticated request");
            } finally {
                stopping = true; pending.Dispose();
                try { worker.Wait(3000); } catch (AggregateException) { }
                broker.StopForServiceShutdown();
                Directory.Delete(root, true);
            }
        }
        name += "-stop"; pending = Native.TestServerPipe(owner, true, name); original = pending;
        Native.TestCloseBeforeAccept(name);
        bool stopped = false;
        var originalHandle = original.SafePipeHandle;
        Microsoft.Win32.SafeHandles.SafePipeHandle replacementHandle = null;
        var clock = Stopwatch.StartNew();
        try {
            Check(!Native.TestWaitForConnection(ref pending, owner, name,
                delegate { return stopped; }, delegate(NamedPipeServerStream replacement) {
                    if (!Object.ReferenceEquals(replacement, original)) stopped = true;
                    return !stopped;
                }), "Stopping during replacement publication cannot begin another accept");
            replacementHandle = pending.SafePipeHandle;
            Check(originalHandle.IsClosed && clock.ElapsedMilliseconds < 2000,
                "Rejected replacement publication retires the old instance promptly");
        } finally { pending.Dispose(); }
        Check(replacementHandle != null && replacementHandle.IsClosed, "Stop retires both owned old and replacement handles");
        Console.WriteLine("PASS actual pre-accept client exit recovery, bounded handles, authenticated readActive and stop publication");
    }

    private static void TestDesktopPrivilegeScope() {
        var processBefore = DesktopUserIdentity.TestTokenSnapshot(false);
        var threadBefore = DesktopUserIdentity.TestTokenSnapshot(true);
        DesktopUserIdentity.TestNotAssigned = true;
        try { Reject(delegate { DesktopUserIdentity.TestDebugScope(delegate { }); }, "BOOL success with NOT_ALL_ASSIGNED must fail closed"); }
        finally { DesktopUserIdentity.TestNotAssigned = false; }
        Check(DesktopUserIdentity.TestTokenSnapshot(false) == processBefore &&
            DesktopUserIdentity.TestTokenSnapshot(true) == threadBefore, "Failed privilege acquisition preserves exact process and thread tokens");
        bool available = false;
        try {
            DesktopUserIdentity.TestDebugScope(delegate {
                available = true;
                var outer = DesktopUserIdentity.TestTokenSnapshot(true);
                Check(outer != threadBefore, "Scoped debug uses a private thread token");
                Check(DesktopUserIdentity.TestTokenSnapshot(false) == processBefore, "Scoped debug never adjusts the process token");
                try { DesktopUserIdentity.TestDebugScope(delegate { throw new IOException("synthetic-read-failure"); }); }
                catch (IOException) { }
                Check(DesktopUserIdentity.TestTokenSnapshot(true) == outer, "Nested read failure restores the exact previous impersonation token");
            });
        } catch (InvalidOperationException) {
            if (available) throw;
            Console.WriteLine("SKIP actual debug-enable success: this fixture token has no assigned debug privilege");
        }
        Check(DesktopUserIdentity.TestTokenSnapshot(false) == processBefore &&
            DesktopUserIdentity.TestTokenSnapshot(true) == threadBefore, "Success or unavailable privilege restores the exact original security context");
        if (available) {
            try { DesktopUserIdentity.TestDebugScope(delegate { throw new IOException("synthetic-read-failure"); }); }
            catch (IOException) { }
            Check(DesktopUserIdentity.TestTokenSnapshot(false) == processBefore &&
                DesktopUserIdentity.TestTokenSnapshot(true) == threadBefore, "Read exceptions cannot leave enabled privileges or impersonation behind");
            var start = new ProcessStartInfo(Process.GetCurrentProcess().MainModule.FileName, "--desktop-restore-failure") {
                UseShellExecute = false, CreateNoWindow = true
            };
            using (var child = Process.Start(start)) {
                if (!child.WaitForExit(8000)) {
                    child.Kill(); child.WaitForExit();
                    throw new Exception("Owned restoration-failure child exceeded its deadline");
                }
                Check(child.ExitCode == 23, "A restoration failure terminates only the owned helper child with safe exit 23");
            }
        }
        Check(!String.IsNullOrWhiteSpace(DesktopUserIdentity.ReadProcessImage((uint)Process.GetCurrentProcess().Id)),
            "Unprivileged query-only image resolver reads a retained live process");
        Reject(delegate { DesktopUserIdentity.ReadProcessImage(0); }, "Image resolver never accepts unknown PID");
        if (GetShellWindow() != IntPtr.Zero) {
            Check(!String.IsNullOrWhiteSpace(DesktopUserIdentity.ReadOwnerSid()), "Actual desktop owner SID must be readable");
            Check(Path.IsPathRooted(DesktopUserIdentity.ReadRoamingPath()), "Actual desktop roaming folder must be absolute");
            Check(DesktopUserIdentity.TestTokenSnapshot(false) == processBefore &&
                DesktopUserIdentity.TestTokenSnapshot(true) == threadBefore, "Desktop getters leave original security context unchanged");
        } else Console.WriteLine("SKIP actual desktop SID/folder: no interactive shell in this Windows fixture; installer smoke is still required");
        Console.WriteLine("PASS scoped desktop identity privilege boundaries (no process-wide privilege change)");
    }
    private static void TestBrokerClosedBoundary(string owner) {
        var directory = Path.Combine(Path.GetTempPath(), "honey-service-close-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try {
            var broker = new Broker(new ProtectedPaths { Install = Install, Root = directory, OwnerSid = owner });
            using (var caller = new Caller(owner, Process.GetCurrentProcess())) {
                bool rejected = false;
                try { broker.Dispatch(caller, new Dictionary<string, object> { { "version", 1 }, { "operation", "launch" }, { "nonce", Nonce } }); }
                catch (RpcFailure failure) { rejected = failure.Code == "serviceAccessDenied"; }
                Check(rejected, "Unknown nonce cannot launch a supervisor");
                var forged = new Dictionary<string, object> { { "version", 1 }, { "operation", "reserve" }, { "parentPid", 4 }, { "config", Fresh() }, { "httpPort", 2081 } };
                Reject(delegate { broker.Dispatch(caller, forged); }, "Caller cannot supply kernel parent identity");
                broker.StopForServiceShutdown();
                rejected = false;
                try { broker.Dispatch(caller, new Dictionary<string, object> { { "version", 1 }, { "operation", "reserve" }, { "config", Fresh() }, { "httpPort", 2081 } }); }
                catch (RpcFailure failure) { rejected = failure.Code == "serviceUnavailable"; }
                Check(rejected && !File.Exists(Path.Combine(directory, "active.json")), "Pending reserve after shutdown cannot publish a lease or child");
            }
            using (var service = new HoneyVpnService()) {
                typeof(HoneyVpnService).GetMethod("OnShutdown", BindingFlags.NonPublic | BindingFlags.Instance).Invoke(service, new object[0]);
                Check(true, "Shutdown outside SCM StopPending does not call RequestAdditionalTime");
            }
        } finally { Directory.Delete(directory, true); }
    }
    private static void TestProtectedAncestry() {
        var admin = new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null);
        var users = new SecurityIdentifier(WellKnownSidType.BuiltinUsersSid, null);
        var acl = new DirectorySecurity(); acl.SetOwner(admin); acl.SetAccessRuleProtection(true, false);
        acl.AddAccessRule(new FileSystemAccessRule(admin, FileSystemRights.FullControl, AccessControlType.Allow));
        acl.AddAccessRule(new FileSystemAccessRule(users, FileSystemRights.AppendData, AccessControlType.Allow));
        ProtectedPaths.AssertAncestorAcl(acl); passed++;
        foreach (var right in new[] { FileSystemRights.Delete, FileSystemRights.DeleteSubdirectoriesAndFiles, FileSystemRights.ChangePermissions, FileSystemRights.TakeOwnership }) {
            var unsafeAcl = new DirectorySecurity(); unsafeAcl.SetOwner(admin); unsafeAcl.SetAccessRuleProtection(true, false);
            unsafeAcl.AddAccessRule(new FileSystemAccessRule(users, right, AccessControlType.Allow));
            bool rejected = false; try { ProtectedPaths.AssertAncestorAcl(unsafeAcl); } catch (RpcFailure) { rejected = true; }
            Check(rejected, "Unprivileged ancestor replacement right must be rejected: " + right);
        }
    }
    private static bool ProcessPolicyAllows(RawSecurityDescriptor descriptor, string caller, uint desired) {
        // SYSTEM owns the modeled process. A same-user elevated child would
        // confer implicit owner WRITE_DAC and cannot prove this boundary.
        descriptor.Owner = new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null);
        descriptor.Group = descriptor.Owner;
        var sd = new byte[descriptor.BinaryLength]; descriptor.GetBinaryForm(sd, 0);
        var sid = new SecurityIdentifier(caller); var sidBytes = new byte[sid.BinaryLength]; sid.GetBinaryForm(sidBytes, 0);
        IntPtr manager = IntPtr.Zero, context = IntPtr.Zero, results = IntPtr.Zero;
        try {
            Check(AuthzInitializeResourceManager(1, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, "HoneyVPN process policy fixture", out manager), "Native policy manager without auditing");
            // Skip account/group resolution: this context is exactly the one
            // arbitrary SID under test, without admin groups or privileges.
            Check(AuthzInitializeContextFromSid(2, sidBytes, manager, IntPtr.Zero, 0, IntPtr.Zero, out context), "Native SID-only policy context");
            results = Marshal.AllocHGlobal(12); for (int i = 0; i < 12; i += 4) Marshal.WriteInt32(results, i, 0);
            var request = new AccessRequest { DesiredAccess = desired };
            var reply = new AccessReply { ResultListLength = 1, GrantedAccessMask = results, SaclEvaluationResults = IntPtr.Add(results, 4), Error = IntPtr.Add(results, 8) };
            Check(AuthzAccessCheck(0, context, ref request, IntPtr.Zero, sd, IntPtr.Zero, 0, ref reply, IntPtr.Zero), "Native descriptor access check");
            int error = Marshal.ReadInt32(reply.Error);
            Check(error == 0 || error == 5, "Native access result is grant or access denied");
            return error == 0 && ((uint)Marshal.ReadInt32(reply.GrantedAccessMask) & desired) == desired;
        } finally {
            if (results != IntPtr.Zero) Marshal.FreeHGlobal(results);
            if (context != IntPtr.Zero) AuthzFreeContext(context);
            if (manager != IntPtr.Zero) AuthzFreeResourceManager(manager);
        }
    }
    private static void RejectProcessObservation(Action action, string code, string label) {
        try { action(); }
        catch (RpcFailure failure) { Check(failure.Code == code, label + " returns expected safe code"); return; }
        throw new Exception(label);
    }
    private static void TestProcessObservationPolicy() {
        const string owner = "S-1-5-21-101-202-303-1001", foreign = "S-1-5-21-101-202-303-1002";
        Check(Native.ProcessDaclSecurityInformation == 0x80000004u &&
            (Native.ProcessDaclSecurityInformation & 0x1bu) == 0,
            "Process policy sets only protected DACL, never owner/group/SACL/integrity label");
        var descriptor = Native.ProcessObservationDescriptor(owner);
        Native.AssertProcessObservationDescriptor(descriptor, owner); passed++;
        Check(ProcessPolicyAllows(descriptor, owner, 0x101000), "Registered owner can query limited identity and wait on SYSTEM-owned process");
        foreach (uint right in new uint[] { 1, 2, 8, 16, 32, 64, 0x400, 0x40000, 0x80000 }) {
            Check(!ProcessPolicyAllows(descriptor, owner, right), "Observer cannot terminate/inject/read memory/duplicate handles/query full/change process security");
            var broader = Native.ProcessObservationDescriptor(owner);
            ((CommonAce)broader.DiscretionaryAcl[2]).AccessMask |= (int)right;
            RejectProcessObservation(delegate { Native.AssertProcessObservationDescriptor(broader, owner); }, "serviceUnavailable", "Broader owner process ACE fails readback policy");
        }
        Check(!ProcessPolicyAllows(descriptor, foreign, 0x101000), "Foreign SID gains no process observation rights");
        RejectProcessObservation(delegate { Native.AssertProcessObservationDescriptor(Native.ProcessObservationDescriptor(foreign), owner); }, "serviceUnavailable", "Wrong owner ACE fails readback policy");
        RejectProcessObservation(delegate { Native.AssertProcessObservationDescriptor(new RawSecurityDescriptor(ControlFlags.None, null, null, null, null), owner); }, "serviceUnavailable", "NULL DACL cannot pass readback");
        var duplicate = Native.ProcessObservationDescriptor(owner);
        duplicate.DiscretionaryAcl.InsertAce(3, new CommonAce(AceFlags.None, AceQualifier.AccessAllowed, 0x101000, new SecurityIdentifier(owner), false, null));
        RejectProcessObservation(delegate { Native.AssertProcessObservationDescriptor(duplicate, owner); }, "serviceUnavailable", "Duplicate owner grant fails readback");
        var inherited = Native.ProcessObservationDescriptor(owner);
        inherited.DiscretionaryAcl[2].AceFlags = AceFlags.Inherited;
        RejectProcessObservation(delegate { Native.AssertProcessObservationDescriptor(inherited, owner); }, "serviceUnavailable", "Inherited owner grant fails readback");
        using (var identity = WindowsIdentity.GetCurrent()) {
            if (!identity.IsSystem) RejectProcessObservation(delegate { Native.ProtectOwnProcessObservation(owner); }, "serviceAccessDenied", "Non-SYSTEM invocation rejects before changing any process DACL");
        }
        Console.WriteLine("PASS exact SYSTEM-owned process observation policy, native owner/foreign access checks and forbidden process rights");
    }
    private static void TestBootProof() {
        const string prior = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        const string current = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
        Check(KernelEpoch.IsConfirmedRestart(prior, current), "Different trusted hive epochs prove old TUN resources cannot remain");
        Check(!KernelEpoch.IsConfirmedRestart(prior, prior), "Service restart in same hive cannot fabricate cleanup");
        Check(!KernelEpoch.IsConfirmedRestart(null, current), "Missing saved epoch must not bypass recovery proof");
        Check(!KernelEpoch.IsConfirmedRestart(prior, null), "Missing current epoch must not bypass recovery proof");
        Check(!KernelEpoch.IsConfirmedRestart("invalid", current), "Malformed old boot token cannot claim a reboot");
    }
    private static void TestVolatileRegistryEpoch(string owner) {
        var path = @"Software\HoneyVpnServiceFixture-" + Guid.NewGuid().ToString("N");
        var mutex = @"Local\HoneyVpnServiceFixture-" + Guid.NewGuid().ToString("N");
        try {
            using (var parent = Registry.CurrentUser.CreateSubKey(path)) {
                var identity = new SecurityIdentifier(owner);
                var epoch = KernelEpoch.TestReadInParent(parent, mutex, identity);
                Check(KernelEpoch.IsValid(epoch), "Native volatile epoch is a bounded random token");
                Check(KernelEpoch.TestReadInParent(parent, mutex, identity) == epoch, "Reopening/restarting a broker in the same hive preserves its epoch");
                var tasks = new Task<string>[8];
                for (int i = 0; i < tasks.Length; i++) tasks[i] = Task.Run(delegate { return KernelEpoch.TestReadInParent(parent, mutex, identity); });
                Check(Task.WaitAll(tasks, 5000), "Concurrent epoch requests must finish within the mutex bound");
                foreach (var task in tasks) Check(task.Result == epoch, "Concurrent creation cannot produce a false different-boot token");
                // Only this private HKCU fixture namespace is removed. The
                // production HKLM epoch is never reset by service operations.
                parent.DeleteSubKeyTree("KernelEpochV1");
                var next = KernelEpoch.TestReadInParent(parent, mutex, identity);
                Check(KernelEpoch.IsConfirmedRestart(epoch, next), "A fresh native volatile namespace has a different epoch");
            }
        } finally { Registry.CurrentUser.DeleteSubKeyTree(path, false); }
    }
}
