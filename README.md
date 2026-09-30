# DNSZen

System-wide custom DNS-over-HTTPS (DoH) for Linux, macOS, and Windows. Similar to Android's "Private DNS", but for desktop.

<img width="697" height="520" alt="image" src="https://github.com/user-attachments/assets/ed3d5b2e-6d14-4e85-97fe-76b1888fd205" />


---

## Why System-Wide?

- **Protects Everything, Not Just Browsers:** Browser-only DoH ignores terminal tools (`curl`, `git`, `docker`), desktop apps (Spotify, Discord, Slack, Steam), and system processes. DNSZen covers 100% of your system traffic.
- **Blocks Ads & Trackers Across All Apps:** Filtering rules from your provider (e.g. NextDNS, AdGuard, Pi-hole) apply to all desktop software, not just websites.
- **Prevents ISP Snooping & Hijacking:** DNS queries travel encrypted inside HTTPS (port 443), stopping ISP tracking, censorship, and Wi-Fi eavesdropping.
- **Sub-Millisecond Caching:** Local in-memory caching serves repeated lookups instantly (`< 1 ms`).
- **Network Agnostic:** Keeps your encrypted DNS active across Wi-Fi and Ethernet changes without DHCP leaks.

---

## Quickstart

### Linux & macOS

```bash
git clone https://github.com/mxskeen/dnszen.git
cd dnszen
sudo ./install.sh
```

### Windows

Open PowerShell as **Administrator**:

```powershell
git clone https://github.com/mxskeen/dnszen.git
cd dnszen
.\install.ps1
```
*(If using Git Bash, running `./install.sh` will auto-launch the PowerShell installer).*

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
| **Change DoH URL** | `sudo dnszen set <url>` | `dnszen set <url>` |
| **Check Status** | `sudo dnszen status` | `dnszen status` |
| **Test Query & Latency** | `sudo dnszen test [domain]` | `dnszen test [domain]` |
| **Restart Service** | `sudo dnszen restart` | `dnszen restart` |
| **View Logs** | `sudo dnszen logs` | `Get-ScheduledTask DNSZen` |
| **Revert to Original DNS** | `sudo dnszen revert` | `dnszen revert` |

---

## Example DoH URLs

- **NextDNS:** `https://dns.nextdns.io/xxxxxx`
- **AdGuard:** `https://dns.adguard-dns.com/dns-query`
- **Cloudflare:** `https://cloudflare-dns.com/dns-query`
- **ControlD:** `https://dns.controld.com/xxxxxx`
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
