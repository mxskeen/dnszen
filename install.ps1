# Entrypoint wrapper for DNSZen on Windows
[CmdletBinding()]
param(
    [Parameter(Position=0)]
    [string]$Command = "",

    [Parameter(Position=1)]
    [string]$Arg = ""
)

& "$PSScriptRoot\scripts\dnszen.ps1" $Command $Arg
