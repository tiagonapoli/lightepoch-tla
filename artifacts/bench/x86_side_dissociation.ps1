$ErrorActionPreference = 'Continue'
$dll = "Q:\src\lightepoch-tla\src\LightEpoch.Repro\bin\Release\net8.0\LightEpoch.Repro.dll"
if (-not (Test-Path $dll)) { $dll = (Get-ChildItem "Q:\src\lightepoch-tla\src\LightEpoch.Repro\bin\Release" -Recurse -Filter LightEpoch.Repro.dll | Select-Object -First 1).FullName }
Write-Host "dll: $dll"

$common = @('--quarantine','--pattern','bare','--pairs','1','--rounds','20000000',
            '--reclaimer-core','0','--reader-core','2','--disturber-cores','4,6,8,10,12,14')

function Run-Arm($name, $impl, $refresh, $extra) {
    $env:LE_REFRESH_ORDER = $refresh
    $args = @('--impl', $impl) + $common + $extra
    Write-Host "=== ARM: $name  (impl=$impl LE_REFRESH_ORDER=$refresh)"
    $out = & dotnet $dll @args 2>&1 | Out-String
    $banner = ($out -split "`n" | Where-Object { $_ -match 'ordering knobs' }) -join ''
    Write-Host $banner.Trim()
    ($out -split "`n" | Where-Object { $_ -match 'violation|VIOLATION|rounds=|self-test|sampled' }) | ForEach-Object { Write-Host "    $($_.Trim())" }
    Remove-Item Env:LE_REFRESH_ORDER -ErrorAction SilentlyContinue
    Write-Host ""
}

Run-Arm 'baseline (control)' 'baseline'    'plain'   @()
Run-Arm 'CAS + plain refresh' 'casannounce' 'plain'  @()
Run-Arm 'CAS + acqload (fix)' 'casannounce' 'acqload' @()
