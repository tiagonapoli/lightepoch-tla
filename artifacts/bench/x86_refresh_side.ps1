$ErrorActionPreference = 'Continue'
$dll = (Get-ChildItem "Q:\src\lightepoch-tla\src\LightEpoch.Repro\bin\Release" -Recurse -Filter LightEpoch.Repro.dll | Select-Object -First 1).FullName

# resume-and-refresh is the ONLY pattern that executes the E->E' refresh announce,
# so it is the only one in which LE_REFRESH_ORDER can possibly matter. Running this
# comparison under --pattern bare is vacuous: the knob selects between code paths
# that are never reached, and both arms are the same program.
$common = @('--quarantine','--pattern','resume-and-refresh','--pairs','1','--rounds','50000000',
            '--reclaimer-core','0','--reader-core','2','--disturber-cores','4,6,8,10,12,14')

$results = @()
foreach ($rep in 1..4) {
    foreach ($arm in @(
        @{ name='baseline';     impl='baseline';    refresh='plain'   },
        @{ name='cas+plain';    impl='casannounce'; refresh='plain'   },
        @{ name='cas+release';  impl='casannounce'; refresh='release' },
        @{ name='cas+acqload';  impl='casannounce'; refresh='acqload' }
    )) {
        $env:LE_REFRESH_ORDER = $arm.refresh
        $out = (& dotnet $dll @('--impl', $arm.impl) @common 2>&1 | Out-String)
        $v = 0; $s = 0
        if ($out -match 'violations=([\d,]+)')    { $v = [int64](($matches[1]) -replace ',','') }
        if ($out -match 'sampledRounds=([\d,]+)') { $s = [int64](($matches[1]) -replace ',','') }
        $knob = if ($out -match 'ordering knobs: (.+)') { $matches[1].Trim() } else { '??' }
        $results += [pscustomobject]@{ rep=$rep; arm=$arm.name; violations=$v; sampled=$s; knobs=$knob }
        Write-Host ("rep{0}  {1,-12} violations={2,-8} sampled={3,-12} [{4}]" -f $rep,$arm.name,$v,$s,$knob)
        Remove-Item Env:LE_REFRESH_ORDER -ErrorAction SilentlyContinue
    }
}
Write-Host "`n=== TOTALS (resume-and-refresh) ==="
$results | Group-Object arm | ForEach-Object {
    $tv = ($_.Group | Measure-Object violations -Sum).Sum
    $ts = ($_.Group | Measure-Object sampled -Sum).Sum
    $n  = ($_.Group | Where-Object { $_.violations -gt 0 }).Count
    Write-Host ("{0,-12} violations={1,-9} sampledRounds={2,-12} reps-with-violations={3}/4" -f $_.Name, $tv, $ts, $n)
}
$results | Export-Csv "Q:\src\lightepoch-tla\artifacts\bench\x86_refresh_side.csv" -NoTypeInformation
