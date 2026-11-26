using System;
using System.IO.MemoryMappedFiles;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Unicode;
using System.Threading;

namespace VozUi;

// ---------------------------------------------------------------------------
// Mirrors of the core's structs (shared/link.odin, dsp/params.odin), field for field.
// tests/dsp_test.odin pins the Odin layout; CoreLink.TryOpen checks sizes against the header.
// Bools are bytes (Odin bool is 1 byte); padding follows the same C rules on both sides.
// ---------------------------------------------------------------------------

[StructLayout(LayoutKind.Sequential)]
public struct EqBand { public byte Kind; public float FreqHz, Q, GainDb; }

[InlineArray(4)]
public struct EqBands { EqBand band; }

[StructLayout(LayoutKind.Sequential)]
public struct Params
{
    public byte Bypass;
    public float InputGainDb;
    public byte HighpassOn;
    public float HighpassHz;
    public byte NsOn;
    public float NsStrength; // 0..1
    public byte GateOn;
    public byte GateVoice;
    public float GateVoiceThresh;
    public float GateThreshDb, GateFloorDb, GateAttackMs, GateHoldMs, GateReleaseMs;
    public EqBands Eq;
    public byte CompOn;
    public float CompThreshDb, CompRatio, CompAttackMs, CompReleaseMs, CompMakeupDb;
    public float OutputGainDb;
}

[InlineArray(256)]
public struct NameBytes { byte b; }

[StructLayout(LayoutKind.Sequential)]
public struct LinkName
{
    public uint Len;
    public NameBytes Text;

    public override readonly string ToString()
    {
        ReadOnlySpan<byte> bytes = Text;
        return Encoding.UTF8.GetString(bytes[..(int)Math.Min(Len, 256)]);
    }

    public static LinkName From(string s)
    {
        var n = new LinkName();
        // Straight into the inline buffer; stops at a character boundary if it doesn't fit.
        Utf8.FromUtf16(s, n.Text, out _, out int written);
        n.Len = (uint)written;
        return n;
    }
}

[InlineArray(32)]
public struct LinkNames { LinkName name; }

[StructLayout(LayoutKind.Sequential)]
public struct LinkState
{
    public Params Params;
    public uint CaptureCount, PlaybackCount;
    public int CaptureSel, PlaybackSel, CaptureDefault; // -1 = default / auto / none
    public uint StatusKind;                             // 0 ok, 1 warn, 2 error
    public LinkName Status;
    public LinkNames Capture;
    public LinkNames Playback;
}

// Live meters from voz.exe: a read-and-reset snapshot, same as the core's meters_load.
public readonly record struct MeterSnapshot(
    float InPeak, float OutPeak, float GateGain, float CompGrDb, float Vad, bool NsSuspended);

// The shared block the core creates (shared/link.odin). State comes from the core under a
// sequence lock; changes go back as WM_COPYDATA commands to the core's window, so the core
// stays the only writer of its params, devices and config file.
public sealed unsafe partial class CoreLink : IDisposable
{
    const string Name = @"Local\voz.link";
    const uint Magic = 0x6B6E_6C76, Version = 3;
    const uint MetersSize = 7 * sizeof(uint);

    // Header field offsets (u32 unless noted), as in shared.Link.
    const int OffMagic = 0, OffVersion = 4, OffSize = 8, OffMetersOffset = 12, OffMetersSize = 16, OffParamsSize = 20,
        OffStateOffset = 24, OffStateSize = 28, OffCoreHwnd = 32 /* u64 */, OffSeq = 40;

    enum Cmd : uint { SetParams = 1, SetCapture = 2, SetPlayback = 3, UiClosed = 4 }

    readonly MemoryMappedFile file;
    readonly MemoryMappedViewAccessor view;
    readonly byte* basePtr;
    readonly uint* meters;
    readonly LinkState* state;

    CoreLink(MemoryMappedFile file, MemoryMappedViewAccessor view, byte* basePtr)
    {
        this.file = file;
        this.view = view;
        this.basePtr = basePtr;
        meters = (uint*)(basePtr + *(uint*)(basePtr + OffMetersOffset));
        state = (LinkState*)(basePtr + *(uint*)(basePtr + OffStateOffset));
    }

