using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Net;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.ServiceProcess;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32;
using Microsoft.Win32.SafeHandles;

public sealed class HoneyVpnService : ServiceBase {
    public const string FixedServiceName = "HoneyVpnTunnelService";
    public const string FixedPipeName = "HoneyVpnTunnelService-v1";
    public const string RegistryPath = @"Software\HoneyVPN\HoneyProxyUtility\WindowsTunnel";
    private Broker broker;
    private Thread listener;
    private NamedPipeServerStream accepting;
    private volatile bool stopping;
    private readonly object pendingGate = new object();
    private readonly SemaphoreSlim handlerSlots = new SemaphoreSlim(7, 7);

    public HoneyVpnService() { ServiceName = FixedServiceName; CanStop = true; CanShutdown = true; AutoLog = false; }
    public static int Main(string[] args) {
        try {
            if (args.Length == 1 && args[0] == "--install") { Install(); return 0; }
            if (args.Length == 1 && args[0] == "--uninstall") { Uninstall(); return 0; }
            if (args.Length != 0 && (args.Length != 1 || args[0] != "--service")) return 2;
            ServiceBase.Run(new HoneyVpnService()); return 0;
        } catch { return 2; } // Installation never prints paths, identities or raw exceptions.
    }

    protected override void OnStart(string[] args) {
        var paths = ProtectedPaths.Load();
        // The ordinary UI retains and verifies this exact LocalSystem process.
        // Its default process DACL need not grant the installed owner query or
        // wait access. Publish no endpoint until the minimal grant is verified.
        Native.ProtectOwnProcessObservation(paths.OwnerSid);
        broker = new Broker(paths);
        // SCM must not report Running before the authenticated endpoint exists.
        accepting = Native.NewServerPipe(broker.Paths.OwnerSid, true);
        listener = new Thread(Listen) { IsBackground = true, Name = "HoneyVPN pipe listener" };
        listener.Start();
    }
    protected override void OnStop() {
        StopService(true);
    }
    private void StopService(bool requestScmTime) {
        NamedPipeServerStream current;
        lock (pendingGate) { stopping = true; current = accepting; accepting = null; }
        if (current != null) current.Dispose();
        if (requestScmTime) RequestAdditionalTime(35000);
        try { if (broker != null) broker.StopForServiceShutdown(); }
        catch {
            // ServiceBase restores Running after an OnStop exception. Exiting
            // instead lets the exact-parent watchdog finish its owned cleanup
            // and SCM perform bounded recovery. Install/uninstall independently
            // require the protected journal acknowledgement before file removal.
            Environment.Exit(1);
        }
        if (listener != null) listener.Join(2000);
    }
    protected override void OnShutdown() { StopService(false); }

    private void Listen() {
        NamedPipeServerStream next = null;
        try {
            next = accepting;
            while (!stopping) {
                if (!Native.WaitForConnection(ref next, broker.Paths.OwnerSid,
                    delegate { return stopping; }, PublishPending)) break;
                if (stopping) break;
                var connected = next;
                // Keep an instance alive continuously: no unprivileged process
                // can replace the server name between successive requests.
                next = Native.NewServerPipe(broker.Paths.OwnerSid, false);
                if (!PublishPending(next)) { connected.Dispose(); break; }
                if (!handlerSlots.Wait(0)) { connected.Dispose(); continue; }
                ThreadPool.QueueUserWorkItem(delegate {
                    try { Handle(connected); } finally { handlerSlots.Release(); }
                });
            }
        } catch {
            bool failed;
            lock (pendingGate) { failed = !stopping; if (failed) stopping = true; }
            if (failed) {
                try { broker.StopForServiceShutdown(); } catch { }
                // The retained supervisor watches this broker's exact process
                // identity. SCM recovery may restart the idle broker safely.
                Environment.Exit(1);
            }
        }
        finally {
            if (next != null) next.Dispose();
            lock (pendingGate) { if (Object.ReferenceEquals(accepting, next)) accepting = null; }
        }
    }
    private bool PublishPending(NamedPipeServerStream pipe) {
        lock (pendingGate) {
            if (stopping) return false;
            accepting = pipe; return true;
        }
    }

    private void Handle(NamedPipeServerStream pipe) {
        using (pipe) {
            try {
                var frameClock = Stopwatch.StartNew();
                var prefix = ReadExact(pipe, 4, frameClock);
                var length = BitConverter.ToInt32(prefix, 0);
                if (length < 2 || length > SafeTunConfiguration.MaxMessageBytes) return;
                using (var caller = Native.Authenticate(pipe, broker.Paths.OwnerSid)) {
                    var text = new UTF8Encoding(false, true).GetString(ReadExact(pipe, length, frameClock));
                    var request = SafeTunConfiguration.Map(SafeTunConfiguration.Serializer().DeserializeObject(text));
                    var result = broker.Dispatch(caller, request);
                    WriteReply(pipe, new Dictionary<string, object> { { "version", 1 }, { "ok", true }, { "result", result } });
                }
            } catch (RpcFailure failure) {
                try { WriteReply(pipe, new Dictionary<string, object> { { "version", 1 }, { "ok", false }, { "code", failure.Code } }); } catch { }
            } catch {
                try { WriteReply(pipe, new Dictionary<string, object> { { "version", 1 }, { "ok", false }, { "code", "startFailed" } }); } catch { }
            }
        }
    }
    private static byte[] ReadExact(Stream pipe, int length, Stopwatch clock) {
        var bytes = new byte[length]; int received = 0;
        while (received < length) {
            var pending = pipe.ReadAsync(bytes, received, length - received);
            var remaining = 5000 - clock.ElapsedMilliseconds;
            if (remaining <= 0 || !pending.Wait((int)remaining)) { pipe.Dispose(); throw new RpcFailure("serviceUnavailable"); }
            var count = pending.Result; if (count <= 0) throw new RpcFailure("serviceUnavailable"); received += count;
        }
        return bytes;
    }
    private static void WriteReply(Stream pipe, Dictionary<string, object> reply) {
        var payload = Encoding.UTF8.GetBytes(SafeTunConfiguration.Serializer().Serialize(reply));
        if (payload.Length > 16384) throw new RpcFailure("serviceUnavailable");
        var prefix = BitConverter.GetBytes(payload.Length);
        var clock = Stopwatch.StartNew();
        var first = pipe.WriteAsync(prefix, 0, prefix.Length);
        if (!first.Wait(5000)) { pipe.Dispose(); return; }
        var body = pipe.WriteAsync(payload, 0, payload.Length);
        var remaining = 5000 - clock.ElapsedMilliseconds;
        if (remaining <= 0 || !body.Wait((int)remaining)) pipe.Dispose();
    }

