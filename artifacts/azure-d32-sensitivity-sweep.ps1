$env:DOTNET_ROOT='C:\dotnet'
$env:PATH="C:\dotnet;$env:PATH"
$exe='C:\le\src\LightEpoch.Repro\bin\Release\net10.0\LightEpoch.Repro.exe'
$configs=@(
'--impl baseline --pattern bare --quarantine --rounds 5000000 --deref 20000 --pairs 1 --reader-core 2 --reclaimer-core 0 --disturber-cores 4,6,8,10,12,14,16,18 --reclaimer-delay 0',
'--impl baseline --pattern resume-and-refresh --quarantine --rounds 5000000 --deref 20000 --pairs 1 --reader-core 2 --reclaimer-core 0 --disturber-cores 4,6,8,10,12,14,16,18 --reclaimer-delay 0',
'--impl baseline --pattern bare --quarantine --rounds 5000000 --deref 20000 --pairs 1 --reader-core 2 --reclaimer-core 0 --disturber-cores 4,6,8,10,12,14,16,18 --reclaimer-delay 50 --jitter',
'--impl baseline --pattern resume-and-refresh --quarantine --rounds 5000000 --deref 20000 --pairs 1 --reader-core 2 --reclaimer-core 0 --disturber-cores 4,6,8,10,12,14,16,18 --reclaimer-delay 50 --jitter'
)
# $p.Handle must be read before WaitForExit: on Windows PowerShell 5.1 a process
# from Start-Process -PassThru does not cache its handle, so ExitCode yields $null.
foreach($a in $configs){ Write-Host "=== $a"; $sw=[Diagnostics.Stopwatch]::StartNew(); $p=Start-Process -FilePath $exe -ArgumentList $a -NoNewWindow -PassThru; $null=$p.Handle; $p.WaitForExit(); $sw.Stop(); Write-Host "EXIT:$($p.ExitCode) WALL:$([math]::Round($sw.Elapsed.TotalSeconds,2))" }
