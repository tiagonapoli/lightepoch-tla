$ErrorActionPreference = 'Stop'
$dll = 'Q:\src\lightepoch-tla\src\LightEpoch.Micro\bin\Release\net10.0\LightEpoch.Micro.dll'
$out = 'Q:\src\lightepoch-tla\artifacts\bench\matrix.csv'

# Each condition varies exactly one spelling inside the cas-announce impl. Every process also
# measures the unmodified baseline in-process, so each row carries its own live control.
$conditions = @(
    @{ name = 'default';     rel = 'volatile'; drain = 'volatile' },
    @{ name = 'rel-plain';   rel = 'plain';    drain = 'volatile' },
    @{ name = 'rel-exch';    rel = 'exchange'; drain = 'volatile' },
    @{ name = 'drain-plain'; rel = 'volatile'; drain = 'plain'    }
)

'rep,condition,impl,ns_op' | Set-Content $out

foreach ($rep in 1..4) {
    foreach ($c in $conditions) {
        $env:LE_RELEASE_ORDER = $c.rel
        $env:LE_DRAIN_PUBLISH_ORDER = $c.drain

        $lines = & dotnet $dll --contended --threads 8 --seconds 5
        foreach ($line in $lines) {
            if ($line -match '^(baseline|full-barrier|cas-announce)\b.*?([\d.]+)\s*$') {
                "$rep,$($c.name),$($Matches[1]),$($Matches[2])" | Add-Content $out
            }
        }
        Write-Host "rep $rep  $($c.name) done"
    }
}

Write-Host '--- results ---'
Import-Csv $out | Group-Object condition, impl | ForEach-Object {
    $v = $_.Group.ns_op | ForEach-Object { [double]$_ } | Sort-Object
    [pscustomobject]@{
        condition = $_.Group[0].condition
        impl      = $_.Group[0].impl
        n         = $v.Count
        min       = $v[0]
        median    = $v[[int]($v.Count / 2)]
        max       = $v[-1]
    }
} | Sort-Object impl, condition | Format-Table -AutoSize
