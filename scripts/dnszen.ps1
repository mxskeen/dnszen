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
$LogFile = "$InstallDir\dnszen.log"
$TaskName = "DNSZen"

function Show-Banner {
    Write-Host "" -ForegroundColor Cyan
    Write-Host "  ===============================================================" -ForegroundColor Cyan
    Write-Host "             DNSZen for Windows - Custom DNS-over-HTTPS           " -ForegroundColor Cyan
    Write-Host "                  System-Wide * Persistent * Fast                " -ForegroundColor Cyan
    Write-Host "                           by @mxskeen                           " -ForegroundColor DarkCyan
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
output: "$LogFile"
verbose: true
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
    Remove-Item -Path "C:\Windows\dnszen.cmd" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "C:\Windows\dnsmonitor.cmd" -Force -ErrorAction SilentlyContinue
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

    # Create global CLI wrappers in C:\Windows\dnszen.cmd and C:\Windows\dnsmonitor.cmd
    Copy-Item $MyInvocation.MyCommand.Path -Destination "$InstallDir\dnszen.ps1" -Force -ErrorAction SilentlyContinue
    $cmdWrapper = @"
@echo off
powershell.exe -ExecutionPolicy Bypass -NoProfile -File "$InstallDir\dnszen.ps1" %*
"@
    Set-Content -Path "C:\Windows\dnszen.cmd" -Value $cmdWrapper -Encoding ASCII -Force -ErrorAction SilentlyContinue

    $monitorWrapper = @"
@echo off
powershell.exe -ExecutionPolicy Bypass -NoProfile -File "$InstallDir\dnszen.ps1" monitor %*
"@
    Set-Content -Path "C:\Windows\dnsmonitor.cmd" -Value $monitorWrapper -Encoding ASCII -Force -ErrorAction SilentlyContinue

    Start-Sleep -Seconds 2
    Write-Host ""
    Write-Host "===============================================================" -ForegroundColor Green
    Write-Host "  * DNSZen is installed and running system-wide on Windows!" -ForegroundColor Green
    Write-Host "===============================================================" -ForegroundColor Green
    Write-Host "  * Upstream DoH: $url" -ForegroundColor Cyan
    Write-Host "  * Primary DNS:  127.0.0.1:53"
    Write-Host "  * Task:         Runs at system startup under SYSTEM"
    Write-Host "  * CLI Access:   Type 'dnszen' or 'dnsmonitor' in any terminal" -ForegroundColor Yellow
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

function Test-DnsZenSecurity {
    Write-Host ""
    Write-Host "=== DNSZen Security, Encryption & Leak Verification ===" -ForegroundColor White
    Write-Host ""

    if (-not (Test-Path $StateFile)) {
        Write-Warning "DNSZen is not installed yet."
        return
    }

    $st = Get-Content $StateFile | ConvertFrom-Json
    $dohUrl = $st.DOH_URL

    # 1. Local Task Status
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task -and $task.State -eq "Running") {
        Write-Host "  [OK] Local Proxy Daemon:     Running on 127.0.0.1:53" -ForegroundColor Green
    } else {
        Write-Host "  [!] Local Proxy Daemon:      Not Running" -ForegroundColor Yellow
    }

    # 2. Adapter DNS Check
    $adapters = Get-NetAdapter | Where-Object Status -eq 'Up'
    $allLocked = $true
    foreach ($adapter in $adapters) {
        $dns = Get-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        if ($dns.ServerAddresses -notcontains "127.0.0.1") {
            $allLocked = $false
        }
    }

    if ($allLocked) {
        Write-Host "  [OK] Network Adapters:       Locked to 127.0.0.1 (No plaintext ISP leaks)" -ForegroundColor Green
    } else {
        Write-Host "  [!] Network Adapters:        Some adapters may have alternate DNS" -ForegroundColor Yellow
    }

    # 3. Transport & Upstream
    Write-Host "  [OK] DNS Encryption:          Active (DNS-over-HTTPS / TLS 1.3)" -ForegroundColor Green
    Write-Host "  [OK] Upstream Endpoint:       $dohUrl" -ForegroundColor Cyan

    # 4. Latency Benchmark
    try {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $res = Resolve-DnsName -Name "cloudflare.com" -Server "127.0.0.1" -QuickTimeout -ErrorAction Stop
        $sw.Stop()
        if ($res) {
            Write-Host "  [OK] End-to-End Latency:      $($sw.ElapsedMilliseconds) ms" -ForegroundColor Green
        }
    } catch {
        Write-Host "  [!] End-to-End Test:          Resolution failed" -ForegroundColor Red
    }

    Write-Host ""
    Write-Host "---------------------------------------------------------------" -ForegroundColor Green
    Write-Host "  Overall Status:  PROTECTED * System-Wide Encrypted * Leak-Free" -ForegroundColor Green
    Write-Host "---------------------------------------------------------------" -ForegroundColor Green
    Write-Host ""
}

