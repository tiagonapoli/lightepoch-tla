$ErrorActionPreference='Stop'
$env:DOTNET_ROOT='C:\dotnet'
$env:PATH="C:\dotnet;$env:PATH"
$sentinel='C:\le\artifacts\x86-vm-20260728\DONE.txt'
if(Test-Path $sentinel){Remove-Item $sentinel -Force}
$cmd = "& 'C:\le\artifacts\run-x86-matrix.ps1' -Exe 'C:\le\src\LightEpoch.Repro\bin\Release\net10.0\LightEpoch.Repro.exe' -OutDir 'C:\le\artifacts\x86-vm-20260728' -TimeoutSeconds 75 -VariantRounds 1000000 -SensitivityRounds 3000000 -SharedRounds 500000; Set-Content -Path '$sentinel' -Value (Get-Date -Format o)"
Start-Process -FilePath powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-Command',$cmd) -WindowStyle Hidden -PassThru | Select-Object Id,ProcessName,StartTime | Format-List
