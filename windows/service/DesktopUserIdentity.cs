using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;

// The installer may run as another administrator or a Windows Administrator
// Protection account. Identity always comes from this desktop's actual shell;
// the installer's own SID/profile is never an identity fallback.
public static class DesktopUserIdentity {
    private const int AccessDenied = 5;
    private const int NoToken = 1008;
    private const string Failure = "desktop-context-unavailable";

    public static string ReadOwnerSid() { return Read(false); }
    public static string ReadRoamingPath() { return Read(true); }

    private static string Read(bool roaming) {
        var shell = GetShellWindow(); uint pid; uint session;
        if (shell == IntPtr.Zero || GetWindowThreadProcessId(shell, out pid) == 0 || pid == 0 ||
            !ProcessIdToSessionId(GetCurrentProcessId(), out session)) throw Unavailable();
        IntPtr process = IntPtr.Zero; IntPtr token = IntPtr.Zero; IntPtr path = IntPtr.Zero;
        try {
            process = OpenProcess(0x1000, false, pid);
            if (process == IntPtr.Zero) {
                if (Marshal.GetLastWin32Error() != AccessDenied) throw Unavailable();
                using (new DebugScope()) { process = OpenProcess(0x1000, false, pid); }
                if (process == IntPtr.Zero) throw Unavailable();
            }
            AssertShell(shell, pid, session, process);
            uint access = roaming ? 14u : 8u;
            if (!OpenProcessToken(process, access, out token)) {
                if (Marshal.GetLastWin32Error() != AccessDenied) throw Unavailable();
                // Retry against the original retained process, never a new PID.
                using (new DebugScope()) {
                    AssertShell(shell, pid, session, process);
                    if (!OpenProcessToken(process, access, out token)) throw Unavailable();
                }
            }
            // The temporary privilege has already been restored before profile
            // lookup or token metadata reads use their explicitly granted rights.
            uint tokenSession; uint returned;
            if (!GetTokenSession(token, 12, out tokenSession, 4, out returned) || tokenSession != session) throw Unavailable();
            string result;
            if (roaming) {
                Guid folder = new Guid("3EB685DB-65F9-4CF6-A03A-E3EF65729F3D");
                if (SHGetKnownFolderPath(ref folder, 0, token, out path) != 0 || path == IntPtr.Zero) throw Unavailable();
                result = Marshal.PtrToStringUni(path);
                if (String.IsNullOrWhiteSpace(result) || !Path.IsPathRooted(result)) throw Unavailable();
            } else {
                using (var identity = new WindowsIdentity(token)) {
                    if (identity.User == null) throw Unavailable();
                    result = identity.User.Value;
                }
            }
            AssertShell(shell, pid, session, process);
            return result;
        } finally {
            if (path != IntPtr.Zero) Marshal.FreeCoTaskMem(path);
            if (token != IntPtr.Zero) CloseHandle(token);
            if (process != IntPtr.Zero) CloseHandle(process);
        }
    }

    // Only the guard's named Honey UI/core CIM candidates use this read-only
    // resolver. It never enables debug privileges or opens any process token.
    public static string ReadProcessImage(uint pid) {
        if (pid == 0) throw Unavailable();
        var process = OpenProcess(0x1000, false, pid);
        if (process == IntPtr.Zero) throw Unavailable();
        try {
            AssertAlive(process);
            var image = new StringBuilder(32768); uint length = (uint)image.Capacity;
            if (!QueryFullProcessImageName(process, 0, image, ref length) || length == 0) throw Unavailable();
            AssertAlive(process);
            return image.ToString();
        } finally { CloseHandle(process); }
    }

