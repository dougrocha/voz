using System;
using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Graphics;

namespace VozUi;

public sealed partial class MainWindow : Window
{
    const double MeterFloorDb = -60; // bottom of the meter
    const double FallDbPerSec = 24;  // same ballistics as the Odin meter

    readonly DispatcherTimer tick = new() { Interval = TimeSpan.FromMilliseconds(33) };
    CoreLink? link;
    int retryTicks;
    double shownDb = MeterFloorDb, outDb = MeterFloorDb;

    // The core's state as last shown. Params the window has no control for (EQ, timings, ...)
    // are sent back unchanged.
    LinkState state;
    uint stateSeq = 1; // odd: never a valid sequence, so the first read always applies
    bool applying;      // true while controls are being set from the core's state
    bool devicesShown;  // the device lists have been filled since connecting
    bool paramsDirty;   // a control changed; sent on the next tick, so a drag costs one send per frame

    public MainWindow()
    {
        InitializeComponent();
        SystemBackdrop = new MicaBackdrop();
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(TitleBar);

        double scale = GetDpiForWindow(WinRT.Interop.WindowNative.GetWindowHandle(this)) / 96.0;
        AppWindow.Resize(new SizeInt32((int)(780 * scale), (int)(680 * scale)));

        MeterTrack.SizeChanged += (_, _) => PlaceThresholds();
        tick.Tick += (_, _) => Step(tick.Interval.TotalSeconds);
        tick.Start();
        Closed += (_, _) =>
        {
            tick.Stop();
            if (paramsDirty) SendParams();
            link?.NotifyClosed();
            link?.Dispose();
        };
    }

    void Step(double dt)
    {
        if (link is { CoreAlive: false }) Disconnect();
        if (link is null && --retryTicks <= 0)
        {
            retryTicks = 30; // look for voz about once a second
            link = CoreLink.TryOpen(out string? error);
            StatusText.Text = link is not null ? "Connected to voz" : error ?? "voz isn't running";
            ControlsScroll.IsEnabled = link is not null;
        }

        if (link is not null)
        {
            if (paramsDirty) SendParams(); // before reading, so the state read back includes it
            if (link.StateSeq != stateSeq)
            {
                link.ReadState(out LinkState next, out stateSeq);
                bool devices = !devicesShown || !SameDevices(in state, in next);
                state = next;
                ApplyState(devices);
            }
        }

        var m = link?.ReadMeters() ?? new MeterSnapshot(0, 0, 0, 0, -1, false);

        // Instant attack, fixed fall.
        shownDb = Math.Max(ToDb(m.InPeak), shownDb - FallDbPerSec * dt);
        outDb = Math.Max(ToDb(m.OutPeak), outDb - FallDbPerSec * dt);

        double h = MeterTrack.ActualHeight;
        InBar.Height = Frac(shownDb) * h;
        OutBar.Height = Frac(outDb) * h;
        LevelText.Text = shownDb <= MeterFloorDb + 0.5 ? "-∞ dB" : $"{shownDb:0} dB";
        VoicePill.Opacity = m.Vad >= state.Params.GateVoiceThresh && m.Vad >= 0 ? 1.0 : 0.25;
        if (link is not null && m.NsSuspended) StatusText.Text = "Noise suppression paused: CPU overloaded";
    }

    void Disconnect()
    {
        link?.Dispose();
        link = null;
        stateSeq = 1;
        devicesShown = paramsDirty = false;
        retryTicks = 0;
        ControlsScroll.IsEnabled = false;
    }

    // ---------------------------------------------------------------------------
    // Core → window
    // ---------------------------------------------------------------------------

    void ApplyState(bool devices)
    {
        ref readonly LinkState s = ref state;
        applying = true;
        try
        {
            ref readonly Params p = ref s.Params;
            NsToggle.IsOn = p.NsOn != 0;
            NsStrength.Value = Math.Round(p.NsStrength * 100);
            GateToggle.IsOn = p.GateOn != 0;
            GateSlider.Value = p.GateThreshDb;
            GateVoice.IsChecked = p.GateVoice != 0;
            CompToggle.IsOn = p.CompOn != 0;
            CompSlider.Value = p.CompThreshDb;
            CompRatio.Value = p.CompRatio;
            OutputGain.Value = p.OutputGainDb;
            BypassButton.IsChecked = p.Bypass != 0;

            if (devices)
            {
                string defaultMic = s.CaptureDefault >= 0 ? $"Default ({s.Capture[s.CaptureDefault]})" : "Default";
                CaptureBox.ItemsSource = Names(defaultMic, in s.Capture, s.CaptureCount);
                PlaybackBox.ItemsSource = Names("VB-Cable (auto)", in s.Playback, s.PlaybackCount);
                devicesShown = true;
            }
            CaptureBox.SelectedIndex = s.CaptureSel + 1;
            PlaybackBox.SelectedIndex = s.PlaybackSel + 1;

            StatusText.Text = s.Status.ToString();
            StatusText.Foreground = (Brush)Application.Current.Resources[
                s.StatusKind == 2 ? "SystemFillColorCriticalBrush" : "TextFillColorSecondaryBrush"];
        }
        finally { applying = false; }
        PlaceThresholds();
    }

