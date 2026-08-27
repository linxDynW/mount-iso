# Stress test: N mount/verify/dismount cycles in ONE process (the
# P/Invoke wrapper compiles once). Each iteration requires W: free
# before mount and gone after dismount; reports pass/fail counts.
param(
    [int]$Iterations = 100,
    [string]$Iso = '',
    [string]$Letter = 'W',
    [string]$Content = 'mount-iso stress test'
)
$ErrorActionPreference = 'Stop'

if (-not $Iso) { $Iso = Join-Path $PSScriptRoot 'test.iso' }
. (Join-Path $PSScriptRoot '..\scripts\mount-iso-lib.ps1')

Write-Host "stress: $Iterations iterations, iso=$Iso, letter=$Letter"

$ok = 0
$fail = 0
$sw = [System.Diagnostics.Stopwatch]::StartNew()

for ($i = 1; $i -le $Iterations; $i++) {
    $iter = "iteration $i/$Iterations"
    try {
        # precondition: target letter must be free, else previous
        # iteration leaked and results would be meaningless
        if (Get-Volume -DriveLetter $Letter -ErrorAction SilentlyContinue) {
            throw "precondition failed: $Letter already mounted (leak from previous iteration?)"
        }

        Mount-IsoImage -ImagePath $Iso -Letter $Letter -VerifyPath "hello.txt"

        $c = Get-Content "$Letter`:\hello.txt" -Raw
        if ($c.Trim() -ne $Content) {
            throw "content mismatch: got '$c'"
        }

        Dismount-IsoImage -ImagePath $Iso -Letter $Letter

        $ok++
        Write-Host ("[$iter] OK ({0}s)" -f [math]::Round($sw.Elapsed.TotalSeconds, 1))
    } catch {
        $fail++
        Write-Host "::error::$iter FAILED: $_"
        # best-effort cleanup so the loop can continue; never let
        # cleanup failures abort the run
        try { Dismount-IsoImage -ImagePath $Iso -Letter $Letter } catch {
            try { Dismount-DiskImage -ImagePath $Iso -ErrorAction SilentlyContinue | Out-Null } catch {}
            try { mountvol ("$Letter`:") /D 2>$null | Out-Null } catch {}
        }
    }
}

$sw.Stop()
Write-Host "=== summary ==="
Write-Host "iterations: $Iterations"
Write-Host "success: $ok"
Write-Host "failed: $fail"
Write-Host ("total: {0}s ({1}s/iter avg)" -f [math]::Round($sw.Elapsed.TotalSeconds, 1), [math]::Round($sw.Elapsed.TotalSeconds / $Iterations, 2))

if ($fail -gt 0) { exit 1 }
exit 0
