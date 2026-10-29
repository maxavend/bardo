# Gives the CI machine a large, high-DPI screen before the design review, so captures are
# sharp enough for portfolio slides. Picks the largest mode the display offers, up to the
# requested size, then sets Windows' scale. Prints what it got.
param(
    [int] $Width = 2880,
    [int] $Height = 1800,
    [int] $Scale = 200
)

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class BardoDisplay
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DEVMODE
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
    public static extern bool EnumDisplaySettings(string device, int mode, ref DEVMODE devMode);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int ChangeDisplaySettings(ref DEVMODE devMode, int flags);

    [DllImport("user32.dll")]
    public static extern bool SystemParametersInfo(uint action, int param, IntPtr vparam, uint winIni);

    [DllImport("user32.dll")]
    public static extern bool SystemParametersInfo(uint action, int param, ref int vparam, uint winIni);
}
"@

$modes = @()
$index = 0
while ($true) {
    $mode = New-Object BardoDisplay+DEVMODE
    $mode.dmSize = [System.Runtime.InteropServices.Marshal]::SizeOf($mode)
    if (-not [BardoDisplay]::EnumDisplaySettings($null, $index, [ref] $mode)) { break }
    $modes += $mode
    $index++
}
"Modes offered: " + (($modes | ForEach-Object { "$($_.dmPelsWidth)x$($_.dmPelsHeight)" } | Sort-Object -Unique) -join ", ")

$best = $modes |
    Where-Object { $_.dmPelsWidth -le $Width -and $_.dmPelsHeight -le $Height -and $_.dmBitsPerPel -ge 32 } |
    Sort-Object { $_.dmPelsWidth * $_.dmPelsHeight } -Descending |
    Select-Object -First 1
if ($best) {
    $result = [BardoDisplay]::ChangeDisplaySettings([ref] $best, 0)
    "Resolution set to $($best.dmPelsWidth)x$($best.dmPelsHeight): $result"
}

# Windows' scale is relative to the display's recommended one; step until it reads $Scale.
$scales = 100, 125, 150, 175, 200, 225, 250, 300, 350, 400
$get = 0x009E; $set = 0x009F
$current = 0
[void][BardoDisplay]::SystemParametersInfo($get, 0, [ref] $current, 0)
$recommended = [Array]::IndexOf($scales, 100) - $current
$target = [Array]::IndexOf($scales, $Scale) - $recommended
[void][BardoDisplay]::SystemParametersInfo($set, $target, [IntPtr]::Zero, 1)
Start-Sleep -Seconds 2
"Scale requested: $Scale% (relative step $target)"
