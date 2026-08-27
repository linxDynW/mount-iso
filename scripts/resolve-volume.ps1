# Resolve the volume UniqueId by its mounted device path.
param(
    [Parameter(Mandatory = $true)][string]$DevicePath
)
$ErrorActionPreference = 'Stop'

Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class DosDevice {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern uint QueryDosDevice(string name, IntPtr target, uint max);

    public static string[] EnumAll() {
        uint size = 262144;
        IntPtr ptr = Marshal.AllocHGlobal((int)size);
        try {
            uint r = QueryDosDevice(null, ptr, size);
            if (r == 0) throw new Exception("QueryDosDevice failed: " + Marshal.GetLastWin32Error());
            return Marshal.PtrToStringUni(ptr, (int)r)
                .Split(new char[] { '\0' }, StringSplitOptions.RemoveEmptyEntries);
        } finally { Marshal.FreeHGlobal(ptr); }
    }

    public static string Target(string name) {
        IntPtr ptr = Marshal.AllocHGlobal(8192);
        try {
            uint r = QueryDosDevice(name, ptr, 8192);
            if (r == 0) return null;
            return Marshal.PtrToStringUni(ptr, (int)r).TrimEnd('\0');
        } finally { Marshal.FreeHGlobal(ptr); }
    }
}
'@

# Resolve the device's real target, then find the volume pointing at it.
$deviceTarget = [DosDevice]::Target(($DevicePath -split '\\')[-1])
if (-not $deviceTarget) { throw "no device target for $DevicePath" }
Write-Host "device: $DevicePath -> $deviceTarget"

foreach ($name in [DosDevice]::EnumAll()) {
    if ($name -notlike 'Volume{*') { continue }
    if ([DosDevice]::Target($name) -eq $deviceTarget) {
        Write-Host "matched: $name -> $deviceTarget"
        return "\\?\$name\"
    }
}
throw "no volume maps to $deviceTarget"
