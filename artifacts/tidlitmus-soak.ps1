<#
.SYNOPSIS
    Overnight x86 soak for the ThisInstanceProtected() torture harness.

.DESCRIPTION
    Alternates the forced-failure control with the fix under several slot-space and
    thread-count settings. The control is re-run every cycle rather than once at the
    start: a soak that reports "no violations" for ten hours is only meaningful if the
    detector was still live at the end of those ten hours, and slot pressure, thermal
    state and scheduler behaviour all drift over a long run.

    Each arm writes a JSON report; the driver appends one CSV row per arm and drops a
    sentinel file when it finishes so a detached run can be polled from outside.

    A cycle is deliberately short relative to the soak so the control/fix interleaving
    is fine-grained; the fix accumulates far more exposure than the control because it
    runs more arms per cycle, which is the ratio the verdict rests on.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $Exe,
    [Parameter(Mandatory = $true)][string] $OutDir,
    [double] $Hours = 10,
    [int] $ControlSeconds = 180,
    [int] $ArmSeconds = 300
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$csv = Join-Path $OutDir 'tidlitmus-soak.csv'
if (-not (Test-Path $csv))
{
    Set-Content -Path $csv -Value 'utc,cycle,arm,mode,releaseOrder,threads,slots,seconds,rounds,falseNegatives,falsePositives,lostOwnership,violations,exitCode'
}

$cpus = [Environment]::ProcessorCount

# Slot spaces small enough that every slot is contended, paired with thread counts
# that both saturate and oversubscribe the machine. The handoff window only opens when
# a slot changes owner across cores, so a large table would idle the detector.
$arms = @(
    @{ Slots = 1; Threads = $cpus },
    @{ Slots = 2; Threads = $cpus },
    @{ Slots = 2; Threads = $cpus * 2 },
    @{ Slots = 4; Threads = $cpus * 2 },
    @{ Slots = 8; Threads = $cpus * 4 }
)

function Invoke-Arm([string] $ReleaseOrder, [int] $Slots, [int] $Threads, [int] $Seconds, [bool] $ExpectViolation, [bool] $Idiom, [int] $Cycle, [string] $Label)
{
    $mode = if ($Idiom) { 'idiom' } else { 'query' }
    $json = Join-Path $OutDir ("{0}-{1}-c{2:d3}-{3}-s{4}-t{5}.json" -f $Label, $mode, $Cycle, $ReleaseOrder, $Slots, $Threads)
    $env:LE_RELEASE_ORDER = $ReleaseOrder

    $argv = @('--impl', 'cas', '--seconds', $Seconds, '--slots', $Slots, '--threads', $Threads, '--json', $json)
    if ($ExpectViolation) { $argv += '--expect-violation' }
    if ($Idiom) { $argv += '--idiom' }

    & $Exe @argv | Out-Null
    $exit = $LASTEXITCODE

    $r = if (Test-Path $json) { Get-Content $json -Raw | ConvertFrom-Json } else { $null }
    $row = '{0},{1},{2},{3},{4},{5},{6},{7},{8},{9},{10},{11},{12},{13}' -f `
        (Get-Date -Format o), $Cycle, $Label, $mode, $ReleaseOrder, $Threads, $Slots, $Seconds, `
        $(if ($r) { $r.rounds } else { -1 }), `
        $(if ($r) { $r.falseNegatives } else { -1 }), `
        $(if ($r) { $r.falsePositives } else { -1 }), `
        $(if ($r) { $r.lostOwnership } else { -1 }), `
        $(if ($r) { $r.violations } else { -1 }), $exit
    Add-Content -Path $csv -Value $row
    Write-Host $row
}

$deadline = (Get-Date).AddHours($Hours)
$cycle = 0

while ((Get-Date) -lt $deadline)
{
    $cycle++

    # Prove the detector is live for this cycle before trusting this cycle's clean runs.
    # Both modes, because they fail at different rates and for slightly different reasons:
    # idiom reads the query immediately after Resume(), query mode samples across the region.
    Invoke-Arm -ReleaseOrder 'upstream' -Slots 2 -Threads ($cpus * 2) -Seconds $ControlSeconds -ExpectViolation $true -Idiom $true -Cycle $cycle -Label 'control'
    Invoke-Arm -ReleaseOrder 'upstream' -Slots 2 -Threads ($cpus * 2) -Seconds $ControlSeconds -ExpectViolation $true -Idiom $false -Cycle $cycle -Label 'control'

    foreach ($a in $arms)
    {
        if ((Get-Date) -ge $deadline) { break }

        Invoke-Arm -ReleaseOrder 'volatile' -Slots $a.Slots -Threads $a.Threads -Seconds $ArmSeconds -ExpectViolation $false -Idiom $true -Cycle $cycle -Label 'fix'
        Invoke-Arm -ReleaseOrder 'volatile' -Slots $a.Slots -Threads $a.Threads -Seconds $ArmSeconds -ExpectViolation $false -Idiom $false -Cycle $cycle -Label 'fix'
    }
}

Set-Content -Path (Join-Path $OutDir 'DONE.txt') -Value (Get-Date -Format o)
Write-Host "soak complete after $cycle cycles"