    static string[] Names(string first, in LinkNames names, uint count)
    {
        var items = new string[count + 1];
        items[0] = first;
        for (int i = 0; i < count; i++) items[i + 1] = names[i].ToString();
        return items;
    }

    // Compares the raw names, so a params-only change neither decodes them nor rebuilds the
    // lists (which would also close an open dropdown).
    static bool SameDevices(in LinkState a, in LinkState b) =>
        a.CaptureCount == b.CaptureCount && a.PlaybackCount == b.PlaybackCount && a.CaptureDefault == b.CaptureDefault &&
        Bytes(in a.Capture).SequenceEqual(Bytes(in b.Capture)) && Bytes(in a.Playback).SequenceEqual(Bytes(in b.Playback));

    static ReadOnlySpan<byte> Bytes(in LinkNames n) => MemoryMarshal.AsBytes(new ReadOnlySpan<LinkNames>(in n));

    // ---------------------------------------------------------------------------
    // Window → core
    // ---------------------------------------------------------------------------

    void Param_Changed(object sender, object e)
    {
        PlaceThresholds();
        if (!applying && link is not null) paramsDirty = true;
    }

    void SendParams()
    {
        paramsDirty = false;
        if (link is null) return;
        Params p = state.Params;
        p.NsOn = B(NsToggle.IsOn);
        p.NsStrength = (float)(NsStrength.Value / 100);
        p.GateOn = B(GateToggle.IsOn);
        p.GateThreshDb = (float)GateSlider.Value;
        p.GateVoice = B(GateVoice.IsChecked == true);
        p.CompOn = B(CompToggle.IsOn);
        p.CompThreshDb = (float)CompSlider.Value;
        p.CompRatio = (float)CompRatio.Value;
        p.OutputGainDb = (float)OutputGain.Value;
        p.Bypass = B(BypassButton.IsChecked == true);
        if (!link.SetParams(p)) StatusText.Text = "voz didn't respond";
    }

    void Capture_Changed(object sender, SelectionChangedEventArgs e) =>
        DeviceChanged(CaptureBox, name => link!.SetCapture(name));

    void Playback_Changed(object sender, SelectionChangedEventArgs e) =>
        DeviceChanged(PlaybackBox, name => link!.SetPlayback(name));

    void DeviceChanged(ComboBox box, Func<string, bool> send)
    {
        if (applying || link is null || box.SelectedIndex < 0) return;
        // Item 0 is "Default" / "auto": the core takes an empty name for that.
        string name = box.SelectedIndex == 0 ? "" : ((string[])box.ItemsSource)[box.SelectedIndex];
        if (!send(name)) StatusText.Text = "voz didn't respond";
    }

    // ---------------------------------------------------------------------------

    void PlaceThresholds()
    {
        if (GateSlider is null || CompSlider is null) return; // ValueChanged fires during InitializeComponent
        double h = MeterTrack.ActualHeight;
        GateLine.Margin = new Thickness(0, 0, 0, Frac(GateSlider.Value) * h);
        CompLine.Margin = new Thickness(0, 0, 0, Frac(CompSlider.Value) * h);
        GateLine.Opacity = GateToggle.IsOn ? 1 : 0.25;
        CompLine.Opacity = CompToggle.IsOn ? 1 : 0.25;
    }

    static byte B(bool b) => b ? (byte)1 : (byte)0;
    static double ToDb(float x) => x > 1e-6f ? 20 * Math.Log10(x) : MeterFloorDb;
    static double Frac(double db) => Math.Clamp((db - MeterFloorDb) / -MeterFloorDb, 0, 1);

    [LibraryImport("user32.dll")]
    private static partial uint GetDpiForWindow(nint hwnd);
}