    private static void RequireAdministrator() {
        if (!new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator)) throw new RpcFailure("serviceAccessDenied");
    }
    private static void StopRegisteredService() {
        using (var controller = new ServiceController(FixedServiceName)) {
            try {
                var status = controller.Status;
                if (status != ServiceControllerStatus.Stopped) { controller.Stop(); controller.WaitForStatus(ServiceControllerStatus.Stopped, TimeSpan.FromSeconds(45)); }
            } catch (InvalidOperationException failure) {
                var native = failure.InnerException as Win32Exception;
                if (native == null || native.NativeErrorCode != 1060) throw;
            }
        }
    }
    private static void Install() {
        RequireAdministrator(); var install = ProtectedPaths.ValidateInstallation();
        var owner = Native.InteractiveOwnerSid(); if (String.IsNullOrEmpty(owner)) throw new RpcFailure("serviceAccessDenied");
        StopRegisteredService(); ConfirmPreviousCleanup(); ProtectedPaths.Configure(owner, install);
        var manager = Native.OpenSCManager(null, null, 3);
        if (manager == IntPtr.Zero) throw new RpcFailure("serviceAccessDenied");
        IntPtr service = IntPtr.Zero;
        try {
            var executable = Path.Combine(install, "HoneyVpnService.exe");
            var command = "\"" + executable + "\" --service";
            service = Native.CreateService(manager, FixedServiceName, "HoneyVPN Tunnel", 0xF01FF, 0x10, 2, 1,
                command, null, IntPtr.Zero, null, null, null);
            if (service == IntPtr.Zero) {
                if (Marshal.GetLastWin32Error() != 1073) throw new RpcFailure("serviceUnavailable");
                service = Native.OpenService(manager, FixedServiceName, 0xF01FF);
                if (service == IntPtr.Zero || !Native.ChangeServiceConfig(service, UInt32.MaxValue, 2, 1, command,
                    null, IntPtr.Zero, null, "LocalSystem", null, "HoneyVPN Tunnel")) throw new RpcFailure("serviceUnavailable");
            }
            Native.ProtectService(service, owner);
            Native.ConfigureRecovery(service);
            if (!Native.StartService(service, 0, IntPtr.Zero) && Marshal.GetLastWin32Error() != 1056) throw new RpcFailure("serviceUnavailable");
            using (var controller = new ServiceController(FixedServiceName)) controller.WaitForStatus(ServiceControllerStatus.Running, TimeSpan.FromSeconds(20));
        } finally { if (service != IntPtr.Zero) Native.CloseServiceHandle(service); Native.CloseServiceHandle(manager); }
    }
    private static void Uninstall() {
        RequireAdministrator(); ProtectedPaths.ValidateInstallation(); StopRegisteredService(); ConfirmPreviousCleanup();
        var manager = Native.OpenSCManager(null, null, 1); if (manager == IntPtr.Zero) throw new RpcFailure("serviceAccessDenied");
        var service = Native.OpenService(manager, FixedServiceName, 0x10000);
        try {
            if (service == IntPtr.Zero) { if (Marshal.GetLastWin32Error() == 1060) return; throw new RpcFailure("serviceUnavailable"); }
            if (!Native.DeleteService(service)) throw new RpcFailure("serviceUnavailable");
        } finally { if (service != IntPtr.Zero) Native.CloseServiceHandle(service); Native.CloseServiceHandle(manager); }
    }
    private static void ConfirmPreviousCleanup() {
        bool configured;
        using (var key = Registry.LocalMachine.OpenSubKey(RegistryPath)) configured = key != null && key.GetValue("OwnerSid") is string;
        if (!configured) {
            var root = ProtectedPaths.DataRoot();
            if (Directory.Exists(root) && Directory.GetFileSystemEntries(root).Length != 0) throw new RpcFailure("recoveryRequired");
            return;
        }
        // SCM Stopped alone is insufficient after a service crash. The retained
        // supervisor must acknowledge core and route cleanup before file removal.
        new Broker(ProtectedPaths.Load()).StopForServiceShutdown();
    }
}

public sealed class RpcFailure : Exception {
    public readonly string Code;
    public RpcFailure(string code) : base(code) { Code = code; }
}

internal sealed class Caller : IDisposable {
    internal readonly string Sid; internal readonly int Pid; internal readonly string Birth;
    internal Process Process;
    internal Caller(string sid, Process process) { Sid = sid; Process = process; Pid = process.Id; Birth = process.StartTime.ToUniversalTime().Ticks.ToString(); }
    internal Process TakeProcess() { var process = Process; Process = null; return process; }
    public void Dispose() { if (Process != null) Process.Dispose(); }
}

internal sealed class Session {
    internal string Nonce; internal int ParentPid; internal string ParentBirth; internal string OwnerSid;
    internal Process Parent; internal Process Supervisor;
    internal Dictionary<string, object> Public() { return new Dictionary<string, object> {
        { "nonce", Nonce }, { "parentPid", ParentPid }, { "parentStartTicks", ParentBirth }
    }; }
}

internal sealed class Broker {
    internal readonly ProtectedPaths Paths;
    private readonly object gate = new object();
    private Session active;
    private bool shuttingDown;
    private readonly HashSet<string> released = new HashSet<string>();
    private static readonly HashSet<string> SafeReasonCodes = new HashSet<string> {
        "none", "core-exited", "parent-exited", "broker-exited", "cancelled", "unsafe-path", "invalid-request", "invalid-config",
        "missing-core", "missing-gateway", "missing-interface-metric", "missing-proxy-settings", "proxy-notify-failed",
        "start-failed", "start-cancelled", "supervisor-failed", "proxy-settings-overridden", "proxy-restore-unconfirmed",
        "proxy-query-failed", "proxy-set-failed", "proxy-abi-mismatch"
    };
    internal Broker(ProtectedPaths paths) { Paths = paths; LoadActive(); }

