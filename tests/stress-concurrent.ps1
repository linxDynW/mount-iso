# Concurrency stress: three independent mount-iso invocations running
# simultaneously, each looping N mount/verify/dismount cycles on its own
# drive letter and ISO copy - the equivalent of three `uses` steps
# firing at once (YAML cannot express parallel uses in one job).
#
# Each worker is a bare stress.ps1 process (single-invocation semantics:
# mount -> verify -> dismount -> repeat). All workers start together and
# run without any sync barrier.
param(
    [int]$Iterations = 50,
    [string]$IsoPath = (Join-Path $PSScriptRoot 'test.iso'),
    [string[]]$Letters = @('X', 'Y', 'Z')
)
$ErrorActionPreference = 'Stop'

$stress = Join-Path $PSScriptRoot 'stress.ps1'

if (-not (Test-Path $IsoPath)) { throw "iso not found: $IsoPath" }

# distinct ISO copies: three concurrent mounts of one file is undefined
# behavior on Windows; real action invocations get distinct files anyway
$copies = @()
for ($i = 0; $i -lt $Letters.Count; $i++) {
    $copy = Join-Path $env:TEMP ("concurrent-iso-$i.iso")
    Copy-Item $IsoPath $copy -Force
    $copies += $copy
}

Write-Host "concurrency stress: $($Letters.Count) workers x $Iterations iterations ($($Letters -join ','))"

# spawn all workers simultaneously.
$workers = @()   # each: p, job, letter, log
for ($i = 0; $i -lt $Letters.Count; $i++) {
    $log = Join-Path $env:TEMP ("concurrent-worker-$i.log")
    Remove-Item $log -Force -ErrorAction SilentlyContinue

    $p = Start-Process -FilePath 'pwsh' -ArgumentList @(
        '-NoProfile', '-File', $stress,
        '-Iterations', $Iterations,
        '-Iso', $copies[$i],
        '-Letter', $Letters[$i]
    ) -PassThru -WindowStyle Hidden -RedirectStandardOutput $log

    # tail job: emits worker lines as they are written (live progress)
    $job = Start-Job -ScriptBlock {
        param($path)
        Get-Content -Path $path -Wait -ErrorAction SilentlyContinue
    } -ArgumentList $log

    $workers += @{ p = $p; job = $job; letter = $Letters[$i]; log = $log }
}

# main loop: forward worker output live (each line consumed once via
# Receive-Job without -Keep); exit when all processes done
$failed = $false
$deadline = (Get-Date).AddSeconds($Iterations * 20 + 120)
while ($true) {
    $allExited = $true
    foreach ($w in $workers) {
        if (-not $w.p.HasExited) { $allExited = $false }
        Receive-Job -Job $w.job 2>$null | ForEach-Object {
            Write-Host ("worker[$($w.letter)] $_")
        }
    }
    if ($allExited) { break }
    if ((Get-Date) -gt $deadline) {
        Write-Host "::error::timeout waiting for workers"
        $failed = $true
        break
    }
    Start-Sleep -Milliseconds 100
}

# final drain of anything still buffered, then cleanup
for ($i = 0; $i -lt $workers.Count; $i++) {
    $w = $workers[$i]
    Receive-Job -Job $w.job 2>$null | ForEach-Object {
        Write-Host ("worker[$($w.letter)] $_")
    }
    Stop-Job $w.job -ErrorAction SilentlyContinue
    Remove-Job $w.job -Force -ErrorAction SilentlyContinue
    Remove-Item $w.log -Force -ErrorAction SilentlyContinue

    if (-not $w.p.HasExited) {
        try { Stop-Process -Id $w.p.Id -Force -ErrorAction SilentlyContinue } catch {}
        $failed = $true
        continue
    }
    if ($w.p.ExitCode -ne 0) {
        Write-Host "::error::worker $($w.letter) exited $($w.p.ExitCode)"
        $failed = $true
    }
}

foreach ($copy in $copies) { Remove-Item $copy -Force -ErrorAction SilentlyContinue }

if ($failed) { exit 1 }
Write-Host "ALL WORKERS PASSED ($($Letters.Count) x $Iterations)"
exit 0
