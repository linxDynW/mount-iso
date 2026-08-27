# Mounts an ISO image to a drive letter and/or folder mount point,
# failure-proof - or unmounts a previously mounted one.

param(
    [Parameter(Mandatory = $true)][string]$ImagePath,
    [ValidateSet('mount', 'unmount')]
    [string]$Action = 'mount',
    [string]$Letter = '',
    [string]$MountPoint = '',
    [string]$VerifyPath = ''
)
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/mount-iso-lib.ps1"

if ($Action -eq 'unmount') {
    Dismount-IsoImage -ImagePath $ImagePath -Letter $Letter -MountPoint $MountPoint
    $target = if ($MountPoint) { $MountPoint } elseif ($Letter) { "$Letter`:" } else { '(none)' }
    Write-Host "ISO unmounted from $target"
    # unmount has no meaningful action outputs; nothing to emit
    exit 0
}

Mount-IsoImage -ImagePath $ImagePath -Letter $Letter -MountPoint $MountPoint -VerifyPath $VerifyPath

$target = if ($MountPoint) { $MountPoint } elseif ($Letter) { "$Letter`:" } else { '(none)' }
Write-Host "ISO mounted at $target"
# only emit the action output when running as a GitHub Action step
# (bare process invocations - e.g. the concurrency stress test - have
# no GITHUB_OUTPUT and Out-File would fail on the empty path)
if ($env:GITHUB_OUTPUT) {
    if ($Letter) {
        "letter=$Letter" | Out-File $env:GITHUB_OUTPUT -Append
    }
    if ($MountPoint) {
        "mount-point=$MountPoint" | Out-File $env:GITHUB_OUTPUT -Append
    }
}
