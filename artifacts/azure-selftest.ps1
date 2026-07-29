$env:DOTNET_ROOT='C:\dotnet'
$env:PATH="C:\dotnet;$env:PATH"
$exe='C:\le\src\LightEpoch.Repro\bin\Release\net10.0\LightEpoch.Repro.exe'
& $exe --impl baseline --pattern bare --self-test --rounds 100000 --deref 1000 --pairs 1 --reader-core 2 --reclaimer-core 0
Write-Host EXIT:$LASTEXITCODE
