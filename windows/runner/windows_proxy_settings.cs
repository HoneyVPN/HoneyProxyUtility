using System;
using System.Runtime.InteropServices;

// WinINet's LAN connection API includes PAC/WPAD and bypass settings. Editing
// ProxyEnable alone leaves automatic settings able to take precedence.
public sealed class HoneyProxySettings {
    public uint Flags;
    public string Server;
    public string Bypass;
    public string AutoConfigUrl;
}

public static class HoneyProxyWinInet {
    [StructLayout(LayoutKind.Explicit)]
    private struct OptionValue {
        [FieldOffset(0)] public uint Number;
        [FieldOffset(0)] public IntPtr Text;
        [FieldOffset(0)] public long Time;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct Option {
        public uint Name;
        public OptionValue Value;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct OptionList {
        public uint Size;
        public IntPtr Connection;
        public uint Count;
        public uint Error;
        public IntPtr Options;
    }
    [DllImport("wininet.dll", EntryPoint="InternetQueryOptionW", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool Query(IntPtr handle, uint option, ref OptionList list, ref uint length);
    [DllImport("wininet.dll", EntryPoint="InternetSetOptionW", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool Set(IntPtr handle, uint option, ref OptionList list, uint length);
    [DllImport("wininet.dll", EntryPoint="InternetSetOptionW", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool InternetSetOption(IntPtr handle, uint option, IntPtr buffer, uint length);
    [DllImport("kernel32.dll")]
    private static extern IntPtr GlobalFree(IntPtr memory);

    public static void VerifyLayout() {
        // The distributed Windows core/application is x64. Fail closed if the
        // managed marshaler does not match the real Windows SDK structures.
        if (IntPtr.Size != 8 || Marshal.SizeOf(typeof(Option)) != 16 ||
            Marshal.SizeOf(typeof(OptionList)) != 32 ||
            Marshal.OffsetOf(typeof(Option), "Value").ToInt32() != 8 ||
            Marshal.OffsetOf(typeof(OptionList), "Options").ToInt32() != 24) {
            throw new InvalidOperationException("proxy-abi-mismatch");
        }
    }

    public static HoneyProxySettings Read() {
        VerifyLayout();
        int stride = Marshal.SizeOf(typeof(Option));
        IntPtr options = Marshal.AllocHGlobal(stride * 4);
        for (int i = 0; i < stride * 4; i++) Marshal.WriteByte(options, i, 0);
        try {
            // FLAGS_UI is Microsoft's Windows 7+ query contract. Restore/set
            // with FLAGS (1), independently of the query option number.
            uint[] names = new uint[] { 10, 2, 3, 4 };
            for (int i = 0; i < 4; i++) {
                Option option = new Option();
                option.Name = names[i];
                Marshal.StructureToPtr(option, IntPtr.Add(options, i * stride), false);
            }
            OptionList list = new OptionList();
            list.Size = (uint)Marshal.SizeOf(typeof(OptionList));
            list.Count = 4;
            list.Options = options;
            uint length = list.Size;
            if (!Query(IntPtr.Zero, 75, ref list, ref length)) {
                throw new InvalidOperationException("proxy-query-failed");
            }
            Option flags = (Option)Marshal.PtrToStructure(options, typeof(Option));
            HoneyProxySettings result = new HoneyProxySettings();
            result.Flags = flags.Value.Number;
            string[] values = new string[3];
            for (int i = 1; i < 4; i++) {
                Option option = (Option)Marshal.PtrToStructure(IntPtr.Add(options, i * stride), typeof(Option));
                values[i - 1] = option.Value.Text == IntPtr.Zero ? "" : Marshal.PtrToStringUni(option.Value.Text);
            }
            result.Server = values[0];
            result.Bypass = values[1];
            result.AutoConfigUrl = values[2];
            return result;
        } finally {
            // Query allocates returned strings with the system global allocator.
            for (int i = 1; i < 4; i++) {
                Option option = (Option)Marshal.PtrToStructure(IntPtr.Add(options, i * stride), typeof(Option));
                if (option.Value.Text != IntPtr.Zero) GlobalFree(option.Value.Text);
            }
            Marshal.FreeHGlobal(options);
        }
    }

    public static void Write(uint flags, string server, string bypass, string autoConfigUrl) {
        VerifyLayout();
        int stride = Marshal.SizeOf(typeof(Option));
        IntPtr options = Marshal.AllocHGlobal(stride * 4);
        IntPtr[] strings = new IntPtr[3];
        try {
            string[] values = new string[] { server ?? "", bypass ?? "", autoConfigUrl ?? "" };
            Option flag = new Option();
            flag.Name = 1;
            flag.Value.Number = flags;
            Marshal.StructureToPtr(flag, options, false);
            for (int i = 1; i < 4; i++) {
                strings[i - 1] = Marshal.StringToHGlobalUni(values[i - 1]);
                Option option = new Option();
                option.Name = (uint)(i + 1);
                option.Value.Text = strings[i - 1];
                Marshal.StructureToPtr(option, IntPtr.Add(options, i * stride), false);
            }
            OptionList list = new OptionList();
            list.Size = (uint)Marshal.SizeOf(typeof(OptionList));
            list.Count = 4;
            list.Options = options;
            if (!Set(IntPtr.Zero, 75, ref list, list.Size)) {
                throw new InvalidOperationException("proxy-set-failed");
            }
        } finally {
            foreach (IntPtr value in strings) {
                if (value != IntPtr.Zero) Marshal.FreeHGlobal(value);
            }
            Marshal.FreeHGlobal(options);
        }
    }
}


// A Proxy supervisor joins this job before launching its core. Children inherit
// membership and cannot break away. The only owning handle is non-inheritable
// and intentionally lives until the supervisor process exits: closing it early
// would terminate the supervisor before it can write its cleanup acknowledgement.
public static class HoneyProxyProcessJob {
    [StructLayout(LayoutKind.Sequential)]
    private struct BasicLimit {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct IoCounters {
        public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
        public ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct ExtendedLimit {
        public BasicLimit BasicLimitInformation;
        public IoCounters IoInfo;
        public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
    }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern IntPtr CreateJobObjectW(ref SecurityAttributes attributes, string name);
    [StructLayout(LayoutKind.Sequential)]
    private struct SecurityAttributes {
        public uint Length; public IntPtr Descriptor;
        [MarshalAs(UnmanagedType.Bool)] public bool Inherit;
    }
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ConvertStringSecurityDescriptorToSecurityDescriptorW(string value, uint revision, out IntPtr descriptor, out uint length);
    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr memory);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern IntPtr OpenJobObjectW(uint access, [MarshalAs(UnmanagedType.Bool)] bool inherit, string name);
    [DllImport("kernel32.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetInformationJobObject(IntPtr job, int informationClass, ref ExtendedLimit information, uint length);
    [DllImport("kernel32.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll")]
    private static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")]
    private static extern void SetLastError(uint error);
    [DllImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseHandle(IntPtr handle);
    private static IntPtr ownedJob = IntPtr.Zero;
    private static string ownedName;

    public static string NameFor(string nonce) {
        if (!System.Text.RegularExpressions.Regex.IsMatch(nonce ?? "", "\\A[a-f0-9]{64}\\z")) {
            throw new InvalidOperationException("invalid-request");
        }
        // Global covers reconnecting/logging into another desktop session.
        // Global job objects do not require SeCreateGlobalPrivilege; Windows
        // reserves that requirement for file mappings and symbolic links.
        // The session nonce is also a loopback API credential. Kernel object
        // names may be enumerable: publish only a domain-separated one-way hash.
        using (System.Security.Cryptography.SHA256 hash = System.Security.Cryptography.SHA256.Create()) {
            byte[] digest = hash.ComputeHash(System.Text.Encoding.ASCII.GetBytes("HoneyVpnProxyJobV1:" + nonce));
            return @"Global\HoneyVpnProxyJobV1_" + BitConverter.ToString(digest).Replace("-", "").ToLowerInvariant();
        }
    }
    public static string Initialize(string nonce) {
        string name = NameFor(nonce);
        if (ownedJob != IntPtr.Zero) {
            if (ownedName != name) throw new InvalidOperationException("proxy-job-failed");
            return name;
        }
        string sid;
        using (System.Security.Principal.WindowsIdentity identity = System.Security.Principal.WindowsIdentity.GetCurrent()) {
            sid = identity.User.Value;
        }
        IntPtr descriptor; uint descriptorLength;
        // No inherited/default token DACL and no unrelated user/group access.
        // The creator account and SYSTEM can query/manage this exact object.
        if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
                "O:" + sid + "D:P(A;;GA;;;SY)(A;;GA;;;" + sid + ")",
                1, out descriptor, out descriptorLength)) {
            throw new InvalidOperationException("proxy-job-failed");
        }
        IntPtr job; int error;
        try {
            SecurityAttributes security = new SecurityAttributes();
            security.Length = (uint)Marshal.SizeOf(typeof(SecurityAttributes));
            security.Descriptor = descriptor; security.Inherit = false;
            SetLastError(0);
            job = CreateJobObjectW(ref security, name);
            error = Marshal.GetLastWin32Error();
        } finally { LocalFree(descriptor); }
        if (job == IntPtr.Zero) throw new InvalidOperationException("proxy-job-failed");
        bool assigned = false;
        try {
            if (error == 183) throw new InvalidOperationException("proxy-job-failed");
            ExtendedLimit limit = new ExtendedLimit();
            limit.BasicLimitInformation.LimitFlags = 0x00002000; // KILL_ON_JOB_CLOSE; no BREAKAWAY flag.
            if (!SetInformationJobObject(job, 9, ref limit, (uint)Marshal.SizeOf(typeof(ExtendedLimit))) ||
                !AssignProcessToJobObject(job, GetCurrentProcess())) {
                throw new InvalidOperationException("proxy-job-failed");
            }
            assigned = true;
            ownedName = name;
            ownedJob = job;
            return name;
        } finally {
            // Once assigned, the kernel handle remains open for the lifetime of
            // this process even if later journal IO or core startup fails.
            if (!assigned) CloseHandle(job);
        }
    }
    public static bool IsGone(string nonce) {
        IntPtr job = OpenJobObjectW(0x0004, false, NameFor(nonce)); // QUERY only; never creates a job.
        if (job != IntPtr.Zero) {
            CloseHandle(job);
            return false;
        }
        // Only confirmed absence proves the original job has been destroyed.
        // Access denied/provider failures are not equivalent to no job.
        if (Marshal.GetLastWin32Error() == 2) return true;
        throw new InvalidOperationException("proxy-job-unconfirmed");
    }
}