    internal object Dispatch(Caller caller, Dictionary<string, object> request) {
        SafeTunConfiguration.Keys(request, "version,operation,nonce,config,httpPort,proxyIp");
        if (!Object.Equals(SafeTunConfiguration.Required(request, "version"), 1)) throw new RpcFailure("serviceAccessDenied");
        var operation = SafeTunConfiguration.GetText(request, "operation", 64);
        lock (gate) {
            if (shuttingDown) throw new RpcFailure("serviceUnavailable");
            if (caller.Sid != Paths.OwnerSid) throw new RpcFailure("serviceAccessDenied");
            if (operation == "readActive") return active == null ? null : active.Public();
            if (operation == "reserve") return Reserve(caller, request).Public();
            var nonce = SafeTunConfiguration.GetText(request, "nonce", 64);
            if (!Regex.IsMatch(nonce, "^[a-f0-9]{64}$")) throw new RpcFailure("serviceAccessDenied");
            if (released.Contains(nonce)) {
                if (operation == "snapshot") return StoppedState();
                if (operation == "signalStop" || operation == "release") return null;
                if (operation == "parentAlive") return false;
                throw new RpcFailure("startFailed");
            }
            if (active == null || active.Nonce != nonce || active.OwnerSid != caller.Sid) throw new RpcFailure("serviceAccessDenied");
            if (operation == "parentAlive") return ParentAlive(active);
            if (operation == "snapshot") return Snapshot(active);
            var state = Snapshot(active);
            // A second process cannot command a live first window's lease. A
            // dead parent or confirmed cleanup allows the same user's recovery.
            if (caller.Pid != active.ParentPid && ParentAlive(active) && !Stopped(state)) throw new RpcFailure("busy");
            switch (operation) {
                case "launch": Launch(active); return null;
                case "abortReservation":
                    if ((string)state["phase"] != "prepared") throw new RpcFailure("stopUnconfirmed");
                    WriteState(active, "failed", true); return null;
                case "signalStop": Signal(active); return null;
                case "release": Release(active); return null;
                default: throw new RpcFailure("serviceAccessDenied");
            }
        }
    }

