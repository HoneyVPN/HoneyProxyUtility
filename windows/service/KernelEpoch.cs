using System;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text.RegularExpressions;
using System.Threading;
using Microsoft.Win32;

// Documented REG_OPTION_VOLATILE lifetime provides a kernel/hive epoch without
// undocumented NtQuerySystemInformation or approximate wall-clock boot times.
// Never remove/reset this key on service/UI restart, install or uninstall.
internal static class KernelEpoch {
    private const string Parent = @"SYSTEM\HoneyVPN";
    private const string Child = "KernelEpochV1";
    private const string MutexName = @"Global\HoneyVpnKernelEpochV1";
    private static readonly SecurityIdentifier SystemSid = new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null);
    private static readonly SecurityIdentifier AdminSid = new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null);

    internal static bool IsValid(string epoch) { return Regex.IsMatch(epoch ?? "", "^[a-f0-9]{32}$"); }
    internal static bool IsConfirmedRestart(string saved, string current) { return IsValid(saved) && IsValid(current) && saved != current; }
    internal static string Read() {
        var security = RegistrySecurityFor(null);
        using (var existing = Registry.LocalMachine.OpenSubKey(Parent, true)) {
            if (existing != null) { AssertTrusted(existing.GetAccessControl()); return ReadInParent(existing, MutexName, null); }
        }
        using (var parent = Registry.LocalMachine.CreateSubKey(Parent, RegistryKeyPermissionCheck.ReadWriteSubTree, RegistryOptions.None, security)) {
            AssertTrusted(parent.GetAccessControl()); return ReadInParent(parent, MutexName, null);
        }
    }
    private static string ReadInParent(RegistryKey parent, string mutexName, SecurityIdentifier testOwner) {
        var mutexSecurity = new MutexSecurity(); mutexSecurity.SetAccessRuleProtection(true, false); mutexSecurity.SetOwner(AdminSid);
        mutexSecurity.AddAccessRule(new MutexAccessRule(SystemSid, MutexRights.FullControl, AccessControlType.Allow));
        mutexSecurity.AddAccessRule(new MutexAccessRule(AdminSid, MutexRights.FullControl, AccessControlType.Allow));
        if (testOwner != null) { mutexSecurity.SetOwner(testOwner); mutexSecurity.AddAccessRule(new MutexAccessRule(testOwner, MutexRights.FullControl, AccessControlType.Allow)); }
        bool created; using (var mutex = new Mutex(false, mutexName, out created, mutexSecurity)) {
            if (testOwner == null && !Trusted((SecurityIdentifier)mutex.GetAccessControl().GetOwner(typeof(SecurityIdentifier)))) throw new RpcFailure("serviceAccessDenied");
            bool acquired = false;
            try {
                try { acquired = mutex.WaitOne(5000); } catch (AbandonedMutexException) { acquired = true; }
                if (!acquired) throw new RpcFailure("serviceUnavailable");
                using (var key = parent.CreateSubKey(Child, RegistryKeyPermissionCheck.ReadWriteSubTree, RegistryOptions.Volatile, RegistrySecurityFor(testOwner))) {
                    if (testOwner == null) AssertTrusted(key.GetAccessControl());
                    var value = key.GetValue("Epoch", null, RegistryValueOptions.DoNotExpandEnvironmentNames);
                    if (value != null) {
                        if (!(value is string) || key.GetValueKind("Epoch") != RegistryValueKind.String || !IsValid((string)value)) throw new RpcFailure("recoveryRequired");
                        return (string)value;
                    }
                    var epoch = Guid.NewGuid().ToString("N"); key.SetValue("Epoch", epoch, RegistryValueKind.String); return epoch;
                }
            } finally { if (acquired) mutex.ReleaseMutex(); }
        }
    }
    private static RegistrySecurity RegistrySecurityFor(SecurityIdentifier testOwner) {
        var security = new RegistrySecurity(); security.SetAccessRuleProtection(true, false); security.SetOwner(testOwner ?? AdminSid);
        foreach (var identity in new[] { SystemSid, AdminSid }) security.AddAccessRule(new RegistryAccessRule(identity, RegistryRights.FullControl,
            InheritanceFlags.ContainerInherit, PropagationFlags.None, AccessControlType.Allow));
        if (testOwner != null) security.AddAccessRule(new RegistryAccessRule(testOwner, RegistryRights.FullControl,
            InheritanceFlags.ContainerInherit, PropagationFlags.None, AccessControlType.Allow));
        return security;
    }
    private static bool Trusted(SecurityIdentifier sid) { return sid.Equals(SystemSid) || sid.Equals(AdminSid); }
    private static void AssertTrusted(RegistrySecurity security) {
        if (!Trusted((SecurityIdentifier)security.GetOwner(typeof(SecurityIdentifier)))) throw new RpcFailure("serviceAccessDenied");
        foreach (RegistryAccessRule rule in security.GetAccessRules(true, true, typeof(SecurityIdentifier))) {
            if (rule.AccessControlType == AccessControlType.Allow && (rule.PropagationFlags & PropagationFlags.InheritOnly) == 0 &&
                !Trusted((SecurityIdentifier)rule.IdentityReference)) throw new RpcFailure("serviceAccessDenied");
        }
    }
#if HONEY_SERVICE_TEST
    internal static string TestReadInParent(RegistryKey parent, string mutexName, SecurityIdentifier owner) { return ReadInParent(parent, mutexName, owner); }
#endif
}
