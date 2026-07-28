<#
.SYNOPSIS
    Builds the TLC image and model-checks every TLA+ spec in this repo.

.DESCRIPTION
    Wraps the two docker commands documented in tla/Dockerfile so the whole
    suite runs with one invocation on Windows. Exits with the container's exit
    code, so it can be used directly as a CI or pre-commit gate.

.PARAMETER Tag
    Image tag to build and run. Defaults to 'lightepoch-tla'.

.PARAMETER NoBuild
    Skip the image build and run the existing image as-is.

.PARAMETER NoCache
    Force a full rebuild, ignoring the Docker layer cache.

.EXAMPLE
    .\run-tests-in-docker.ps1

.EXAMPLE
    .\run-tests-in-docker.ps1 -NoBuild
#>
[CmdletBinding()]
param(
    [string] $Tag = 'lightepoch-tla',
    [switch] $NoBuild,
    [switch] $NoCache
)

$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
$dockerfile = Join-Path $here 'Dockerfile'

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Error "docker was not found on PATH. Install Docker Desktop, or run tla/run.sh directly with TLA_TOOLS pointing at tla2tools.jar."
}

docker info *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Error "The Docker daemon is not reachable. Start Docker Desktop and try again."
}

if (-not $NoBuild) {
    Write-Host "==> Building image '$Tag' from $dockerfile" -ForegroundColor Cyan
    $buildArgs = @('build', '-f', $dockerfile, '-t', $Tag)
    if ($NoCache) { $buildArgs += '--no-cache' }
    $buildArgs += $here

    & docker @buildArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Error "docker build failed with exit code $LASTEXITCODE."
    }
}

Write-Host "==> Model-checking all specs" -ForegroundColor Cyan
$started = Get-Date
& docker run --rm $Tag
$exitCode = $LASTEXITCODE
$elapsed = (Get-Date) - $started

Write-Host ""
if ($exitCode -eq 0) {
    Write-Host "==> All specs matched expectations in $([int]$elapsed.TotalSeconds)s." -ForegroundColor Green
} else {
    Write-Host "==> Spec results did not match expectations (exit code $exitCode) after $([int]$elapsed.TotalSeconds)s." -ForegroundColor Red
}

exit $exitCode
