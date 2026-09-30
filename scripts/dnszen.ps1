# ==============================================================================
#  DNSZen for Windows - Custom DNS-over-HTTPS (DoH) System-Wide
#  Brings Android-like "Private DNS" to Windows 10 & 11
# ==============================================================================

[CmdletBinding()]
param(
    [Parameter(Position=0)]
    [string]$Command = "",

    [Parameter(Position=1)]
    [string]$Arg = ""
)

$ErrorActionPreference = "Stop"

$Version = "1.0.0"
$DefaultDnsproxyVer = "v0.85.0"
$InstallDir = "$env:ProgramData\dnszen"
$BinDir = "$InstallDir\bin"
$ConfigFile = "$InstallDir\dnsproxy.yaml"
$StateFile = "$InstallDir\dnszen.json"
$BackupFile = "$InstallDir\backup_dns.clixml"
$DnsproxyExe = "$BinDir\dnsproxy.exe"
$TaskName = "DNSZen"

function Show-Banner {
    Write-Host "" -ForegroundColor Cyan
    Write-Host "  ===============================================================" -ForegroundColor Cyan
    Write-Host "             DNSZen for Windows - Custom DNS-over-HTTPS           " -ForegroundColor Cyan
    Write-Host "                  System-Wide * Persistent * Fast                " -ForegroundColor Cyan
    Write-Host "  ===============================================================" -ForegroundColor Cyan
    Write-Host ""
}

