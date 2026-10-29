# Gives the CI machine a large, high-DPI screen before the design review, so captures are
# sharp enough for portfolio slides. Picks the largest mode the display offers, up to the
# requested size, then the largest Windows scale up to the requested one. Prints what it got.
param(
    [int] $Width = 2880,
    [int] $Height = 1800,
    [int] $Scale = 200
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

    /// <summary>Raises Windows' scale step by step, keeping the largest it accepts up to the target.</summary>
    public static uint SetScale(int percent)
    {
        const uint get = 0x009E, set = 0x009F;
        var current = 0;
        SystemParametersInfo(get, 0, ref current, 0);
        for (var step = current + 1; step <= current + 8; step++)
        {
            SystemParametersInfo(set, step, IntPtr.Zero, 1);
            System.Threading.Thread.Sleep(300);
            if (GetDpiForSystem() * 100 / 96 >= percent) break;
        }
        return GetDpiForSystem() * 100 / 96;
    }
}
"@

"Modes offered: " + [BardoDisplay]::Modes()
"Resolution: " + [BardoDisplay]::SetLargest($Width, $Height)
Start-Sleep -Seconds 2
"Scale: " + [BardoDisplay]::SetScale($Scale) + "%"