    private Session Reserve(Caller caller, Dictionary<string, object> request) {
        if (active != null) throw new RpcFailure("busy");
        if (caller.Process.HasExited) throw new RpcFailure("startFailed");
        var httpPort = SafeTunConfiguration.Required(request, "httpPort");
        if (!(httpPort is int) || (int)httpPort < 1 || (int)httpPort > 65535) throw new RpcFailure("startFailed");
        object proxyIp = null;
        if (request.TryGetValue("proxyIp", out proxyIp) && proxyIp != null) {
            IPAddress ip;
            if (!(proxyIp is string) || !IPAddress.TryParse((string)proxyIp, out ip) || ip.AddressFamily != System.Net.Sockets.AddressFamily.InterNetwork) throw new RpcFailure("startFailed");
        }
        var session = new Session { Nonce = NewNonce(), ParentPid = caller.Pid, ParentBirth = caller.Birth, OwnerSid = caller.Sid };
        var directory = SessionPath(session, "");
        try {
            var config = SafeTunConfiguration.Prepare(SafeTunConfiguration.Required(request, "config"), Paths.Install, directory, session.Nonce);
            Directory.CreateDirectory(directory); ProtectedPaths.AssertPrivate(directory);
            WriteJson(SessionPath(session, "config.json"), config);
            WriteJson(SessionPath(session, "request.json"), new Dictionary<string, object> {
                { "version", 1 }, { "nonce", session.Nonce }, { "parentPid", session.ParentPid },
                { "parentStartTicks", session.ParentBirth }, { "ownerSid", session.OwnerSid },
                { "brokerParentPid", Process.GetCurrentProcess().Id },
                { "brokerParentStartTicks", Process.GetCurrentProcess().StartTime.ToUniversalTime().Ticks.ToString() },
                { "bootEpoch", Paths.BootEpoch },
                { "tunnel", true }, { "httpPort", httpPort }, { "proxyIp", proxyIp }
            });
            WriteState(session, "prepared", false);
            // No caller path/PID/SID, executable or arguments are ever persisted.
            using (var pointer = new FileStream(Path.Combine(Paths.Root, "active.json"), FileMode.CreateNew, FileAccess.Write, FileShare.None)) {
                var bytes = Encoding.UTF8.GetBytes(SafeTunConfiguration.Serializer().Serialize(new Dictionary<string, object> {
                    { "version", 1 }, { "nonce", session.Nonce }, { "scope", "service-tun" }, { "bootEpoch", Paths.BootEpoch }
                }));
                pointer.Write(bytes, 0, bytes.Length); pointer.Flush(true);
            }
            session.Parent = caller.TakeProcess(); active = session; return session;
        } catch {
            if (Directory.Exists(directory)) Directory.Delete(directory, true);
            throw new RpcFailure("startFailed");
        }
    }
    private void Launch(Session session) {
        var state = Snapshot(session);
        if ((string)state["phase"] != "prepared" || !ParentAlive(session)) throw new RpcFailure("startFailed");
        var script = Path.Combine(Paths.Install, "windows_vpn_supervisor.ps1");
        var core = Path.Combine(Paths.Install, "sing-box.exe");
        ProtectedPaths.AssertProgramFile(script); ProtectedPaths.AssertProgramFile(core);
        WriteState(session, "launching", false);
        var info = new ProcessStartInfo {
            FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe"),
            Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" + script + "\" -Request \"" + SessionPath(session, "request.json") + "\"",
            UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = Paths.Install
        };
        try {
            session.Supervisor = Process.Start(info);
            if (session.Supervisor == null) throw new InvalidOperationException();
            var originalHandle = session.Supervisor.Handle;
        } catch {
            // If process creation is uncertain, the nonce stop remains valid
            // for a late supervisor. Never forge cleanup of a possibly live core.
            Signal(session); throw new RpcFailure("startFailed");
        }
    }
    private bool ParentAlive(Session session) {
        if (session.Parent == null) return false;
        try { return !session.Parent.HasExited && session.Parent.StartTime.ToUniversalTime().Ticks.ToString() == session.ParentBirth; }
        catch { return false; }
    }
    private Dictionary<string, object> Snapshot(Session session) {
        var state = ReadJson(SessionPath(session, "state.json"));
        if (state == null || !Object.Equals(state["version"], 1) || !Object.Equals(state["nonce"], session.Nonce) || !(state["phase"] is string) || !(state["cleanupConfirmed"] is bool)) throw new RpcFailure("recoveryRequired");
        var phase = (string)state["phase"];
        if (Array.IndexOf(new[] { "prepared", "launching", "starting", "running", "stopping", "stopped", "failed" }, phase) < 0) throw new RpcFailure("recoveryRequired");
        var result = new Dictionary<string, object> { { "phase", phase }, { "cleanupConfirmed", state["cleanupConfirmed"] } };
        object value;
        if (state.TryGetValue("reasonCode", out value) && value is string && SafeReasonCodes.Contains((string)value)) result["reasonCode"] = value;
        if (state.TryGetValue("coreExitCode", out value) && value is int) result["coreExitCode"] = value;
        if (state.TryGetValue("connectElapsedMs", out value) && (value is int || value is long) && Convert.ToInt64(value) >= 0) result["connectElapsedMs"] = value;
        return result;
    }
    private void Signal(Session session) {
        var path = SessionPath(session, "stop"); ProtectedPaths.AssertPlain(path);
        File.WriteAllText(path, session.Nonce, new UTF8Encoding(false));
    }
    private void Release(Session session) {
        if (!Stopped(Snapshot(session))) throw new RpcFailure("stopUnconfirmed");
        var pointer = ReadJson(Path.Combine(Paths.Root, "active.json"));
        if (pointer == null || !Object.Equals(pointer["nonce"], session.Nonce)) throw new RpcFailure("recoveryRequired");
        var config = SessionPath(session, "config.json"); if (File.Exists(config)) File.Delete(config);
        File.Delete(Path.Combine(Paths.Root, "active.json"));
        released.Add(session.Nonce); if (released.Count > 512) released.Clear();
        active = null;
        if (session.Parent != null) session.Parent.Dispose();
        if (session.Supervisor != null) session.Supervisor.Dispose();
        try { Directory.Delete(SessionPath(session, ""), true); } catch { }
    }
    internal void StopForServiceShutdown() {
        Session session;
        lock (gate) { shuttingDown = true; session = active; if (session == null) return;
            var state = Snapshot(session); if ((string)state["phase"] == "prepared") WriteState(session, "failed", true); else Signal(session); }
        var clock = Stopwatch.StartNew();
        while (clock.ElapsedMilliseconds < 30000) {
            lock (gate) { if (active == null) return; if (Stopped(Snapshot(session))) { Release(session); return; } }
            Thread.Sleep(100);
        }
        throw new RpcFailure("stopUnconfirmed");
    }
    private void LoadActive() {
        var pointer = ReadJson(Path.Combine(Paths.Root, "active.json")); if (pointer == null) return;
        var nonce = SafeTunConfiguration.GetText(pointer, "nonce", 64);
        if (!Object.Equals(SafeTunConfiguration.Required(pointer, "version"), 1) || !Regex.IsMatch(nonce, "^[a-f0-9]{64}$") ||
            !Object.Equals(SafeTunConfiguration.Required(pointer, "scope"), "service-tun")) throw new RpcFailure("recoveryRequired");
        var session = new Session { Nonce = nonce };
        var epoch = SafeTunConfiguration.GetText(pointer, "bootEpoch", 32);
        if (!KernelEpoch.IsValid(epoch)) throw new RpcFailure("recoveryRequired");
        if (KernelEpoch.IsConfirmedRestart(epoch, Paths.BootEpoch)) {
            // Only this service's TUN sessions use this protected namespace.
            // Its processes, TUN handles and ActiveStore-only routes cannot
            // survive a proven full kernel/hive restart. It never writes HKCU.
            Directory.CreateDirectory(SessionPath(session, ""));
            ProtectedPaths.AssertPrivate(SessionPath(session, ""));
            active = session; WriteState(session, "failed", true); Release(session); return;
        }
        var request = ReadJson(SessionPath(session, "request.json")); if (request == null) throw new RpcFailure("recoveryRequired");
        if (!Object.Equals(request["ownerSid"], Paths.OwnerSid) || !Object.Equals(request["nonce"], nonce) || !Object.Equals(request["tunnel"], true) || !(request["parentPid"] is int)) throw new RpcFailure("recoveryRequired");
        session.OwnerSid = Paths.OwnerSid; session.ParentPid = (int)request["parentPid"];
        session.ParentBirth = SafeTunConfiguration.GetText(request, "parentStartTicks", 32);
        if (session.ParentPid <= 0 || !Regex.IsMatch(session.ParentBirth, "^\\d{15,20}$")) throw new RpcFailure("recoveryRequired");
        try {
            var parent = Process.GetProcessById(session.ParentPid); var originalHandle = parent.Handle;
            if (!parent.HasExited && parent.StartTime.ToUniversalTime().Ticks.ToString() == session.ParentBirth && Native.ProcessOwnerSid(parent) == session.OwnerSid) session.Parent = parent;
            else parent.Dispose();
        } catch { }
        active = session;
        var state = Snapshot(session);
        if (!ParentAlive(session)) {
            if ((string)state["phase"] == "prepared") WriteState(session, "failed", true);
            else if (!Stopped(state)) Signal(session);
        }
    }
    private string SessionPath(Session session, string file) {
        if (!Regex.IsMatch(session.Nonce ?? "", "^[a-f0-9]{64}$")) throw new RpcFailure("serviceAccessDenied");
        return Path.Combine(Paths.Root, session.Nonce, file);
    }
    private static bool Stopped(Dictionary<string, object> state) { return ((string)state["phase"] == "stopped" || (string)state["phase"] == "failed") && Object.Equals(state["cleanupConfirmed"], true); }
    private static Dictionary<string, object> StoppedState() { return new Dictionary<string, object> { { "phase", "stopped" }, { "cleanupConfirmed", true } }; }
    private void WriteState(Session session, string phase, bool cleanup) { WriteJson(SessionPath(session, "state.json"), new Dictionary<string, object> {
        { "version", 1 }, { "nonce", session.Nonce }, { "phase", phase }, { "cleanupConfirmed", cleanup }
    }); }
    private static string NewNonce() {
        var bytes = new byte[32]; using (var rng = System.Security.Cryptography.RandomNumberGenerator.Create()) rng.GetBytes(bytes);
        return BitConverter.ToString(bytes).Replace("-", "").ToLowerInvariant();
    }
    private static Dictionary<string, object> ReadJson(string path) {
        ProtectedPaths.AssertPlain(path); if (!File.Exists(path)) return null;
        if (new FileInfo(path).Length > 16384) throw new RpcFailure("recoveryRequired");
        return SafeTunConfiguration.Map(SafeTunConfiguration.Serializer().DeserializeObject(File.ReadAllText(path, Encoding.UTF8)));
    }
    private static void WriteJson(string path, object value) {
        ProtectedPaths.AssertPlain(path); var temporary = path + ".service.tmp"; ProtectedPaths.AssertPlain(temporary);
        File.WriteAllText(temporary, SafeTunConfiguration.Serializer().Serialize(value), new UTF8Encoding(false));
        if (File.Exists(path)) File.Replace(temporary, path, null); else File.Move(temporary, path);
    }
}