function Test-Admin {
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Elevate-Privileges {
    if (-not (Test-Admin)) {
        Write-Warning "Administrator rights required. Relaunching with elevation..."
        $scriptPath = $MyInvocation.MyCommand.Path
        $argsList = "-ExecutionPolicy Bypass -File `"$scriptPath`""
        if ($Command) { $argsList += " `"$Command`"" }
        if ($Arg) { $argsList += " `"$Arg`"" }

        Start-Process powershell.exe -Verb RunAs -ArgumentList $argsList
        Exit
    }
}

function Detect-Arch {
    $arch = $env:PROCESSOR_ARCHITECTURE
    switch ($arch) {
        "AMD64" { return "amd64" }
        "ARM64" { return "arm64" }
        "x86"   { return "386" }
        Default { return "amd64" }
    }
}

function Install-Dnsproxy {
    if (Test-Path $DnsproxyExe) {
        Write-Host "[OK] dnsproxy engine is already present." -ForegroundColor Green
        return
    }

    $arch = Detect-Arch
    Write-Host "[>] Detecting latest release for windows-$arch..." -ForegroundColor Cyan

    $tag = $DefaultDnsproxyVer
    try {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/AdguardTeam/dnsproxy/releases/latest" -TimeoutSec 5 -ErrorAction SilentlyContinue
        if ($release.tag_name) {
            $tag = $release.tag_name
        }
    } catch {}

    $zipName = "dnsproxy-windows-$arch-$tag.zip"
    $downloadUrl = "https://github.com/AdguardTeam/dnsproxy/releases/download/$tag/$zipName"
    $tempZip = "$env:TEMP\$zipName"

    Write-Host "[>] Downloading dnsproxy ($tag)..." -ForegroundColor Cyan
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
        Invoke-WebRequest -Uri $downloadUrl -OutFile $tempZip -UseBasicParsing
    } catch {
        Write-Warning "Primary download failed. Trying fallback version $DefaultDnsproxyVer..."
        $zipName = "dnsproxy-windows-$arch-$DefaultDnsproxyVer.zip"
        $downloadUrl = "https://github.com/AdguardTeam/dnsproxy/releases/download/$DefaultDnsproxyVer/$zipName"
        Invoke-WebRequest -Uri $downloadUrl -OutFile $tempZip -UseBasicParsing
    }

    New-Item -ItemType Directory -Path $BinDir -Force | Out-Null
    $extractTemp = "$env:TEMP\dnszen_extract"
    if (Test-Path $extractTemp) { Remove-Item -Recurse -Force $extractTemp }
    Expand-Archive -Path $tempZip -DestinationPath $extractTemp -Force

    $foundExe = Get-ChildItem -Path $extractTemp -Filter "dnsproxy.exe" -Recurse | Select-Object -First 1
    if (-not $foundExe) {
        throw "Could not locate dnsproxy.exe inside downloaded archive."
    }

    Copy-Item $foundExe.FullName -Destination $DnsproxyExe -Force
    Remove-Item $tempZip -Force -ErrorAction SilentlyContinue
    Remove-Item $extractTemp -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host "[OK] Installed dnsproxy engine to $DnsproxyExe" -ForegroundColor Green
}

function Sanitize-Url([string]$raw) {
    $clean = $raw.Trim()
    if ($clean -notmatch "^https?://") {
        $clean = "https://$clean"
    }
    return $clean
}

function Verify-DoHUrl([string]$url) {
    Write-Host "[>] Verifying DoH endpoint: $url..." -ForegroundColor Cyan

    $testPort = 55353
    $proc = Start-Process -FilePath $DnsproxyExe -ArgumentList "--listen=127.0.0.1 --port=$testPort --upstream=`"$url`" --bootstrap=1.1.1.1:53 --bootstrap=8.8.8.8:53 --timeout=5s" -PassThru -WindowStyle Hidden

    Start-Sleep -Seconds 2

    $verified = $false
    try {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $dnsRes = Resolve-DnsName -Name "google.com" -Server "127.0.0.1" -Port $testPort -ErrorAction Stop -QuickTimeout
        $sw.Stop()
        if ($dnsRes) {
            $verified = $true
            Write-Host "[OK] Verification successful! Response time: $($sw.ElapsedMilliseconds) ms" -ForegroundColor Green
        }
    } catch {
        Write-Warning "Could not resolve test query through $url."
    } finally {
        if (-not $proc.HasExited) {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        }
    }

    return $verified
}

function Prompt-DoHUrl {
    Write-Host ""
    Write-Host "Enter your Custom DNS-over-HTTPS (DoH) URL:" -ForegroundColor White
    Write-Host "Examples:" -ForegroundColor DarkGray
    Write-Host "  * NextDNS:    https://dns.nextdns.io/xxxxxx" -ForegroundColor Cyan
    Write-Host "  * AdGuard:    https://dns.adguard-dns.com/dns-query" -ForegroundColor Cyan
    Write-Host "  * Cloudflare: https://cloudflare-dns.com/dns-query" -ForegroundColor Cyan
    Write-Host "  * Self-host:  https://yourdomain.com/dns-query" -ForegroundColor Cyan
    Write-Host ""

    while ($true) {
        $inputUrl = Read-Host "DoH URL"
        if ([string]::IsNullOrWhiteSpace($inputUrl)) {
            Write-Warning "URL cannot be empty."
            continue
        }

        $sanitized = Sanitize-Url $inputUrl
        if (Verify-DoHUrl $sanitized) {
            return $sanitized
        } else {
            Write-Host ""
            Write-Host "Verification failed. Options:" -ForegroundColor Yellow
            Write-Host "  [1] Re-enter another URL (Recommended)"
            Write-Host "  [2] Use this URL anyway"
            Write-Host "  [3] Cancel"
            $opt = Read-Host "Select [1-3]"
            if ($opt -eq "2") { return $sanitized }
            if ($opt -eq "3") { Exit }
        }
    }
}

function Write-ProxyConfig([string]$url) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    $yaml = @"
# Generated by DNSZen
listen-addrs:
  - "127.0.0.1"
listen-ports:
  - 53
upstream:
  - "$url"
bootstrap:
  - "1.1.1.1:53"
  - "8.8.8.8:53"
  - "9.9.9.9:53"
cache: true
cache-size: 65536
cache-optimistic: true
upstream-mode: load_balance
dnssec: false
timeout: "6s"
"@
    Set-Content -Path $ConfigFile -Value $yaml -Encoding UTF8
}

function Setup-ScheduledTask {
    Write-Host "[>] Configuring Windows background service..." -ForegroundColor Cyan

    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

    $action = New-ScheduledTaskAction -Execute $DnsproxyExe -Argument "--config-path=`"$ConfigFile`""
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit (New-TimeSpan -Days 365)

    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Start-ScheduledTask -TaskName $TaskName

    Write-Host "[OK] Windows background service registered and started." -ForegroundColor Green
}

function Configure-SystemDNS {
    Write-Host "[>] Configuring Windows network adapters to use 127.0.0.1..." -ForegroundColor Cyan

    if (-not (Test-Path $BackupFile)) {
        $currentDNS = Get-DnsClientServerAddress -AddressFamily IPv4
        $currentDNS | Export-Clixml -Path $BackupFile
        Write-Host "[OK] Backed up original DNS configuration." -ForegroundColor Green
    }

    $adapters = Get-NetAdapter | Where-Object Status -eq 'Up'
    foreach ($adapter in $adapters) {
        Set-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -ServerAddresses ("127.0.0.1") -ErrorAction SilentlyContinue
    }

    Clear-DnsClientCache
    Write-Host "[OK] Network adapters configured to 127.0.0.1." -ForegroundColor Green
}

function Revert-SystemDNS {
    Write-Host "[>] Restoring original network adapter DNS..." -ForegroundColor Cyan

    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

    $adapters = Get-NetAdapter | Where-Object Status -eq 'Up'
    if (Test-Path $BackupFile) {
        $saved = Import-Clixml -Path $BackupFile
        foreach ($item in $saved) {
            if ($item.ServerAddresses -and $item.ServerAddresses.Count -gt 0) {
                Set-DnsClientServerAddress -InterfaceIndex $item.InterfaceIndex -ServerAddresses $item.ServerAddresses -ErrorAction SilentlyContinue
            } else {
                Set-DnsClientServerAddress -InterfaceIndex $item.InterfaceIndex -ResetServerAddresses -ErrorAction SilentlyContinue
            }
        }
    } else {
        foreach ($adapter in $adapters) {
            Set-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -ResetServerAddresses -ErrorAction SilentlyContinue
        }
    }

    Clear-DnsClientCache
    Remove-Item -Path $InstallDir -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host "[OK] Original system DNS settings restored completely." -ForegroundColor Green
}

function Invoke-Install {
    Show-Banner
    Install-Dnsproxy
    $url = Prompt-DoHUrl
    Write-ProxyConfig $url
    Setup-ScheduledTask
    Configure-SystemDNS

    $state = @{
        DOH_URL = $url
        Version = $Version
        InstalledAt = (Get-Date).ToString("o")
    }
    $state | ConvertTo-Json | Set-Content $StateFile -Encoding UTF8

    # Create global CLI wrapper in C:\Windows\dnszen.cmd
    Copy-Item $MyInvocation.MyCommand.Path -Destination "$InstallDir\dnszen.ps1" -Force -ErrorAction SilentlyContinue
    $cmdWrapper = @"
@echo off
powershell.exe -ExecutionPolicy Bypass -NoProfile -File "$InstallDir\dnszen.ps1" %*
"@
    Set-Content -Path "C:\Windows\dnszen.cmd" -Value $cmdWrapper -Encoding ASCII -Force -ErrorAction SilentlyContinue

    Start-Sleep -Seconds 2
    Write-Host ""
    Write-Host "===============================================================" -ForegroundColor Green
    Write-Host "  * DNSZen is installed and running system-wide on Windows!" -ForegroundColor Green
    Write-Host "===============================================================" -ForegroundColor Green
    Write-Host "  * Upstream DoH: $url" -ForegroundColor Cyan
    Write-Host "  * Primary DNS:  127.0.0.1:53"
    Write-Host "  * Task:         Runs at system startup under SYSTEM"
    Write-Host "  * CLI Access:   Type 'dnszen' in any terminal window" -ForegroundColor Yellow
    Write-Host ""
}

function Show-Status {
    if (Test-Path $StateFile) {
        $st = Get-Content $StateFile | ConvertFrom-Json
        Write-Host ""
        Write-Host "--- DNSZen System Status ---" -ForegroundColor White
        Write-Host "  Status:        ACTIVE" -ForegroundColor Green
        Write-Host "  Upstream DoH:  $($st.DOH_URL)" -ForegroundColor Cyan
        Write-Host "  Primary DNS:   127.0.0.1:53"
        Write-Host "  Installed At:  $($st.InstalledAt)" -ForegroundColor DarkGray
        Write-Host ""
    } else {
        Write-Host "DNSZen Status: NOT INSTALLED" -ForegroundColor Red
    }
}

function Show-Menu {
    while ($true) {
        Show-Banner
        $statusStr = "NOT INSTALLED"
        $currentUrl = "None"
        if (Test-Path $StateFile) {
            $st = Get-Content $StateFile | ConvertFrom-Json
            $statusStr = "ACTIVE"
            $currentUrl = $st.DOH_URL
        }
        Write-Host "  Current Status: $statusStr" -ForegroundColor Green
        Write-Host "  Active DoH URL: $currentUrl" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  [1] Change DoH URL"
        Write-Host "  [2] View Status & Live Diagnostics"
        Write-Host "  [3] Test DNS Resolution & Speed"
        Write-Host "  [4] Restart DNSZen Service"
        Write-Host "  [5] Revert to Original DNS & Uninstall"
        Write-Host ""
        Write-Host "  Author GitHub: https://github.com/mxskeen/dnszen/" -ForegroundColor Cyan
        Write-Host "  [6] Exit"
        Write-Host ""
        $choice = Read-Host "Select option [1-6]"
        switch ($choice) {
            "1" {
                $newUrl = Prompt-DoHUrl
                Write-ProxyConfig $newUrl
                Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
                Start-ScheduledTask -TaskName $TaskName
                $st = Get-Content $StateFile | ConvertFrom-Json
                $st.DOH_URL = $newUrl
                $st | ConvertTo-Json | Set-Content $StateFile -Encoding UTF8
                Write-Host "[OK] Updated upstream DoH URL to: $newUrl" -ForegroundColor Green
                Read-Host "Press Enter to return to menu..."
            }
            "2" {
                Show-Status
                Read-Host "Press Enter to return to menu..."
            }
            "3" {
                $dom = Read-Host "Enter domain to test [default: cloudflare.com]"
                if (-not $dom) { $dom = "cloudflare.com" }
                Resolve-DnsName -Name $dom -Server "127.0.0.1"
                Read-Host "Press Enter to return to menu..."
            }
            "4" {
                Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
                Start-ScheduledTask -TaskName $TaskName
                Write-Host "[OK] DNSZen service restarted." -ForegroundColor Green
                Read-Host "Press Enter to return to menu..."
            }
            "5" {
                $confirm = Read-Host "Are you sure you want to revert to original DNS? [y/N]"
                if ($confirm -match "^[yY]") {
                    Revert-SystemDNS
                    Exit
                }
            }
            "6" {
                Exit
            }
        }
    }
}

# Elevation check
Elevate-Privileges

switch ($Command.ToLower()) {
    "install" {
        Invoke-Install
    }
    "set" {
        $targetUrl = $Arg
        if (-not $targetUrl) {
            $targetUrl = Prompt-DoHUrl
        } else {
            $targetUrl = Sanitize-Url $targetUrl
            Verify-DoHUrl $targetUrl | Out-Null
        }
        Write-ProxyConfig $targetUrl
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        Start-ScheduledTask -TaskName $TaskName
        if (Test-Path $StateFile) {
            $st = Get-Content $StateFile | ConvertFrom-Json
            $st.DOH_URL = $targetUrl
            $st | ConvertTo-Json | Set-Content $StateFile -Encoding UTF8
        }
        Write-Host "[OK] Updated upstream DoH URL to: $targetUrl" -ForegroundColor Green
    }
    "revert" {
        Revert-SystemDNS
    }
    "status" {
        Show-Status
    }
    "test" {
        $dom = if ($Arg) { $Arg } else { "cloudflare.com" }
        Write-Host "Querying $dom via 127.0.0.1..."
        Resolve-DnsName -Name $dom -Server "127.0.0.1"
    }
    "menu" {
        Show-Menu
    }
    Default {
        if (-not (Test-Path $StateFile)) {
            Invoke-Install
        } else {
            Show-Menu
        }
    }
}
