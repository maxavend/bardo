# Gives the CI machine a large, high-DPI screen before the design review, so captures are
# sharp enough for portfolio slides. Picks the largest mode the display offers, up to the
# requested size, then sets Windows' scale. Prints what it got.
param(
    [int] $Width = 1920,
    [int] $Height = 1080,
    [int] $Scale = 150
)

Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class BardoDisplay
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct DEVMODE
    {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
        public int dmFields, dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
        public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public short dmLogPixels;
        public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
        public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern bool EnumDisplaySettings(string device, int mode, ref DEVMODE devMode);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int ChangeDisplaySettings(ref DEVMODE devMode, int flags);

    [DllImport("user32.dll")]
    private static extern bool SystemParametersInfo(uint action, int param, ref int value, uint winIni);

    [DllImport("user32.dll")]
    private static extern bool SystemParametersInfo(uint action, int param, IntPtr value, uint winIni);

    [DllImport("user32.dll")]
    private static extern uint GetDpiForSystem();

    private static DEVMODE Empty()
    {
        var mode = new DEVMODE();
        mode.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
        return mode;
    }

    public static string Modes()
    {
        var found = new SortedSet<string>();
        for (var index = 0; ; index++)
        {
            var mode = Empty();
            if (!EnumDisplaySettings(null, index, ref mode)) break;
            found.Add(mode.dmPelsWidth + "x" + mode.dmPelsHeight);
        }
        return string.Join(", ", found);
    }

    public static string SetLargest(int width, int height)
    {
        DEVMODE best = Empty();
        var bestArea = 0;
        for (var index = 0; ; index++)
        {
            var mode = Empty();
            if (!EnumDisplaySettings(null, index, ref mode)) break;
            var area = mode.dmPelsWidth * mode.dmPelsHeight;
            if (mode.dmPelsWidth <= width && mode.dmPelsHeight <= height && mode.dmBitsPerPel >= 32 && area > bestArea)
            {
                best = mode;
                bestArea = area;
            }
        }
        if (bestArea == 0) return "no mode";
        var result = ChangeDisplaySettings(ref best, 0);
        return best.dmPelsWidth + "x" + best.dmPelsHeight + " (" + result + ")";
    }

    /// <summary>
    /// Sets Windows' scale. The setting counts steps from the scale Windows recommends for
    /// the display (100 % at 1920 x 1080); the system DPI only changes at sign-in, so the
    /// app reports the scale it really got.
    /// </summary>
    public static int SetScale(int percent, int recommended)
    {
        int[] scales = { 100, 125, 150, 175, 200, 225, 250, 300, 350, 400, 450, 500 };
        var step = Array.IndexOf(scales, percent) - Array.IndexOf(scales, recommended);
        SystemParametersInfo(0x009F, step, IntPtr.Zero, 1);
        return step;
    }
}
"@

"Modes offered: " + [BardoDisplay]::Modes()
"Resolution: " + [BardoDisplay]::SetLargest($Width, $Height)
Start-Sleep -Seconds 2
"Scale step: " + [BardoDisplay]::SetScale($Scale, 100)