internal sealed class ProtectedPaths {
    internal string Install; internal string Root; internal string OwnerSid; internal string BootEpoch;
    private static readonly SecurityIdentifier SystemSid = new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null);
    private static readonly SecurityIdentifier AdminSid = new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null);
    private static readonly SecurityIdentifier UsersSid = new SecurityIdentifier(WellKnownSidType.BuiltinUsersSid, null);
#if HONEY_SERVICE_TEST
    internal static string TestDataRoot;
#endif
    internal static string DataRoot() {
#if HONEY_SERVICE_TEST
        if (TestDataRoot != null) return TestDataRoot;
#endif
        return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "HoneyVPN", "WindowsTunnel");
    }
    internal static string ValidateInstallation() {
        var expected = Path.GetFullPath(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "HoneyProxyUtility"));
        var executable = Path.GetFullPath(Assembly.GetExecutingAssembly().Location);
        if (!String.Equals(executable, Path.Combine(expected, "HoneyVpnService.exe"), StringComparison.OrdinalIgnoreCase)) throw new RpcFailure("serviceAccessDenied");
        AssertProgramFile(executable); AssertProgramFile(Path.Combine(expected, "sing-box.exe"));
        AssertProgramFile(Path.Combine(expected, "windows_vpn_supervisor.ps1"));
        foreach (var name in new[] { "ru-blocked.srs", "ru-blocked-community.srs", "re-filter.srs", "ru.srs" })
            AssertProgramFile(Path.Combine(expected, "data", "flutter_assets", "assets", "geo", name));
        return expected;
    }
    internal static void Configure(string owner, string install) {
        new SecurityIdentifier(owner);
        var root = DataRoot(); var parent = Directory.GetParent(root).FullName;
        AssertPlain(parent); AssertPlain(root);
        AssertAncestorsSafe(parent);
        // Tightening a DACL does not revoke previously opened writable handles.
        // Even an empty user-planted namespace must never be adopted by SYSTEM.
        if (Directory.Exists(parent)) AssertProtected(Directory.GetAccessControl(parent), false);
        if (Directory.Exists(root)) AssertPrivate(root);
        bool previouslyConfigured;
        using (var key = Registry.LocalMachine.OpenSubKey(HoneyVpnService.RegistryPath)) previouslyConfigured = key != null && key.GetValue("OwnerSid") is string;
        if (Directory.Exists(root) && Directory.GetFileSystemEntries(root).Length != 0) {
            // Never elevate a user-planted request or journal on first install.
            if (!previouslyConfigured) throw new RpcFailure("recoveryRequired");
            AssertPrivate(root);
        }
        Directory.CreateDirectory(parent, DirectorySecurityFor(false));
        AssertPlain(parent); AssertProtected(Directory.GetAccessControl(parent), false);
        Directory.CreateDirectory(root, DirectorySecurityFor(true)); AssertPrivate(root);
        using (var key = Registry.LocalMachine.CreateSubKey(HoneyVpnService.RegistryPath)) {
            var acl = new RegistrySecurity(); acl.SetAccessRuleProtection(true, false); acl.SetOwner(AdminSid);
            acl.AddAccessRule(new RegistryAccessRule(SystemSid, RegistryRights.FullControl, InheritanceFlags.ContainerInherit, PropagationFlags.None, AccessControlType.Allow));
            acl.AddAccessRule(new RegistryAccessRule(AdminSid, RegistryRights.FullControl, InheritanceFlags.ContainerInherit, PropagationFlags.None, AccessControlType.Allow));
            acl.AddAccessRule(new RegistryAccessRule(UsersSid, RegistryRights.ReadKey, InheritanceFlags.ContainerInherit, PropagationFlags.None, AccessControlType.Allow));
            key.SetAccessControl(acl); key.SetValue("OwnerSid", owner, RegistryValueKind.String);
        }
    }
    internal static ProtectedPaths Load() {
        var install = ValidateInstallation(); string owner;
        using (var key = Registry.LocalMachine.OpenSubKey(HoneyVpnService.RegistryPath)) owner = key == null ? null : key.GetValue("OwnerSid") as string;
        if (String.IsNullOrEmpty(owner)) throw new RpcFailure("serviceAccessDenied"); new SecurityIdentifier(owner);
        var root = DataRoot(); AssertPrivate(root);
        var parent = Directory.GetParent(root).FullName; AssertPlain(parent);
        AssertProtected(Directory.GetAccessControl(parent), false);
        return new ProtectedPaths { Install = install, Root = root, OwnerSid = owner, BootEpoch = KernelEpoch.Read() };
    }
    internal static void AssertPlain(string path) {
        var full = Path.GetFullPath(path);
        if (!Path.IsPathRooted(path) || full.StartsWith(@"\\", StringComparison.Ordinal)) throw new RpcFailure("serviceAccessDenied");
        for (var current = full; !String.IsNullOrEmpty(current); current = Path.GetDirectoryName(current)) {
            try { if ((File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0) throw new RpcFailure("serviceAccessDenied"); }
            catch (FileNotFoundException) { } catch (DirectoryNotFoundException) { }
        }
    }
    internal static void AssertProgramFile(string path) {
        AssertPlain(path); if (!File.Exists(path)) throw new RpcFailure("serviceUnavailable");
        AssertAncestorsSafe(path);
        AssertProtected(File.GetAccessControl(path), false);
        var root = Path.GetFullPath(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "HoneyProxyUtility"));
        var directory = Path.GetDirectoryName(path);
        while (directory != null && (String.Equals(directory, root, StringComparison.OrdinalIgnoreCase) ||
            directory.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))) {
            AssertProtected(Directory.GetAccessControl(directory), false);
            directory = Path.GetDirectoryName(directory);
        }
    }
    internal static void AssertPrivate(string directory) { AssertPlain(directory); AssertAncestorsSafe(directory); AssertProtected(Directory.GetAccessControl(directory), true); }
    private static void AssertAncestorsSafe(string path) {
        for (var ancestor = Path.GetDirectoryName(Path.GetFullPath(path)); !String.IsNullOrEmpty(ancestor); ancestor = Path.GetDirectoryName(ancestor)) {
            if (Directory.Exists(ancestor)) AssertAncestorAcl(Directory.GetAccessControl(ancestor));
        }
    }
    internal static void AssertAncestorAcl(FileSystemSecurity acl) {
        // Normal C:\/ProgramData permit creating unrelated child directories.
        // Only rights that can replace this protected subtree are dangerous.
        var owner = (SecurityIdentifier)acl.GetOwner(typeof(SecurityIdentifier));
        if (!TrustedWriter(owner)) throw new RpcFailure("serviceAccessDenied");
        const FileSystemRights replace = FileSystemRights.Delete | FileSystemRights.DeleteSubdirectoriesAndFiles |
            FileSystemRights.ChangePermissions | FileSystemRights.TakeOwnership;
        foreach (FileSystemAccessRule rule in acl.GetAccessRules(true, true, typeof(SecurityIdentifier))) {
            if (rule.AccessControlType == AccessControlType.Allow && (rule.PropagationFlags & PropagationFlags.InheritOnly) == 0 &&
                (rule.FileSystemRights & replace) != 0 && !TrustedWriter((SecurityIdentifier)rule.IdentityReference)) throw new RpcFailure("serviceAccessDenied");
        }
    }
    private static void AssertProtected(FileSystemSecurity acl, bool privateData) {
        var owner = (SecurityIdentifier)acl.GetOwner(typeof(SecurityIdentifier));
        if (!TrustedWriter(owner)) throw new RpcFailure("serviceAccessDenied");
        const FileSystemRights write = FileSystemRights.WriteData | FileSystemRights.AppendData | FileSystemRights.WriteAttributes |
            FileSystemRights.WriteExtendedAttributes | FileSystemRights.Delete | FileSystemRights.DeleteSubdirectoriesAndFiles |
            FileSystemRights.ChangePermissions | FileSystemRights.TakeOwnership;
        foreach (FileSystemAccessRule rule in acl.GetAccessRules(true, true, typeof(SecurityIdentifier))) {
            if (rule.AccessControlType != AccessControlType.Allow || (rule.PropagationFlags & PropagationFlags.InheritOnly) != 0) continue;
            var identity = (SecurityIdentifier)rule.IdentityReference;
            if ((!privateData && (rule.FileSystemRights & write) == 0) || TrustedWriter(identity)) continue;
            throw new RpcFailure("serviceAccessDenied");
        }
    }
    private static bool TrustedWriter(SecurityIdentifier sid) { return sid.Equals(SystemSid) || sid.Equals(AdminSid) || sid.Value == "S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464"; }
    private static DirectorySecurity DirectorySecurityFor(bool privateData) {
        var acl = new DirectorySecurity(); acl.SetAccessRuleProtection(true, false); acl.SetOwner(AdminSid);
        foreach (var sid in new[] { SystemSid, AdminSid }) acl.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl,
            InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
        if (!privateData) acl.AddAccessRule(new FileSystemAccessRule(UsersSid, FileSystemRights.ReadAndExecute,
            InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
        return acl;
    }
}

internal static class Native {
    internal const int ProcessObservationRights = 0x101000; // QUERY_LIMITED_INFORMATION | SYNCHRONIZE
    internal const uint ProcessDaclSecurityInformation = 0x80000004u; // PROTECTED_DACL | DACL, never owner/group/SACL
    private const int ProcessAllAccess = 0x1fffff;
    [StructLayout(LayoutKind.Sequential)] private struct SecurityAttributes { internal int Length; internal IntPtr Descriptor; internal int Inherit; }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern SafePipeHandle CreateNamedPipe(string name, uint open, uint mode, uint instances, uint output, uint input, uint timeout, ref SecurityAttributes security);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool ImpersonateNamedPipeClient(SafePipeHandle pipe);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool RevertToSelf();
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetNamedPipeClientProcessId(SafePipeHandle pipe, out uint pid);
    [DllImport("user32.dll")] private static extern IntPtr GetShellWindow();
    [DllImport("user32.dll", SetLastError = true)] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll")] private static extern IntPtr GetCurrentProcess();
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool GetKernelObjectSecurity(IntPtr handle, uint info, [Out] byte[] descriptor, uint size, out uint needed);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool GetSecurityDescriptorDacl(IntPtr descriptor, out bool present, out IntPtr dacl, out bool defaulted);
    [DllImport("advapi32.dll")] private static extern uint SetSecurityInfo(IntPtr handle, uint type, uint info, IntPtr owner, IntPtr group, IntPtr dacl, IntPtr sacl);
    private static RawSecurityDescriptor ReadProcessDescriptor(IntPtr process) {
        uint needed;
        if (GetKernelObjectSecurity(process, 7, null, 0, out needed) ||
            Marshal.GetLastWin32Error() != 122 || needed == 0 || needed > 16384) throw new RpcFailure("serviceUnavailable");
        var bytes = new byte[needed]; uint returned;
        if (!GetKernelObjectSecurity(process, 7, bytes, needed, out returned) || returned == 0 || returned > needed) throw new RpcFailure("serviceUnavailable");
        return new RawSecurityDescriptor(bytes, 0);
    }
    internal static RawSecurityDescriptor ProcessObservationDescriptor(string owner) {
        var sid = new SecurityIdentifier(owner);
        if (sid.Equals(new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null)) ||
            sid.Equals(new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null))) throw new RpcFailure("serviceAccessDenied");
        return new RawSecurityDescriptor("D:P(A;;0x1fffff;;;SY)(A;;0x1fffff;;;BA)(A;;0x101000;;;" + sid.Value + ")");
    }
    internal static void AssertProcessObservationDescriptor(RawSecurityDescriptor descriptor, string owner) {
        var sid = new SecurityIdentifier(owner);
        var system = new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null);
        var admin = new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null);
        if (descriptor == null ||
            (descriptor.ControlFlags & (ControlFlags.DiscretionaryAclPresent | ControlFlags.DiscretionaryAclProtected)) !=
                (ControlFlags.DiscretionaryAclPresent | ControlFlags.DiscretionaryAclProtected) ||
            descriptor.DiscretionaryAcl == null || descriptor.DiscretionaryAcl.Count != 3 || sid.Equals(system) || sid.Equals(admin)) throw new RpcFailure("serviceUnavailable");
        bool foundSystem = false, foundAdmin = false, foundOwner = false;
        foreach (GenericAce entry in descriptor.DiscretionaryAcl) {
            var ace = entry as CommonAce;
            if (ace == null || ace.AceQualifier != AceQualifier.AccessAllowed || ace.AceFlags != AceFlags.None || ace.IsCallback) throw new RpcFailure("serviceUnavailable");
            if (ace.SecurityIdentifier.Equals(system) && !foundSystem && ace.AccessMask == ProcessAllAccess) foundSystem = true;
            else if (ace.SecurityIdentifier.Equals(admin) && !foundAdmin && ace.AccessMask == ProcessAllAccess) foundAdmin = true;
            else if (ace.SecurityIdentifier.Equals(sid) && !foundOwner && ace.AccessMask == ProcessObservationRights) foundOwner = true;
            else throw new RpcFailure("serviceUnavailable");
        }
        if (!foundSystem || !foundAdmin || !foundOwner) throw new RpcFailure("serviceUnavailable");
    }
    internal static void ProtectOwnProcessObservation(string owner) {
        using (var identity = WindowsIdentity.GetCurrent()) {
            if (!identity.IsSystem) throw new RpcFailure("serviceAccessDenied");
        }
        // Only the current kernel process is changed. Its owner/group, SACL
        // (including the integrity label), token and child defaults stay intact.
        var process = GetCurrentProcess();
        var before = ReadProcessDescriptor(process);
        var desired = ProcessObservationDescriptor(owner);
        AssertProcessObservationDescriptor(desired, owner);
        var bytes = new byte[desired.BinaryLength]; desired.GetBinaryForm(bytes, 0);
        var pin = GCHandle.Alloc(bytes, GCHandleType.Pinned);
        try {
            bool present, defaulted; IntPtr dacl;
            if (!GetSecurityDescriptorDacl(pin.AddrOfPinnedObject(), out present, out dacl, out defaulted) ||
                !present || dacl == IntPtr.Zero || SetSecurityInfo(process, 6, ProcessDaclSecurityInformation,
                    IntPtr.Zero, IntPtr.Zero, dacl, IntPtr.Zero) != 0) throw new RpcFailure("serviceUnavailable");
        } finally { pin.Free(); }
        var after = ReadProcessDescriptor(process);
        AssertProcessObservationDescriptor(after, owner);
        if (!Object.Equals(before.Owner, after.Owner) || !Object.Equals(before.Group, after.Group)) throw new RpcFailure("serviceUnavailable");
    }
    internal static NamedPipeServerStream NewServerPipe(string owner, bool first) {
        return CreateServerPipe(owner, first, HoneyVpnService.FixedPipeName);
    }
    internal static bool WaitForConnection(ref NamedPipeServerStream pending, string owner,
        Func<bool> stopping, Func<NamedPipeServerStream, bool> publish) {
        return WaitForConnectionCore(ref pending, stopping, publish,
            delegate { return NewServerPipe(owner, false); });
    }
    private static bool IsEarlyClientDisconnect(IOException failure) {
        // HRESULT_FROM_WIN32(ERROR_NO_DATA). Only ConnectNamedPipe's documented
        // closed-before-accept lifecycle state is recoverable here.
        return failure.HResult == unchecked((int)0x800700e8);
    }
    private static bool WaitForConnectionCore(ref NamedPipeServerStream pending,
        Func<bool> stopping, Func<NamedPipeServerStream, bool> publish,
        Func<NamedPipeServerStream> createReplacement) {
        if (!publish(pending)) return false;
        while (!stopping()) {
            try { pending.WaitForConnection(); return !stopping(); }
            catch (IOException failure) {
                if (stopping()) return false;
                if (!IsEarlyClientDisconnect(failure)) throw;
                // Keep the authenticated name and DACL alive while replacing
                // its unusable instance. Resource/creation errors stay fatal.
                var failed = pending;
                pending = createReplacement();
                try { if (!publish(pending)) return false; }
                finally { failed.Dispose(); }
                // Benign cancellations cannot exhaust a retry counter. Handles
                // remain bounded (old+new) and stop is observed within 50 ms.
                Thread.Sleep(50);
            }
        }
        return false;
    }
