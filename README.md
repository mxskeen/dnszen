# DNSZen

System-wide custom DNS-over-HTTPS (DoH) for Linux, macOS, and Windows. Similar to Android's "Private DNS", but for desktop.

<img width="652" height="635" alt="image" src="https://github.com/user-attachments/assets/18e64c5d-3101-406d-84f6-343c5ae6c6d4" />


---

## Why System-Wide?

- **Protects Everything, Not Just Browsers:** Browser-only DoH ignores terminal tools (`curl`, `git`, `docker`), desktop apps (Spotify, Discord, Slack, Steam), and system processes. DNSZen covers 100% of your system traffic.
- **Blocks Ads & Trackers Across All Apps:** Filtering rules from your provider (e.g. NextDNS, AdGuard, Pi-hole) apply to all desktop software, not just websites.
- **Prevents ISP Snooping & Hijacking:** DNS queries travel encrypted inside HTTPS (port 443), stopping ISP tracking, censorship, and Wi-Fi eavesdropping.
- **Sub-Millisecond Caching:** Local in-memory caching serves repeated lookups instantly (`< 1 ms`).
- **Network Agnostic:** Keeps your encrypted DNS active across Wi-Fi and Ethernet changes without DHCP leaks.

---

## Quickstart

### One-Line Install (Zero Clone)

**Linux & macOS:**
```bash
curl -sSL https://raw.githubusercontent.com/mxskeen/dnszen/master/install.sh | sudo bash
```

**Windows (PowerShell as Admin):**
```powershell
irm https://raw.githubusercontent.com/mxskeen/dnszen/master/install.ps1 | iex
```

<details>
<summary><b>Or install via Git Clone</b></summary>

**Linux & macOS:**
```bash
git clone https://github.com/mxskeen/dnszen.git
cd dnszen
sudo ./install.sh
```

**Windows:**
```powershell
git clone https://github.com/mxskeen/dnszen.git
cd dnszen
.\install.ps1
```
*(If using Git Bash, running `./install.sh` will auto-launch the PowerShell installer).*

</details>

---

## Usage

Once installed, manage DNSZen from any terminal window:

### Visual Menu

From any terminal window:
- **Linux & macOS:** `sudo dnszen`
- **Windows (PowerShell / CMD):** `dnszen` *(or `.\install.ps1`)*

### CLI Commands

| Action | Linux / macOS | Windows (PowerShell / CMD) |
|---|---|---|
| **Open Visual Menu** | `sudo dnszen` | `dnszen` |
| **Live Query Monitor** | `sudo dnsmonitor` *(or `sudo dnszen monitor`)* | `dnsmonitor` *(or `dnszen monitor`)* |
| **Select Privacy Preset** | `sudo dnszen presets` | `dnszen presets` |
| **Change DoH URL / Preset** | `sudo dnszen set [preset|url]` | `dnszen set [preset|url]` |
| **Verify Encryption & Leaks** | `sudo dnszen verify` | `dnszen verify` |
| **Check Status** | `sudo dnszen status` | `dnszen status` |
| **Test Query & Latency** | `sudo dnszen test [domain]` | `dnszen test [domain]` |
| **Restart Service** | `sudo dnszen restart` | `dnszen restart` |
| **View Logs** | `sudo dnszen logs` | `Get-ScheduledTask DNSZen` |
| **Update DNSZen** | `sudo dnszen update` | `dnszen update` |
| **Revert to Original DNS** | `sudo dnszen revert` | `dnszen revert` |

---

### Popular Privacy Presets

Don't have a custom NextDNS or AdGuard account yet? Choose from 5 built-in zero-configuration privacy presets:

| Option | Provider | Description |
|---|---|---|
| **[1] AdGuard DNS** | AdGuard | Ad, tracker, phishing & malware blocking |
| **[2] Cloudflare Security** | Cloudflare (1.1.1.2) | High-speed DoH + automated malware blocking |
| **[3] Quad9** | Quad9 (9.9.9.9) | Threat intelligence, DNSSEC & Swiss privacy |
| **[4] Mullvad DNS** | Mullvad | Strict zero-log privacy + ad & tracker blocking |
| **[5] Cloudflare Standard** | Cloudflare (1.1.1.1) | Clean, ultra-low latency encrypted DNS |

Switch to any preset anytime from terminal:
```bash
sudo dnszen set adguard
sudo dnszen set cloudflare
sudo dnszen set quad9
sudo dnszen set mullvad
```

---

### Live Query Monitor (`dnsmonitor`)

Inspect live DNS queries passing through your encrypted local proxy in real time:

```bash
# Linux & macOS
sudo dnsmonitor

# Windows (PowerShell / CMD)
dnsmonitor
```

```text
  TIME       TYPE   DOMAIN                             STATUS       LATENCY    ANSWER
  ────────── ────── ────────────────────────────────── ──────────── ────────── ─────────────────────────
  15:47:36   A      cloudflare.com                     [RESOLVED]   18ms       104.16.133.229, 104.16.132.229
  15:47:36   A      doubleclick.net                    [BLOCKED]    24ms       0.0.0.0
  15:47:36   A      cloudflare.com                     [CACHED]     <1ms       104.16.133.229, 104.16.132.229
  15:47:37   A      analytics.tracker.example          [BLOCKED]    31ms       0.0.0.0
```

- **Filter & Block Detection:** Instantly flags ad and tracker blocks (`[BLOCKED]`) from your upstream provider (RethinkDNS, NextDNS, AdGuard).
- **Latency Benchmark:** Measures real round-trip query time for each request.
- **Cache Optimization:** Shows sub-millisecond local cache hits (`[CACHED]`).

---

### Self-Update & Release Notifications

DNSZen checks GitHub in the background (non-blocking, cached for 24 hours) and notifies you in the terminal when a newer version is released:

```text
┌─────────────────────────────────────────────────────────────┐
│  Update Available! v1.0.0 -> v1.1.0                         │
│  Run 'sudo dnszen update' to install the latest features.   │
└─────────────────────────────────────────────────────────────┘
```

To update DNSZen directly anytime:
```bash
# Linux & macOS
sudo dnszen update

# Windows (PowerShell / CMD)
dnszen update
```

---

## Example Custom DoH URLs

- **NextDNS:** `https://dns.nextdns.io/xxxxxx`
- **ControlD:** `https://dns.controld.com/xxxxxx`
- **AdGuard Custom:** `https://dns.adguard-dns.com/dns-query`
- **Self-Hosted (Pi-hole / Technitium):** `https://dns.yourdomain.com/dns-query`

*(You can omit `https://` when typing — DNSZen auto-formats it).*

---

## How It Works

1. **Auto-Detects** your OS (Linux, macOS, Windows) and architecture (`x86_64`, `arm64`, `armv7`, `386`).
2. **Verifies** your DoH URL with a test DNS query before making any system changes.
3. **Runs in Background**: Registers a persistent service (`systemd` on Linux, `launchd` on macOS, Scheduled Task on Windows) listening on `127.0.0.1:53`. Survives terminal exit and system reboots.
4. **Routes System DNS**: Points your OS resolver to `127.0.0.1`.
5. **Reversible**: Backs up previous settings. Running `revert` completely restores original DNS configurations.

---

## License

[MIT](LICENSE)
