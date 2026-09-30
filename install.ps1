# ==============================================================================
#  DNSZen - Universal Windows Entrypoint & One-Line Installer Wrapper
#  Supports: .\install.ps1 OR irm https://.../install.ps1 | iex
# ==============================================================================
[CmdletBinding()]
param(
    [Parameter(Position=0)]
    [string]$Command = "",

    [Parameter(Position=1)]
    [string]$Arg = ""
)

$localScript = "$PSScriptRoot\scripts\dnszen.ps1"
if (Test-Path $localScript) {
    & $localScript $Command $Arg
} else {
    $repoRaw = "https://raw.githubusercontent.com/mxskeen/dnszen/master/scripts/dnszen.ps1"
    $tempScript = "$env:TEMP\dnszen.ps1"
    Write-Host "[>] Fetching DNSZen installer from GitHub..." -ForegroundColor Cyan
    Invoke-WebRequest -Uri $repoRaw -OutFile $tempScript -UseBasicParsing
    & $tempScript $Command $Arg
}
