param(
    [string]$Exe = "Q:\src\lightepoch-tla\src\LightEpoch.Repro\bin\Release\net10.0\LightEpoch.Repro.exe",
    [string]$OutDir = "Q:\src\lightepoch-tla\artifacts\x86-local-acquire-fence-20260728",
    [int]$VariantRounds = 1000000,
    [int]$SensitivityRounds = 3000000,
    [int]$SharedRounds = 500000,
    [int]$Deref = 20000,
    [int]$SharedDeref = 5000,
    [int]$TimeoutSeconds = 75
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$csv = Join-Path $OutDir 'results.csv'
if (Test-Path $csv) { Remove-Item $csv -Force }
function Invoke-ReproRun {
    param([string]$Name,[string]$Impl,[string]$Pattern,[string]$ArgString,[string]$AcquireOrder = '',[string]$RefreshOrder = '',[int]$TimeoutSeconds = 75)
    $safe = ($Name -replace '[^A-Za-z0-9_.-]', '_')
    $stdout = Join-Path $OutDir "$safe.out.txt"; $stderr = Join-Path $OutDir "$safe.err.txt"
    $psi = [System.Diagnostics.ProcessStartInfo]::new(); $psi.FileName = $Exe; $psi.Arguments = $ArgString; $psi.WorkingDirectory = Split-Path $Exe -Parent; $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    if ($AcquireOrder) { $psi.EnvironmentVariables['LE_ACQUIRE_ORDER'] = $AcquireOrder } else { $psi.EnvironmentVariables.Remove('LE_ACQUIRE_ORDER') }
    if ($RefreshOrder) { $psi.EnvironmentVariables['LE_REFRESH_ORDER'] = $RefreshOrder } else { $psi.EnvironmentVariables.Remove('LE_REFRESH_ORDER') }
    $p = [System.Diagnostics.Process]::new(); $p.StartInfo = $psi; $sw = [System.Diagnostics.Stopwatch]::StartNew(); [void]$p.Start(); $outTask = $p.StandardOutput.ReadToEndAsync(); $errTask = $p.StandardError.ReadToEndAsync(); $finished = $p.WaitForExit($TimeoutSeconds * 1000); $killed = $false
    if (-not $finished) { $killed = $true; try { $p.Kill() } catch {}; [void]$p.WaitForExit(15000) }
    $sw.Stop(); $outText = $outTask.Result; $errText = $errTask.Result; Set-Content -Path $stdout -Value $outText -Encoding UTF8; Set-Content -Path $stderr -Value $errText -Encoding UTF8
    $exit = if ($killed) { $null } else { $p.ExitCode }; $status = if ($killed) { 'SURVIVED_TIMEOUT' } elseif ($exit -eq 0) { 'SURVIVED_EXIT0' } else { 'CRASHED_NONZERO' }; $combined = $outText + "`n" + $errText
    $slotReuse = if ($combined -match 'slot reuse: ([^\r\n]+)') { $Matches[1] } else { '' }; $sampled = if ($combined -match 'sampledRounds=([0-9,]+)') { $Matches[1] } else { '' }; $violations = if ($combined -match 'violations=([0-9,]+)') { $Matches[1] } else { '' }; $elapsedReported = if ($combined -match 'elapsed=([0-9.]+)s') { $Matches[1] } elseif ($combined -match 'in ([0-9.]+)s with NO') { $Matches[1] } else { '' }; $banner = if ($combined -match 'ordering knobs: ([^\r\n]+)') { $Matches[1] } else { '' }
    $obj = [pscustomobject]@{name=$Name; impl=$Impl; pattern=$Pattern; acquireOrder=$AcquireOrder; refreshOrder=$RefreshOrder; banner=$banner; status=$status; exitCode=$exit; wallSeconds=[math]::Round($sw.Elapsed.TotalSeconds,3); reportedSeconds=$elapsedReported; violations=$violations; sampledRounds=$sampled; slotReuse=$slotReuse; stdout=$stdout; stderr=$stderr}
    $obj | Export-Csv -Path $csv -NoTypeInformation -Append; $obj | Format-List | Out-String | Write-Host
}
foreach ($pattern in @('bare','resume-and-refresh')) { Invoke-ReproRun -Name "sensitivity-baseline-$pattern" -Impl baseline -Pattern $pattern -ArgString "--impl baseline --pattern $pattern --quarantine --rounds $SensitivityRounds --deref $Deref --pairs 1 --reader-core 2 --reclaimer-core 0 --disturber-cores 4,6,8,10 --reclaimer-delay 0" -TimeoutSeconds $TimeoutSeconds }
foreach ($pattern in @('bare','resume-and-refresh')) { foreach ($refresh in @('', 'acqload')) { $suffix = if($refresh){$refresh}else{'plain'}; Invoke-ReproRun -Name "quarantine-casannounce-acqfence-refresh-$suffix-$pattern" -Impl casannounce -Pattern $pattern -AcquireOrder fence -RefreshOrder $refresh -ArgString "--impl casannounce --pattern $pattern --quarantine --rounds $VariantRounds --deref $Deref --pairs 1 --reader-core 2 --reclaimer-core 0 --disturber-cores 4,6,8,10 --reclaimer-delay 0" -TimeoutSeconds $TimeoutSeconds } }
foreach ($pattern in @('bare','resume-and-refresh')) { foreach ($refresh in @('', 'acqload')) { $suffix = if($refresh){$refresh}else{'plain'}; Invoke-ReproRun -Name "shared-casannounce-acqfence-refresh-$suffix-$pattern" -Impl casannounce -Pattern $pattern -AcquireOrder fence -RefreshOrder $refresh -ArgString "--impl casannounce --pattern $pattern --rounds $SharedRounds --deref $SharedDeref --readers 8 --slot-space 2 --reclaimer-delay 0" -TimeoutSeconds $TimeoutSeconds } }