    private static void AssertShell(IntPtr shell, uint pid, uint session, IntPtr process) {
        uint currentPid; uint actualSession;
        if (GetShellWindow() != shell || GetWindowThreadProcessId(shell, out currentPid) == 0 ||
            currentPid != pid || !ProcessIdToSessionId(pid, out actualSession) || actualSession != session) throw Unavailable();
        AssertAlive(process);
    }
    private static void AssertAlive(IntPtr process) {
        uint exit; NativeFileTime created, exited, kernel, user;
        if (!GetExitCodeProcess(process, out exit) || exit != 259 ||
            !GetProcessTimes(process, out created, out exited, out kernel, out user) ||
            exited.Low != 0 || exited.High != 0) throw Unavailable();
    }
    private static InvalidOperationException Unavailable() { return new InvalidOperationException(Failure); }

    private sealed class DebugScope : IDisposable {
        private IntPtr previousThread;
        private IntPtr duplicate;
        private TokenPrivileges previousPrivileges;
        private bool changed;
        private bool attached;
        internal DebugScope() {
            IntPtr source = IntPtr.Zero; bool closeSource = false;
            try {
                if (OpenThreadToken(GetCurrentThread(), 14, true, out previousThread)) source = previousThread;
                else {
                    if (Marshal.GetLastWin32Error() != NoToken ||
                        !OpenProcessToken(GetCurrentProcess(), 10, out source)) throw Unavailable();
                    closeSource = true;
                }
                if (!DuplicateTokenEx(source, 0x2c, IntPtr.Zero, 2, 2, out duplicate)) throw Unavailable();
                NativeLuid luid;
                if (!LookupPrivilegeValue(null, "SeDebugPrivilege", out luid)) throw Unavailable();
                var requested = new TokenPrivileges { Count = 1, Luid = luid, Attributes = 2 };
                uint returned; bool success; int error;
#if HONEY_SERVICE_TEST
                if (TestNotAssigned) { success = true; error = 1300; returned = 0; }
                else {
#endif
                    SetLastError(0);
                    success = AdjustTokenPrivileges(duplicate, false, ref requested, 16, out previousPrivileges, out returned);
                    error = Marshal.GetLastWin32Error();
#if HONEY_SERVICE_TEST
                }
#endif
                changed = previousPrivileges.Count != 0;
                // BOOL alone is insufficient: ERROR_NOT_ALL_ASSIGNED is failure.
                if (!success || error != 0 || previousPrivileges.Count > 1) throw Unavailable();
                if (!SetThreadToken(IntPtr.Zero, duplicate)) throw Unavailable();
                attached = true;
            } catch { Dispose(); throw Unavailable(); }
            finally { if (closeSource && source != IntPtr.Zero) CloseHandle(source); }
        }
        public void Dispose() {
            bool privilegeRestored = true; bool threadRestored = true;
            if (changed && duplicate != IntPtr.Zero) {
                SetLastError(0);
                privilegeRestored = RestoreTokenPrivileges(duplicate, false, ref previousPrivileges, 0, IntPtr.Zero, IntPtr.Zero) &&
                    Marshal.GetLastWin32Error() == 0;
            }
            if (attached) {
#if HONEY_SERVICE_TEST
                if (TestRestoreFailure) threadRestored = false;
                else
#endif
                threadRestored = previousThread == IntPtr.Zero ? RevertToSelf() : SetThreadToken(IntPtr.Zero, previousThread);
            }
            // A damaged impersonation context cannot return to the installer or
            // service code. Terminate this helper without a crash/credential dump.
            if (!privilegeRestored || !threadRestored) Environment.Exit(23);
            attached = false; changed = false;
            if (duplicate != IntPtr.Zero) { CloseHandle(duplicate); duplicate = IntPtr.Zero; }
            if (previousThread != IntPtr.Zero) { CloseHandle(previousThread); previousThread = IntPtr.Zero; }
        }
    }

#if HONEY_SERVICE_TEST
    internal static bool TestNotAssigned;
    internal static bool TestRestoreFailure;
    internal static void TestDebugScope(Action read) { using (new DebugScope()) { read(); } }
    internal static string TestTokenSnapshot(bool thread) {
        IntPtr token;
        if (thread) {
            if (!OpenThreadToken(GetCurrentThread(), 8, true, out token)) {
                if (Marshal.GetLastWin32Error() == NoToken) return "none";
                throw Unavailable();
            }
        } else if (!OpenProcessToken(GetCurrentProcess(), 8, out token)) throw Unavailable();
        try {
            uint size;
            GetTokenBytes(token, 3, IntPtr.Zero, 0, out size);
            if (size == 0 || size > 65536) throw Unavailable();
            var memory = Marshal.AllocHGlobal((int)size);
            try {
                if (!GetTokenBytes(token, 3, memory, size, out size)) throw Unavailable();
                var privileges = new byte[size]; Marshal.Copy(memory, privileges, 0, (int)size);
                var statistics = Marshal.AllocHGlobal(64);
                try {
                    if (!GetTokenBytes(token, 10, statistics, 64, out size)) throw Unavailable();
                    return Marshal.ReadInt64(statistics).ToString() + ":" + Convert.ToBase64String(privileges);
                } finally { Marshal.FreeHGlobal(statistics); }
            } finally { Marshal.FreeHGlobal(memory); }
        } finally { CloseHandle(token); }
    }
#endif