    // Null when voz isn't running; `error` says why when it's running but incompatible.
    public static CoreLink? TryOpen(out string? error)
    {
        error = null;
        MemoryMappedFile file;
        try { file = MemoryMappedFile.OpenExisting(Name, MemoryMappedFileRights.ReadWrite); }
        catch (System.IO.FileNotFoundException) { return null; }

        var view = file.CreateViewAccessor(0, 0, MemoryMappedFileAccess.ReadWrite);
        byte* p = null;
        view.SafeMemoryMappedViewHandle.AcquirePointer(ref p);
        p += view.PointerOffset;

        uint U(int off) => *(uint*)(p + off);
        bool ok = Volatile.Read(ref *(uint*)(p + OffMagic)) == Magic && U(OffVersion) == Version &&
            U(OffMetersSize) == MetersSize && U(OffParamsSize) == sizeof(Params) && U(OffStateSize) == sizeof(LinkState) &&
            view.Capacity >= U(OffSize);
        if (!ok)
        {
            error = "voz and voz-ui are different versions";
            view.SafeMemoryMappedViewHandle.ReleasePointer();
            view.Dispose();
            file.Dispose();
            return null;
        }

        return new CoreLink(file, view, p);
    }

    nint CoreHwnd => (nint)Volatile.Read(ref *(ulong*)(basePtr + OffCoreHwnd));

    // The core's window exists until it quits; 0 only in the moment before it's created.
    public bool CoreAlive => CoreHwnd is var h && (h == 0 || IsWindow(h));

    // Sequence number of the core's state; changes whenever the core rewrites it.
    public uint StateSeq => Volatile.Read(ref *(uint*)(basePtr + OffSeq));

    // A consistent copy of the core's state (retries while the core is mid-write).
    public void ReadState(out LinkState dst, out uint seq)
    {
        uint* s = (uint*)(basePtr + OffSeq);
        for (var spin = new SpinWait(); ; spin.SpinOnce())
        {
            uint s1 = Volatile.Read(ref *s);
            if ((s1 & 1) != 0) continue;
            dst = *state;
            Interlocked.MemoryBarrier();
            if (Volatile.Read(ref *s) == s1) { seq = s1; return; }
        }
    }

    public MeterSnapshot ReadMeters()
    {
        // Field order of shared.Meters: in_peak, out_peak, gate_gain, comp_gr_db, vad, ns_suspended, xruns.
        static float F(uint bits) => BitConverter.UInt32BitsToSingle(bits);
        return new MeterSnapshot(
            InPeak: F(Interlocked.Exchange(ref meters[0], 0)),
            OutPeak: F(Interlocked.Exchange(ref meters[1], 0)),
            GateGain: F(Volatile.Read(ref meters[2])),
            CompGrDb: F(Volatile.Read(ref meters[3])),
            Vad: F(Volatile.Read(ref meters[4])),
            NsSuspended: Volatile.Read(ref meters[5]) != 0);
    }

    public bool SetParams(in Params p)
    {
        fixed (Params* ptr = &p) return Send(Cmd.SetParams, ptr, sizeof(Params));
    }

    // The window is closing; voz quits too when its close_quits setting is on.
    public void NotifyClosed() => Send(Cmd.UiClosed, null, 0);

    // Empty name = Windows default mic / VB-Cable (auto).
    public bool SetCapture(string name) => SendName(Cmd.SetCapture, name);
    public bool SetPlayback(string name) => SendName(Cmd.SetPlayback, name);

    bool SendName(Cmd cmd, string name)
    {
        var n = LinkName.From(name);
        return Send(cmd, &n, sizeof(LinkName));
    }

    // Synchronous: when this returns, the core has applied the command and rewritten its state.
    bool Send(Cmd cmd, void* data, int size)
    {
        nint hwnd = CoreHwnd;
        if (hwnd == 0) return false;
        var cds = new CopyDataStruct { dwData = (nuint)cmd, cbData = (uint)size, lpData = data };
        const uint WM_COPYDATA = 0x004A, SMTO_ABORTIFHUNG = 0x0002;
        return SendMessageTimeoutW(hwnd, WM_COPYDATA, 0, (nint)(&cds), SMTO_ABORTIFHUNG, 500, out nint result) != 0 && result != 0;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct CopyDataStruct { public nuint dwData; public uint cbData; public void* lpData; }

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool IsWindow(nint hwnd);

    [LibraryImport("user32.dll")]
    private static partial nint SendMessageTimeoutW(nint hwnd, uint msg, nint wParam, nint lParam, uint flags, uint timeoutMs, out nint result);

    public void Dispose()
    {
        view.SafeMemoryMappedViewHandle.ReleasePointer();
        view.Dispose();
        file.Dispose();
    }
}