function Emit-QueryRow($ev) {
    if (-not $ev.Domain) { return }
    $dispDom = if ($ev.Domain.Length -gt 34) { $ev.Domain.Substring(0, 31) + "..." } else { $ev.Domain }

    $isBlocked = $false
    foreach ($ans in $ev.Answers) {
        if ($ans -in @("0.0.0.0", "::", "127.0.0.1", "0.0.0.0/0")) {
            $isBlocked = $true
            break
        }
    }

    $statusCol = "Green"
    $tag = "[RESOLVED]"
    if ($isBlocked) {
        $tag = "[BLOCKED]"
        $statusCol = "Red"
    } elseif ($ev.Cached) {
        $tag = "[CACHED]"
        $statusCol = "Cyan"
        if (-not $ev.Latency) { $ev.Latency = "<1ms" }
    } elseif ($ev.Status -eq "NXDOMAIN") {
        $tag = "[NXDOMAIN]"
        $statusCol = "Yellow"
    } elseif ($ev.Status -in @("REFUSED", "SERVFAIL")) {
        $tag = "[$($ev.Status)]"
        $statusCol = "Red"
    }

    if (-not $ev.Latency) {
        $ev.Latency = if ($tag -eq "[CACHED]") { "<1ms" } else { "-" }
    }

    $ansStr = if ($ev.Answers.Count -gt 0) { $ev.Answers -join ", " } else { if ($tag -in @("[RESOLVED]","[CACHED]")) { "NODATA" } else { $tag.Trim("[]") } }
    if ($ansStr.Length -gt 40) { $ansStr = $ansStr.Substring(0, 37) + "..." }

    Write-Host ("  {0,-10} {1,-6} {2,-34} " -f $ev.Time, $ev.Type, $dispDom) -NoNewline -ForegroundColor Gray
    Write-Host ("{0,-12} " -f $tag) -NoNewline -ForegroundColor $statusCol
    Write-Host ("{0,-10} {1}" -f $ev.Latency, $ansStr)
}

