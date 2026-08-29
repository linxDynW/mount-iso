# mount-iso library: Mount-IsoImage / Dismount-IsoImage.
# Dot-source this file once per process; Add-Type compiles the P/Invoke
# wrapper a single time.

if (-not ('DosDevice' -as [type])) {
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
}

function Resolve-IsoVolumeUid {
    param([string]$DevicePath)
    $deviceName = ($DevicePath -split '\\')[-1]
    # The device path from Mount-DiskImage is optimistic: the device
    # may not be registered in the DOS namespace yet, and the volume
    # symlink appears asynchronously after it. Poll both - they can
    # lag by a variable amount under load.
    for ($i = 0; $i -lt 150; $i++) {
        Start-Sleep -Milliseconds 200
        $deviceTarget = [DosDevice]::Target($deviceName)
        if (-not $deviceTarget) { continue }
        foreach ($name in [DosDevice]::EnumAll()) {
            if ($name -notlike 'Volume{*') { continue }
            if ([DosDevice]::Target($name) -eq $deviceTarget) {
                return "\\?\$name\"
            }
        }
    }
    throw "no volume symlink maps to device $DevicePath (waited 30s)"
}

function Mount-IsoImage {
    param(
        [Parameter(Mandatory = $true)][string]$ImagePath,
        [string]$Letter = '',
        [string]$MountPoint = '',
        [string]$VerifyPath = ''
    )
    if (-not (Test-Path $ImagePath)) { throw "ISO not found: $ImagePath" }

    $useLetter = -not [string]::IsNullOrEmpty($Letter)
    $useFolder = -not [string]::IsNullOrEmpty($MountPoint)
    if (-not $useLetter -and -not $useFolder) {
        throw "no mount target: give letter and/or mount-point"
    }
    $verifyRoots = @()   # where the content must appear after mounting

    if ($useFolder) {
        # create the dir if missing; must be empty before mounting
        if (-not (Test-Path $MountPoint)) {
            New-Item -ItemType Directory -Path $MountPoint -Force | Out-Null
            Write-Host "created mount point dir: $MountPoint"
        }
        if (-not (Test-Path $MountPoint -PathType Container)) {
            throw "mount point is not a directory: $MountPoint"
        }
        if ((Get-ChildItem $MountPoint -Force -ErrorAction SilentlyContinue).Count -ne 0) {
            throw "mount point dir is not empty: $MountPoint"
        }
        $verifyRoots += $MountPoint
    }
    if ($useLetter) {
        if (Get-Volume -DriveLetter $Letter -ErrorAction SilentlyContinue) {
            throw "drive letter $Letter is already in use"
        }
        $verifyRoots += "$Letter`:"
    }

    $img = Mount-DiskImage -ImagePath $ImagePath -NoDriveLetter -PassThru
    if (-not $img -or -not $img.DevicePath) {
        throw "Mount-DiskImage returned no DevicePath for $ImagePath"
    }

    try {
        $uid = Resolve-IsoVolumeUid $img.DevicePath

        if ($useLetter) {
            mountvol ("$Letter`:") $uid 2>$null
            if ($LASTEXITCODE -ne 0) {
                throw "mountvol failed (exit $LASTEXITCODE) for letter $Letter"
            }
        }
        if ($useFolder) {
            mountvol $MountPoint $uid 2>$null
            if ($LASTEXITCODE -ne 0) {
                throw "mountvol failed (exit $LASTEXITCODE) for $MountPoint"
            }
        }

        if ($VerifyPath) {
            foreach ($root in $verifyRoots) {
                $check = Join-Path $root $VerifyPath
                if (-not (Test-Path $check)) {
                    throw "mount verification failed: $check not accessible"
                }
            }
        } else {
            if ($useLetter -and -not (Get-Volume -DriveLetter $Letter -ErrorAction SilentlyContinue)) {
                throw "mount verification failed: no volume at $Letter"
            }
            if ($useFolder -and (Get-ChildItem $MountPoint -Force -ErrorAction SilentlyContinue).Count -eq 0) {
                throw "mount verification failed: $MountPoint still empty"
            }
        }
    } catch {
        # Drop every mount point and the image
        if ($useLetter) { try { mountvol ("$Letter`:") /D 2>$null } catch {} }
        if ($useFolder) { try { mountvol $MountPoint /D 2>$null } catch {} }
        try { Dismount-DiskImage -ImagePath $ImagePath -ErrorAction SilentlyContinue | Out-Null } catch {}
        throw
    }
}

function Dismount-IsoImage {
    param(
        [Parameter(Mandatory = $true)][string]$ImagePath,
        [string]$Letter = '',
        [string]$MountPoint = ''
    )
    $useLetter = -not [string]::IsNullOrEmpty($Letter)
    $useFolder = -not [string]::IsNullOrEmpty($MountPoint)

    # remove every mount point, then detach the image; verify both
    # happened. Only touch what was requested (letter and/or folder).
    if ($useLetter -and (Get-Volume -DriveLetter $Letter -ErrorAction SilentlyContinue)) {
        mountvol ("$Letter`:") /D 2>$null
    }
    if ($useFolder -and (Test-Path $MountPoint)) {
        mountvol $MountPoint /D 2>$null
    }
    # Dismount-DiskImage emits a status object - swallow it.
    Dismount-DiskImage -ImagePath $ImagePath -ErrorAction SilentlyContinue | Out-Null
    Start-Sleep -Milliseconds 300
    if ($useLetter -and (Get-Volume -DriveLetter $Letter -ErrorAction SilentlyContinue)) {
        throw "dismount failed: $Letter still present"
    }
    if ($useFolder -and (Get-ChildItem $MountPoint -Force -ErrorAction SilentlyContinue).Count -ne 0) {
        throw "dismount failed: $MountPoint still has content"
    }
}
