$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path C:\dotnet | Out-Null
$install = 'C:\dotnet\dotnet-install.ps1'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -Uri https://dot.net/v1/dotnet-install.ps1 -OutFile $install
& powershell -ExecutionPolicy Bypass -File $install -Channel 10.0 -InstallDir C:\dotnet
$env:DOTNET_ROOT='C:\dotnet'
$env:PATH="C:\dotnet;$env:PATH"
dotnet --info
Get-CimInstance Win32_Processor | Select-Object -First 1 Name,NumberOfCores,NumberOfLogicalProcessors | Format-List