    [StructLayout(LayoutKind.Sequential)] private struct NativeLuid { internal uint Low; internal int High; }
    [StructLayout(LayoutKind.Sequential)] private struct NativeFileTime { internal uint Low; internal uint High; }
    [StructLayout(LayoutKind.Sequential)] private struct TokenPrivileges { internal uint Count; internal NativeLuid Luid; internal uint Attributes; }
    [DllImport("user32.dll")] private static extern IntPtr GetShellWindow();
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll")] private static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")] private static extern IntPtr GetCurrentThread();
    [DllImport("kernel32.dll")] private static extern uint GetCurrentProcessId();
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool ProcessIdToSessionId(uint pid, out uint session);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetExitCodeProcess(IntPtr process, out uint code);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetProcessTimes(IntPtr process, out NativeFileTime created, out NativeFileTime exited, out NativeFileTime kernel, out NativeFileTime user);
    [DllImport("kernel32.dll", EntryPoint = "QueryFullProcessImageNameW", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool QueryFullProcessImageName(IntPtr process, uint flags, StringBuilder image, ref uint length);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll")] private static extern void SetLastError(uint error);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool OpenThreadToken(IntPtr thread, uint access, bool self, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool DuplicateTokenEx(IntPtr source, uint access, IntPtr attributes, int level, int type, out IntPtr token);
    [DllImport("advapi32.dll", EntryPoint = "LookupPrivilegeValueW", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool LookupPrivilegeValue(string system, string name, out NativeLuid luid);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool AdjustTokenPrivileges(IntPtr token, bool all, ref TokenPrivileges state, uint size, out TokenPrivileges previous, out uint returned);
    [DllImport("advapi32.dll", EntryPoint = "AdjustTokenPrivileges", SetLastError = true)] private static extern bool RestoreTokenPrivileges(IntPtr token, bool all, ref TokenPrivileges state, uint size, IntPtr previous, IntPtr returned);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool SetThreadToken(IntPtr thread, IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool RevertToSelf();
    [DllImport("advapi32.dll", EntryPoint = "GetTokenInformation", SetLastError = true)] private static extern bool GetTokenSession(IntPtr token, int type, out uint session, uint size, out uint returned);
#if HONEY_SERVICE_TEST
    [DllImport("advapi32.dll", EntryPoint = "GetTokenInformation", SetLastError = true)] private static extern bool GetTokenBytes(IntPtr token, int type, IntPtr buffer, uint size, out uint returned);
#endif
    [DllImport("shell32.dll")] private static extern int SHGetKnownFolderPath(ref Guid folder, uint flags, IntPtr token, out IntPtr path);
}
