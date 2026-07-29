$ErrorActionPreference = 'Continue'
$dll = (Get-ChildItem "Q:\src\lightepoch-tla\src\LightEpoch.Repro\bin\Release" -Recurse -Filter LightEpoch.Repro.dll | Select-Object -First 1).FullName

$common = @('--quarantine','--pattern','bare','--pairs','1','--rounds','50000000',
            '--reclaimer-core','0','--reader-core','2','--disturber-cores','4,6,8,10,12,14')

$results = @()
foreach ($rep in 1..3) {
    foreach ($arm in @(
        @{ name='baseline';     impl='baseline';    refresh='plain'   },
        @{ name='cas+plain';    impl='casannounce'; refresh='plain'   },
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
Write-Host "`n=== TOTALS ==="
$results | Group-Object arm | ForEach-Object {
    $tv = ($_.Group | Measure-Object violations -Sum).Sum
    $ts = ($_.Group | Measure-Object sampled -Sum).Sum
    Write-Host ("{0,-12} violations={1,-8} sampledRounds={2}" -f $_.Name, $tv, $ts)
}
$results | Export-Csv "Q:\src\lightepoch-tla\artifacts\bench\x86_side_dissociation.csv" -NoTypeInformation