#if HONEY_SERVICE_TEST
    internal static NamedPipeServerStream TestServerPipe(string owner, bool first, string name) { return CreateServerPipe(owner, first, name); }
    internal static bool TestWaitForConnection(ref NamedPipeServerStream pending, string owner, string name,
        Func<bool> stopping, Func<NamedPipeServerStream, bool> publish) {
        return WaitForConnectionCore(ref pending, stopping, publish,
            delegate { return CreateServerPipe(owner, false, name); });
    }
    internal static bool TestIsEarlyClientDisconnect(IOException failure) { return IsEarlyClientDisconnect(failure); }
    [DllImport("kernel32.dll", EntryPoint = "CreateFileW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafePipeHandle TestOpenPipe(string path, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
    internal static void TestCloseBeforeAccept(string name) {
        // Managed Connect first calls WaitNamedPipe, so use the actual Win32
        // open to deterministically connect before ConnectNamedPipe is armed.
        using (var client = TestOpenPipe(@"\\.\pipe\" + name, 0x12019b, 0, IntPtr.Zero, 3, 0x40110000, IntPtr.Zero)) {
            if (client.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
        }
    }
#endif
    private static NamedPipeServerStream CreateServerPipe(string owner, bool first, string name) {
        // GenericWrite includes CreateNewInstance! Grant precise client rights,
        // leaving instance creation available only to SYSTEM/Administrators.
        var acl = new PipeSecurity(); acl.SetSecurityDescriptorSddlForm("D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;0x12019b;;;" + owner + ")");
        var bytes = acl.GetSecurityDescriptorBinaryForm(); var pin = GCHandle.Alloc(bytes, GCHandleType.Pinned);
        try {
            var security = new SecurityAttributes { Length = Marshal.SizeOf(typeof(SecurityAttributes)), Descriptor = pin.AddrOfPinnedObject() };
            var handle = CreateNamedPipe(@"\\.\pipe\" + name, 3u | 0x40000000u | (first ? 0x80000u : 0),
                4u | 2u | 8u, 255, 4096, 4096, 5000, ref security);
            if (handle.IsInvalid) { handle.Dispose(); throw new RpcFailure("serviceUnavailable"); }
            return new NamedPipeServerStream(PipeDirection.InOut, true, false, handle);
        } finally { pin.Free(); }
    }
    internal static Caller Authenticate(NamedPipeServerStream pipe, string owner) {
        uint pid; if (!GetNamedPipeClientProcessId(pipe.SafePipeHandle, out pid) || pid == 0 || pid > Int32.MaxValue) throw new RpcFailure("serviceAccessDenied");
        if (!ImpersonateNamedPipeClient(pipe.SafePipeHandle)) throw new RpcFailure("serviceAccessDenied");
        string sid = null;
        try { using (var identity = WindowsIdentity.GetCurrent(true)) { if (identity != null && identity.User != null) sid = identity.User.Value; } }
        finally { if (!RevertToSelf()) Environment.FailFast("serviceAccessDenied"); }
        if (sid != owner) throw new RpcFailure("serviceAccessDenied");
        var process = Process.GetProcessById((int)pid);
        try {
            var retainedHandle = process.Handle;
            if (process.HasExited || ProcessOwnerSid(process) != sid) throw new RpcFailure("serviceAccessDenied");
            return new Caller(sid, process);
        } catch { process.Dispose(); throw; }
    }
    internal static string ProcessOwnerSid(Process process) {
        IntPtr token; if (!OpenProcessToken(process.Handle, 8, out token)) throw new RpcFailure("serviceAccessDenied");
        try { using (var identity = new WindowsIdentity(token)) { return identity.User == null ? null : identity.User.Value; } }
        finally { CloseHandle(token); }
    }
    internal static string InteractiveOwnerSid() {
        try { return DesktopUserIdentity.ReadOwnerSid(); }
        catch (InvalidOperationException) { return null; }
    }
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] internal static extern IntPtr OpenSCManager(string machine, string database, uint access);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] internal static extern IntPtr CreateService(IntPtr manager, string name, string display, uint access, uint type, uint start, uint error, string binary, string group, IntPtr tag, string dependencies, string account, string password);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] internal static extern IntPtr OpenService(IntPtr manager, string name, uint access);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] internal static extern bool ChangeServiceConfig(IntPtr service, uint type, uint start, uint error, string binary, string group, IntPtr tag, string dependencies, string account, string password, string display);
    [DllImport("advapi32.dll", SetLastError = true)] internal static extern bool StartService(IntPtr service, uint count, IntPtr args);
    [DllImport("advapi32.dll", SetLastError = true)] internal static extern bool DeleteService(IntPtr service);
    [DllImport("advapi32.dll")] internal static extern bool CloseServiceHandle(IntPtr handle);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool ConvertStringSecurityDescriptorToSecurityDescriptor(string text, uint revision, out IntPtr descriptor, out uint length);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool SetServiceObjectSecurity(IntPtr service, uint info, IntPtr descriptor);
    [DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr memory);
    internal static void ProtectService(IntPtr service, string owner) {
        IntPtr descriptor; uint length;
        if (!ConvertStringSecurityDescriptorToSecurityDescriptor("O:BAD:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;CCLCRPLORC;;;" + owner + ")", 1, out descriptor, out length)) throw new RpcFailure("serviceUnavailable");
        try {
            if (!SetServiceObjectSecurity(service, 5, descriptor)) throw new RpcFailure("serviceUnavailable");
            VerifyServiceOwner(service);
        }
        finally { LocalFree(descriptor); }
    }
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool QueryServiceObjectSecurity(IntPtr service, uint info, IntPtr descriptor, uint size, out uint needed);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool GetSecurityDescriptorOwner(IntPtr descriptor, out IntPtr owner, out bool defaulted);
    private static void VerifyServiceOwner(IntPtr service) {
        uint needed; QueryServiceObjectSecurity(service, 1, IntPtr.Zero, 0, out needed);
        if (needed == 0 || needed > 16384) throw new RpcFailure("serviceUnavailable");
        var descriptor = Marshal.AllocHGlobal((int)needed);
        try {
            IntPtr owner; bool defaulted;
            if (!QueryServiceObjectSecurity(service, 1, descriptor, needed, out needed) ||
                !GetSecurityDescriptorOwner(descriptor, out owner, out defaulted) || owner == IntPtr.Zero ||
                !new SecurityIdentifier(owner).Equals(new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null))) throw new RpcFailure("serviceUnavailable");
        } finally { Marshal.FreeHGlobal(descriptor); }
    }
    [StructLayout(LayoutKind.Sequential)] private struct RecoveryAction { internal uint Type; internal uint Delay; }
    [StructLayout(LayoutKind.Sequential)] private struct FailureActions {
        internal uint ResetPeriod; internal IntPtr RebootMessage; internal IntPtr Command; internal uint Count; internal IntPtr Actions;
    }
    [DllImport("advapi32.dll", EntryPoint = "ChangeServiceConfig2W", SetLastError = true)]
    private static extern bool ChangeRecovery(IntPtr service, uint level, ref FailureActions actions);
    internal static void ConfigureRecovery(IntPtr service) {
        if (IntPtr.Size != 8 || Marshal.SizeOf(typeof(FailureActions)) != 40 || Marshal.SizeOf(typeof(RecoveryAction)) != 8) throw new RpcFailure("serviceUnavailable");
        var array = Marshal.AllocHGlobal(24); var empty = Marshal.StringToHGlobalUni("");
        try {
            Marshal.StructureToPtr(new RecoveryAction { Type = 1, Delay = 5000 }, array, false);
            Marshal.StructureToPtr(new RecoveryAction { Type = 1, Delay = 10000 }, IntPtr.Add(array, 8), false);
            Marshal.StructureToPtr(new RecoveryAction { Type = 0, Delay = 0 }, IntPtr.Add(array, 16), false);
            var actions = new FailureActions { ResetPeriod = 86400, RebootMessage = empty, Command = empty, Count = 3, Actions = array };
            // Restart only, with no caller-controlled recovery command/reboot.
            if (!ChangeRecovery(service, 2, ref actions)) throw new RpcFailure("serviceUnavailable");
        } finally { Marshal.FreeHGlobal(array); Marshal.FreeHGlobal(empty); }
    }
}
