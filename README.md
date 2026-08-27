# mount-iso

[![CI](https://github.com/linxDynW/mount-iso/actions/workflows/stress.yml/badge.svg)](https://github.com/linxDynW/mount-iso/actions/workflows/stress.yml)
[![release](https://img.shields.io/github/v/release/linxDynW/mount-iso)](https://github.com/linxDynW/mount-iso/releases)
[![stars](https://img.shields.io/github/stars/linxDynW/mount-iso)](https://github.com/linxDynW/mount-iso)

Mount an ISO image to a specific drive letter and/or folder on Windows, failure-proof.

```yaml
- uses: linxDynW/mount-iso@v1
  with:
    image-path: ${{ github.workspace }}\disk.iso    # required
    letter: W                                       # drive letter
    verify-path: LaunchBuildEnv.cmd                 # optional content check
```

Mount to a folder only:

```yaml
- uses: linxDynW/mount-iso@v1
  with:
    image-path: ${{ github.workspace }}\disk.iso
    mount-point: C:\iso-mount                       # NTFS folder
    verify-path: LaunchBuildEnv.cmd
```

Mount to both at once (the same volume gets both mount points):

```yaml
- uses: linxDynW/mount-iso@v1
  with:
    image-path: ${{ github.workspace }}\disk.iso
    letter: W
    mount-point: C:\iso-mount
    verify-path: LaunchBuildEnv.cmd
```

Unmount a previously mounted ISO (unmounting something
that is not mounted succeeds silently):

```yaml
- uses: linxDynW/mount-iso@v1
  with:
    action: unmount
    image-path: ${{ github.workspace }}\disk.iso
    letter: W
    # and/or: mount-point: C:\iso-mount
```

## Why this exists

`Mount-DiskImage` has no `-DriveLetter` parameter, so mounting to a
specific letter needs two steps: mount, then re-point the volume via
`mountvol`. The hard part is identifying *which* volume the ISO
created:

- `Mount-DiskImage ... -PassThru | Get-Volume` pipeline binding is
  flaky (`Get-Volume` has no `-DiskImage` parameter, and the CIM
  binding intermittently yields nothing, which causes failure in a
  small possibility)
- taking a snapshot before and after mounting, and then find the new
  volume is a simple way, but may race with other volumes appering
  
This action identifies the volume through the symbolic link to device:

```
(symlink)               (device name in kernel)
\\.\CDROM1      ->      \Device\CdRom1
Volume{GUID}    ->      \Device\CdRom1
```

`$img.DevicePath` and every `Volume{GUID}` are symbolic links. The 
`$img.DevicePath` points at a target, and a volume which points to 
the same target is what we want.


## Failure-proofing

- **Atomic mount**: if `mountvol` or the content verification fails,
  the image is automatically dismounted before the error propagates. 
- **Precondition checks**: the target letter must be free or the mount
  folder must be empty before mounting; otherwise the action refuses.
- **Post checks**: after mounting, the volume (or the folder)
  must actually be reachable; after unmounting, the folder must be
  empty again.
- **Race-free identity**: matching on symbolic-link targets is immune
  to other volumes appearing concurrently (verified with 3 parallel
  mount processes, 150 mounts, 0 failures).

## Requirements

- Windows (runner or local)
- **Admin session** — `mountvol` requires it (GitHub runners are admin)
- PowerShell 7+ (pwsh)

## Inputs

| input | required | default | description |
|---|---|---|---|
| `action` | no | `mount` | `mount` or `unmount`. Unmount is idempotent |
| `image-path` | yes | | path to the ISO file |
| `letter` | no | | drive letter to mount to / unmount from. Give this and/or `mount-point` |
| `mount-point` | no | | optional NTFS folder to mount to / unmount from, in addition to the letter if given (e.g. `C:\iso-mount`). Created if missing; must be empty before mounting. While mounted the folder contains the ISO content; empty again after unmount |
| `verify-path` | no | | optional path (relative to the mount root) that must exist after mounting, e.g. `LaunchBuildEnv.cmd`. Empty = skip content check (volume presence is still verified). Ignored on unmount |

## Outputs

| output | description |
|---|---|
| `letter` | the drive letter the ISO was mounted to (only when `letter` was given) |
| `mount-point` | the folder the ISO was mounted to (only when `mount-point` is set) |

## Notes

- **Empty ISO**: mount an empty ISO with `mount-point` mode with no
  `verify-path` argument will fail (`mount-point` mode with no 
  `verify-path` checks "folder is non-empty" as the success signal).
  If you mount empty ISOs to a folder, pass a `verify-path` or use
  `letter` mode. (A ISO with zero files is rare, `oscdimg` and 
  friends always write at least the metadata.)
- You need to give `letter` and/or `mount-point`, only what you ask
  for will be mounted. Giving neither is an error.

## Development
- `scripts/mount-iso-lib.ps1` — implementation as a dot-sourced library
  (`Mount-IsoImage` / `Dismount-IsoImage`).
- `scripts/mount-iso.ps1` — thin CLI entry (what the action invokes)
- `scripts/resolve-volume.ps1` — standalone volume resolver (debug/reuse)
- `.github/workflows/stress.yml` — three soak jobs:
  - `stress`: serial 50/100 mount/unmount cycles (letter W)
  - `concurrent`: 3 independent processes mounting simultaneously
    (X/Y/Z, the equivalent of three parallel `uses` steps), 50/100
    cycles each, live progress in the CI log
  - `folder`: folder-mode 10/30 cycles with leak detection
  - runs on push + nightly

## License

MIT