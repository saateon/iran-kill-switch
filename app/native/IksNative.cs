// Iran Kill Switch - native helper (compiled by the .NET Framework that ships with Windows).
//
//  WfpSession : Windows Filtering Platform. All IKS objects carry one provider key, so they can
//               always be found and removed, even if the app's state file is lost.
//  Routes     : IP Helper API (CreateIpForwardEntry2) for the "Iran direct" routes.
//
// Only plain P/Invoke; no third-party code. Struct layouts follow fwpmtypes.h / netioapi.h (x64 and x86).
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace IKS.Native
{
    public static class Ids
    {
        public const string Version = "__IKS_VERSION__";   // replaced with app\VERSION when compiled
        public static readonly Guid Provider = new Guid("5d3a2f6e-9b1c-4e7a-8f20-3c6b1a9d4e71");
        public static readonly Guid Sublayer = new Guid("5d3a2f6e-9b1c-4e7a-8f20-3c6b1a9d4e72");
        public static readonly Guid ConnectV4 = new Guid("c38d57d1-05a7-4c33-904f-7fbceee60e82");
        public static readonly Guid ConnectV6 = new Guid("4a72393b-319f-44bc-84c3-ba54dcb3b6b4");
        public static readonly Guid AcceptV4 = new Guid("e1cd9fe7-f4b5-4273-96c0-592e487b8650");
        public static readonly Guid AcceptV6 = new Guid("a3b42c97-9f04-4672-b87e-cee9c483257f");
        public static readonly Guid[] Layers = { ConnectV4, ConnectV6, AcceptV4, AcceptV6 };
        internal static readonly Guid CondAppId = new Guid("d78e1e87-8644-4ea5-9437-d809ecefc971");
        internal static readonly Guid CondRemoteAddr = new Guid("b235ae9a-1d64-49b8-a44c-5ff3d9095045");
        internal static readonly Guid CondLocalAddr = new Guid("d9ee00de-c1ef-4617-bfe3-ffd8f5a08957");
        internal static readonly Guid CondInterfaceType = new Guid("daf8cd14-e09e-4c93-a5ae-c5c13b73ffca");
        internal static readonly Guid CondFlags = new Guid("632ce23b-5167-435c-86d7-e903684aa80c");
    }

    // ---------------------------------------------------------------- conditions
    public sealed class Cond
    {
        internal Guid Field; internal uint Match; internal uint Type;
        internal uint U32; internal uint Lo; internal uint Hi; internal byte[] V6; internal byte V6Len; internal string AppPath;

        const uint EQUAL = 0, RANGE = 5, FLAGS_ALL_SET = 6;
        const uint T_UINT32 = 3, T_BLOB = 12, T_V6MASK = 0x101, T_RANGE = 0x102;

        public static Cond App(string exePath) { return new Cond { Field = Ids.CondAppId, Match = EQUAL, Type = T_BLOB, AppPath = exePath }; }
        public static Cond RemoteRange(uint lo, uint hi) { return new Cond { Field = Ids.CondRemoteAddr, Match = RANGE, Type = T_RANGE, Lo = lo, Hi = hi }; }
        public static Cond LocalRange(uint lo, uint hi) { return new Cond { Field = Ids.CondLocalAddr, Match = RANGE, Type = T_RANGE, Lo = lo, Hi = hi }; }
        public static Cond RemoteV6(byte[] addr16, byte prefixLength) { return new Cond { Field = Ids.CondRemoteAddr, Match = EQUAL, Type = T_V6MASK, V6 = addr16, V6Len = prefixLength }; }
        public static Cond InterfaceType(uint ifType) { return new Cond { Field = Ids.CondInterfaceType, Match = EQUAL, Type = T_UINT32, U32 = ifType }; }
        public static Cond Loopback() { return new Cond { Field = Ids.CondFlags, Match = FLAGS_ALL_SET, Type = T_UINT32, U32 = 0x1 }; }
    }

    // ---------------------------------------------------------------- WFP
    public sealed class WfpSession : IDisposable
    {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct DISPLAY { public string name; public string desc; }
        [StructLayout(LayoutKind.Sequential)] struct BLOB { public uint size; public IntPtr data; }
        [StructLayout(LayoutKind.Sequential)] struct SESSION { public Guid key; public DISPLAY disp; public uint flags; public uint txnWait; public uint pid; public IntPtr sid; public IntPtr user; public int kernel; }
        [StructLayout(LayoutKind.Sequential)] struct PROVIDER { public Guid key; public DISPLAY disp; public uint flags; public BLOB data; public IntPtr service; }
        [StructLayout(LayoutKind.Sequential)] struct SUBLAYER { public Guid key; public DISPLAY disp; public uint flags; public IntPtr provider; public BLOB data; public ushort weight; }
        [StructLayout(LayoutKind.Sequential)] struct VALUE { public uint type; public IntPtr value; }
        [StructLayout(LayoutKind.Sequential)] struct COND { public Guid field; public uint match; public VALUE value; }
        [StructLayout(LayoutKind.Sequential)] struct RANGE { public VALUE lo; public VALUE hi; }
        [StructLayout(LayoutKind.Sequential)] struct ACTION { public uint type; public Guid filterType; }
        [StructLayout(LayoutKind.Sequential)] struct FILTER
        {
            public Guid key; public DISPLAY disp; public uint flags; public IntPtr provider; public BLOB data;
            public Guid layer; public Guid sublayer; public VALUE weight; public uint ncond; public IntPtr conds;
            public ACTION action; public ulong ctx1; public ulong ctx2; public IntPtr reserved; public ulong id; public VALUE effWeight;
        }
        [StructLayout(LayoutKind.Sequential)] struct ENUMTPL
        {
            public IntPtr provider; public Guid layer; public uint enumType; public uint flags; public IntPtr ctxTpl;
            public uint ncond; public IntPtr conds; public uint actionMask; public IntPtr callout;
        }

        [DllImport("fwpuclnt.dll", CharSet = CharSet.Unicode)] static extern uint FwpmEngineOpen0(string server, uint authn, IntPtr ident, ref SESSION s, out IntPtr h);
        [DllImport("fwpuclnt.dll")] static extern uint FwpmEngineClose0(IntPtr h);
        [DllImport("fwpuclnt.dll")] static extern uint FwpmTransactionBegin0(IntPtr h, uint flags);
        [DllImport("fwpuclnt.dll")] static extern uint FwpmTransactionCommit0(IntPtr h);
        [DllImport("fwpuclnt.dll")] static extern uint FwpmTransactionAbort0(IntPtr h);
        [DllImport("fwpuclnt.dll")] static extern uint FwpmProviderAdd0(IntPtr h, ref PROVIDER p, IntPtr sd);
        [DllImport("fwpuclnt.dll")] static extern uint FwpmProviderDeleteByKey0(IntPtr h, ref Guid key);
        [DllImport("fwpuclnt.dll")] static extern uint FwpmSubLayerAdd0(IntPtr h, ref SUBLAYER s, IntPtr sd);
        [DllImport("fwpuclnt.dll")] static extern uint FwpmSubLayerDeleteByKey0(IntPtr h, ref Guid key);
        [DllImport("fwpuclnt.dll")] static extern uint FwpmFilterAdd0(IntPtr h, ref FILTER f, IntPtr sd, out ulong id);
        [DllImport("fwpuclnt.dll")] static extern uint FwpmFilterDeleteById0(IntPtr h, ulong id);
        [DllImport("fwpuclnt.dll")] static extern uint FwpmFilterCreateEnumHandle0(IntPtr h, ref ENUMTPL t, out IntPtr e);
        [DllImport("fwpuclnt.dll")] static extern uint FwpmFilterEnum0(IntPtr h, IntPtr e, uint n, out IntPtr entries, out uint got);
        [DllImport("fwpuclnt.dll")] static extern uint FwpmFilterDestroyEnumHandle0(IntPtr h, IntPtr e);
        [DllImport("fwpuclnt.dll")] static extern void FwpmFreeMemory0(ref IntPtr p);
        [DllImport("fwpuclnt.dll", CharSet = CharSet.Unicode)] static extern uint FwpmGetAppIdFromFileName0(string file, out IntPtr blob);

        const uint OK = 0, ALREADY_EXISTS = 0x80320009, NOT_FOUND_PROVIDER = 0x80320005, NOT_FOUND_SUBLAYER = 0x80320007, IN_USE = 0x8032000A;
        const uint ACTION_BLOCK = 0x1001, ACTION_PERMIT = 0x1002;

        IntPtr _h; readonly bool _dynamic; bool _txn;
        public bool Dynamic { get { return _dynamic; } }

        public WfpSession(bool dynamicSession)
        {
            _dynamic = dynamicSession;
            var s = new SESSION { key = Guid.NewGuid(), disp = new DISPLAY { name = "Iran Kill Switch" }, flags = dynamicSession ? 1u : 0u, txnWait = 30000 };
            Check(FwpmEngineOpen0(null, 10 /*RPC_C_AUTHN_WINNT*/, IntPtr.Zero, ref s, out _h), "open the filtering engine (run as Administrator)");
        }

        static void Check(uint r, string what) { if (r != OK) throw new InvalidOperationException(string.Format("WFP: could not {0} (0x{1:X8})", what, r)); }

        public void Begin() { Check(FwpmTransactionBegin0(_h, 0), "begin transaction"); _txn = true; }
        public void Commit() { Check(FwpmTransactionCommit0(_h), "commit transaction"); _txn = false; }
        public void Abort() { if (_txn) { FwpmTransactionAbort0(_h); _txn = false; } }

        public void EnsureProviderAndSublayer()
        {
            uint persistent = _dynamic ? 0u : 1u;
            var p = new PROVIDER { key = Ids.Provider, disp = new DISPLAY { name = "Iran Kill Switch", desc = "Selective kill switch (IKS)" }, flags = persistent };
            uint r = FwpmProviderAdd0(_h, ref p, IntPtr.Zero);
            if (r != OK && r != ALREADY_EXISTS) Check(r, "add provider");
            IntPtr pk = AllocGuid(Ids.Provider);
            try
            {
                var sl = new SUBLAYER { key = Ids.Sublayer, disp = new DISPLAY { name = "Iran Kill Switch", desc = "IKS filters" }, flags = persistent, provider = pk, weight = 0xFFFE };
                r = FwpmSubLayerAdd0(_h, ref sl, IntPtr.Zero);
                if (r != OK && r != ALREADY_EXISTS) Check(r, "add sublayer");
            }
            finally { Marshal.FreeHGlobal(pk); }
        }

        static IntPtr AllocGuid(Guid g) { IntPtr p = Marshal.AllocHGlobal(16); Marshal.Copy(g.ToByteArray(), 0, p, 16); return p; }

        public ulong AddFilter(string name, Guid layer, bool permit, byte weight, Cond[] conds)
        {
            var frees = new List<IntPtr>(); var wfpFrees = new List<IntPtr>();
            try
            {
                int csz = Marshal.SizeOf(typeof(COND));
                IntPtr arr = IntPtr.Zero;
                if (conds != null && conds.Length > 0)
                {
                    arr = Marshal.AllocHGlobal(csz * conds.Length); frees.Add(arr);
                    for (int i = 0; i < conds.Length; i++)
                    {
                        Cond c = conds[i];
                        var wc = new COND { field = c.Field, match = c.Match, value = new VALUE { type = c.Type } };
                        if (c.Type == 3) wc.value.value = (IntPtr)(long)c.U32;
                        else if (c.Type == 12)
                        {
                            IntPtr blob; uint r = FwpmGetAppIdFromFileName0(c.AppPath, out blob);
                            Check(r, "read app id of " + c.AppPath); wfpFrees.Add(blob); wc.value.value = blob;
                        }
                        else if (c.Type == 0x102)
                        {
                            var rg = new RANGE { lo = new VALUE { type = 3, value = (IntPtr)(long)c.Lo }, hi = new VALUE { type = 3, value = (IntPtr)(long)c.Hi } };
                            IntPtr pr = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(RANGE))); frees.Add(pr);
                            Marshal.StructureToPtr(rg, pr, false); wc.value.value = pr;
                        }
                        else if (c.Type == 0x101)
                        {
                            IntPtr pm = Marshal.AllocHGlobal(17); frees.Add(pm);
                            Marshal.Copy(c.V6, 0, pm, 16); Marshal.WriteByte(pm, 16, c.V6Len); wc.value.value = pm;
                        }
                        Marshal.StructureToPtr(wc, arr + i * csz, false);
                    }
                }
                IntPtr pk = AllocGuid(Ids.Provider); frees.Add(pk);
                var f = new FILTER
                {
                    key = Guid.NewGuid(), disp = new DISPLAY { name = name, desc = "Iran Kill Switch" },
                    flags = _dynamic ? 0u : 1u /*PERSISTENT*/, provider = pk, layer = layer, sublayer = Ids.Sublayer,
                    weight = new VALUE { type = 1 /*UINT8*/, value = (IntPtr)weight },
                    ncond = (uint)(conds == null ? 0 : conds.Length), conds = arr,
                    action = new ACTION { type = permit ? ACTION_PERMIT : ACTION_BLOCK }
                };
                ulong id;
                Check(FwpmFilterAdd0(_h, ref f, IntPtr.Zero, out id), "add filter '" + name + "'");
                return id;
            }
            finally
            {
                foreach (IntPtr p in frees) Marshal.FreeHGlobal(p);
                for (int i = 0; i < wfpFrees.Count; i++) { IntPtr p = wfpFrees[i]; FwpmFreeMemory0(ref p); }
            }
        }

        // Every filter carrying the IKS provider key, in all four layers.
        public List<ulong> ListOurFilters()
        {
            var ids = new List<ulong>();
            IntPtr pk = AllocGuid(Ids.Provider);
            try
            {
                foreach (Guid layer in Ids.Layers)
                {
                    var t = new ENUMTPL { provider = pk, layer = layer, enumType = 1 /*OVERLAPPING: no conditions = all*/, actionMask = 0xFFFFFFFF };
                    IntPtr e;
                    if (FwpmFilterCreateEnumHandle0(_h, ref t, out e) != OK) continue;
                    try
                    {
                        while (true)
                        {
                            IntPtr entries; uint got;
                            if (FwpmFilterEnum0(_h, e, 256, out entries, out got) != OK || got == 0) { if (entries != IntPtr.Zero) FwpmFreeMemory0(ref entries); break; }
                            for (int i = 0; i < got; i++)
                            {
                                var f = (FILTER)Marshal.PtrToStructure(Marshal.ReadIntPtr(entries, i * IntPtr.Size), typeof(FILTER));
                                if (f.provider != IntPtr.Zero && ((Guid)Marshal.PtrToStructure(f.provider, typeof(Guid))) == Ids.Provider) ids.Add(f.id);
                            }
                            FwpmFreeMemory0(ref entries);
                            if (got < 256) break;
                        }
                    }
                    finally { FwpmFilterDestroyEnumHandle0(_h, e); }
                }
            }
            finally { Marshal.FreeHGlobal(pk); }
            return ids;
        }

        public int DeleteOurFilters()
        {
            int n = 0;
            foreach (ulong id in ListOurFilters()) { if (FwpmFilterDeleteById0(_h, id) == OK) n++; }
            return n;
        }

        // Full removal: filters, then sublayer, then provider. Safe to call when nothing exists.
        public int RemoveAll()
        {
            int n = DeleteOurFilters();
            Guid s = Ids.Sublayer, p = Ids.Provider;
            uint r = FwpmSubLayerDeleteByKey0(_h, ref s);
            if (r != OK && r != NOT_FOUND_SUBLAYER) Check(r, "delete sublayer");
            r = FwpmProviderDeleteByKey0(_h, ref p);
            if (r != OK && r != NOT_FOUND_PROVIDER && r != IN_USE) Check(r, "delete provider");
            return n;
        }

        public void Dispose() { Abort(); if (_h != IntPtr.Zero) { FwpmEngineClose0(_h); _h = IntPtr.Zero; } }
    }

    // ---------------------------------------------------------------- routes
    public static class Routes
    {
        // MIB_IPFORWARD_ROW2 is 104 bytes on x64 and x86; offsets below are checked by Verify().
        const int RowSize = 104, OffIfIndex = 8, OffDstFamily = 12, OffDstAddr = 16, OffDstLen = 40,
                  OffHopFamily = 44, OffHopAddr = 48, OffMetric = 84, OffProtocol = 88;

        [DllImport("iphlpapi.dll")] static extern void InitializeIpForwardEntry(IntPtr row);
        [DllImport("iphlpapi.dll")] static extern int CreateIpForwardEntry2(IntPtr row);
        [DllImport("iphlpapi.dll")] static extern int DeleteIpForwardEntry2(IntPtr row);
        [DllImport("iphlpapi.dll")] static extern int GetIpForwardTable2(ushort family, out IntPtr table);
        [DllImport("iphlpapi.dll")] static extern void FreeMibTable(IntPtr table);

        static IntPtr Row(uint prefix, byte len, uint ifIndex, uint nextHop, uint metric)
        {
            IntPtr r = Marshal.AllocHGlobal(RowSize);
            for (int i = 0; i < RowSize; i++) Marshal.WriteByte(r, i, 0);
            InitializeIpForwardEntry(r);
            Marshal.WriteInt32(r, OffIfIndex, (int)ifIndex);
            Marshal.WriteInt16(r, OffDstFamily, 2);
            WriteIp(r, OffDstAddr, prefix);
            Marshal.WriteByte(r, OffDstLen, len);
            Marshal.WriteInt16(r, OffHopFamily, 2);
            WriteIp(r, OffHopAddr, nextHop);
            Marshal.WriteInt32(r, OffMetric, (int)metric);
            Marshal.WriteInt32(r, OffProtocol, 3 /*MIB_IPPROTO_NETMGMT*/);
            return r;
        }
        static void WriteIp(IntPtr p, int off, uint hostOrder)
        {
            Marshal.WriteByte(p, off, (byte)(hostOrder >> 24)); Marshal.WriteByte(p, off + 1, (byte)(hostOrder >> 16));
            Marshal.WriteByte(p, off + 2, (byte)(hostOrder >> 8)); Marshal.WriteByte(p, off + 3, (byte)hostOrder);
        }
        static uint ReadIp(IntPtr p, int off)
        {
            return ((uint)Marshal.ReadByte(p, off) << 24) | ((uint)Marshal.ReadByte(p, off + 1) << 16) | ((uint)Marshal.ReadByte(p, off + 2) << 8) | Marshal.ReadByte(p, off + 3);
        }

        // Returns 0 on success; 5010 (already exists) is treated as success by callers.
        public static int Add(uint prefix, byte len, uint ifIndex, uint nextHop, uint metric)
        {
            IntPtr r = Row(prefix, len, ifIndex, nextHop, metric);
            try { return CreateIpForwardEntry2(r); } finally { Marshal.FreeHGlobal(r); }
        }
        public static int Delete(uint prefix, byte len, uint ifIndex, uint nextHop)
        {
            IntPtr r = Row(prefix, len, ifIndex, nextHop, 0);
            try { return DeleteIpForwardEntry2(r); } finally { Marshal.FreeHGlobal(r); }
        }

        // Layout self-check: the IPv4 default route read through our offsets must look sane.
        // Returns "ifIndex nextHop" of the first 0.0.0.0/0 route, or "" if none.
        public static string DefaultRouteProbe()
        {
            IntPtr t;
            if (GetIpForwardTable2(2, out t) != 0) return "";
            try
            {
                int n = Marshal.ReadInt32(t);
                for (int i = 0; i < n; i++)
                {
                    IntPtr row = t + 8 + i * RowSize;
                    if (Marshal.ReadInt16(row, OffDstFamily) == 2 && Marshal.ReadByte(row, OffDstLen) == 0 && ReadIp(row, OffDstAddr) == 0)
                    {
                        uint hop = ReadIp(row, OffHopAddr);
                        return Marshal.ReadInt32(row, OffIfIndex) + " " + (hop >> 24) + "." + ((hop >> 16) & 255) + "." + ((hop >> 8) & 255) + "." + (hop & 255);
                    }
                }
                return "";
            }
            finally { FreeMibTable(t); }
        }
    }
}