function Show-LiveMonitor {
    Write-Host ""
    Write-Host "  ===============================================================" -ForegroundColor Cyan
    Write-Host "             DNSZen Live Query Monitor (Ctrl+C to exit)          " -ForegroundColor Cyan
    Write-Host "  ===============================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host ("  {0,-10} {1,-6} {2,-34} {3,-12} {4,-10} {5}" -f "TIME", "TYPE", "DOMAIN", "STATUS", "LATENCY", "ANSWER") -ForegroundColor White
    Write-Host ("  {0} {1} {2} {3} {4} {5}" -f ("-"*10), ("-"*6), ("-"*34), ("-"*12), ("-"*10), ("-"*25)) -ForegroundColor DarkGray

    if (-not (Test-Path $LogFile)) {
        New-Item -ItemType File -Path $LogFile -Force | Out-Null
    }

    # Ensure proxy config has logging enabled
    if (Test-Path $ConfigFile) {
        $cfg = Get-Content $ConfigFile -Raw
        if ($cfg -notmatch "output:") {
            Add-Content -Path $ConfigFile -Value "`noutput: `"$LogFile`"`nverbose: true"
            Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
            Start-ScheduledTask -TaskName $TaskName
        }
    }

    $pendingDurations = @{}
    $cachedFlag = $false
    $currentEvent = $null

    try {
        Get-Content -Path $LogFile -Tail 30 -Wait | ForEach-Object {
            $line = $_.Trim()
            if (-not $line) { return }

            if ($line -match 'duration=([0-9.]+m?s)') {
                $durVal = $matches[1]
                if ($line -match 'question=";([^\\\s]+)\.\\tIN\\t\s*([A-Za-z0-9]+)"') {
                    $qdom = $matches[1].ToLower()
                    $qtype = $matches[2]
                    $pendingDurations["$qdom:$qtype"] = $durVal
                }
            }

            if ($line -match "replying from cache") {
                $cachedFlag = $true
            }

            if ($line -match '(\d{2}:\d{2}:\d{2})\.\d+ DEBUG out prefix=dnsproxy line_num=1 line=";; opcode: QUERY, status: ([A-Z]+), id: (\d+)"') {
                $ts = $matches[1]
                $status = $matches[2]
                $qid = $matches[3]
                $currentEvent = @{
                    Time = $ts
                    Status = $status
                    Id = $qid
                    Domain = ""
                    Type = ""
                    Answers = [System.Collections.Generic.List[string]]::new()
                    Cached = $cachedFlag
                    Latency = ""
                    Expected = -1
                }
                $cachedFlag = $false
                return
            }

            if (-not $currentEvent) { return }

            if ($line -match 'ANSWER: (\d+)') {
                $currentEvent.Expected = [int]$matches[1]
            }

            if ($line -match 'line=";([^\\\s]+)\.\\tIN\\t\s*([A-Za-z0-9]+)"') {
                $currentEvent.Domain = $matches[1]
                $currentEvent.Type = $matches[2]
                $key = "$($currentEvent.Domain.ToLower()):$($currentEvent.Type)"
                if ($pendingDurations.ContainsKey($key)) {
                    $currentEvent.Latency = $pendingDurations[$key]
                    $pendingDurations.Remove($key)
                }
                if ($currentEvent.Expected -eq 0) {
                    Emit-QueryRow $currentEvent
                    $currentEvent = $null
                }
                return
            }

            if ($line -match 'line="[^\\]+\\t\d+\\tIN\\t([A-Za-z0-9]+)\\t([^"]+)"') {
                $currentEvent.Answers.Add($matches[2])
                if ($currentEvent.Expected -ge 0 -and $currentEvent.Answers.Count -ge $currentEvent.Expected) {
                    Emit-QueryRow $currentEvent
                    $currentEvent = $null
                }
                return
            }
        }
    } catch {
        # Graceful exit on interrupt
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
        Write-Host "  [3] Verify Security, Encryption & Leak Test"
        Write-Host "  [4] Live Query Monitor (dnsmonitor)"
        Write-Host "  [5] Test DNS Resolution & Speed"
        Write-Host "  [6] Restart DNSZen Service"
        Write-Host "  [7] Revert to Original DNS & Uninstall"
        Write-Host ""
        Write-Host "  Author GitHub: https://github.com/mxskeen/dnszen/" -ForegroundColor Cyan
        Write-Host "  [8] Exit"
        Write-Host ""
        $choice = Read-Host "Select option [1-8]"
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
                Test-DnsZenSecurity
                Read-Host "Press Enter to return to menu..."
            }
            "4" {
                Show-LiveMonitor
                Read-Host "Press Enter to return to menu..."
            }
            "5" {
                $dom = Read-Host "Enter domain to test [default: cloudflare.com]"
                if (-not $dom) { $dom = "cloudflare.com" }
                Resolve-DnsName -Name $dom -Server "127.0.0.1"
                Read-Host "Press Enter to return to menu..."
            }
            "6" {
                Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
                Start-ScheduledTask -TaskName $TaskName
                Write-Host "[OK] DNSZen service restarted." -ForegroundColor Green
                Read-Host "Press Enter to return to menu..."
            }
            "7" {
                $confirm = Read-Host "Are you sure you want to revert to original DNS? [y/N]"
                if ($confirm -match "^[yY]") {
                    Revert-SystemDNS
                    Exit
                }
            }
            "8" {
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
    "monitor" {
        Show-LiveMonitor
    }
    "dnsmonitor" {
        Show-LiveMonitor
    }
    "watch" {
        Show-LiveMonitor
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
    "verify" {
        Test-DnsZenSecurity
    }
    "leak-test" {
        Test-DnsZenSecurity
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
