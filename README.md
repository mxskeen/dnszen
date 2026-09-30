# 🛡️ DNSZen

> **System-Wide Custom DNS over HTTPS (DoH) for Desktop PC.**  
> Like Android's *"Private DNS"*, but built for Linux, macOS, and Windows.

---

## ⚡ The Problem

On Android, you can go into **Settings → Network → Private DNS**, type your custom DNS URL or hostname (like NextDNS, AdGuard, or your private Pi-hole), and **every single app and query on your phone routes through it encrypted**.

On desktop computers (Linux, macOS, Windows), there is no native, hassle-free way to simply paste a custom DNS-over-HTTPS (DoH) URL:
- Standard desktop resolvers don't support custom DoH URLs out of the box.
- Browser-only DoH ignores terminal apps, system services, Docker, Git, Spotify, games, etc.
- Manually compiling proxies, writing service daemons, and reconfiguring network managers is complex and fragile.

## 🚀 The Solution: DNSZen

**DNSZen** turns your custom DoH URL into a permanent, system-wide, encrypted DNS resolver in seconds:
1. Clone the repository and run the script.
2. It automatically detects your **Operating System** and **CPU Architecture**.
3. Downloads and sets up the ultra-fast AdGuard `dnsproxy` engine.
4. Asks for your DoH URL and **verifies it live** before applying.
5. Configures a persistent background service (`systemd` on Linux, `launchd` on macOS, Scheduled Task on Windows).
6. Points your system resolver to local encrypted resolution.

Close your terminal — **it runs in the background forever, across reboots**.  
Change your URL anytime with one command. Revert back to your original settings with zero traces left behind.

---

## 💻 Quick Start

### Linux & macOS

```bash
# 1. Clone this repository
git clone https://github.com/your-username/dnszen.git
cd dnszen

# 2. Run the installer
sudo ./dnszen.sh
```

Follow the prompt to enter your custom DoH URL. Once verified and installed, DNSZen registers itself globally as `dnszen`:

```bash
# You can now run DNSZen from ANY terminal window:
sudo dnszen
```

### Windows (PowerShell)

Open PowerShell as **Administrator**:

```powershell
# 1. Clone this repository
git clone https://github.com/your-username/dnszen.git
cd dnszen

# 2. Run the script
.\dnszen.ps1
```

---

## 🔧 Management & CLI Commands

Once installed, manage your DNS anytime via CLI commands or the interactive menu:

| Command | Action |
|---|---|
| `sudo dnszen` | Opens the interactive visual management menu |
| `sudo dnszen set <url>` | Changes your upstream DoH URL (verifies before saving) |
| `sudo dnszen status` | Shows current service state, listener address, and active URL |
| `sudo dnszen test [domain]` | Tests DNS resolution and measures response latency |
| `sudo dnszen logs` | Displays recent logs from the background daemon |
| `sudo dnszen restart` | Restarts the background proxy service |
| `sudo dnszen revert` | Restores original system DNS and cleanly uninstalls DNSZen |

---

## 🌐 Supported DoH Providers

DNSZen works with any standard DNS-over-HTTPS endpoint:

| Provider | Example URL |
|---|---|
| **NextDNS** | `https://dns.nextdns.io/xxxxxx` |
| **AdGuard DNS** | `https://dns.adguard-dns.com/dns-query` |
| **Cloudflare** | `https://cloudflare-dns.com/dns-query` |
| **ControlD** | `https://dns.controld.com/xxxxxx` |
| **Quad9** | `https://dns.quad9.net/dns-query` |
| **Pi-hole / Technitium / AdGuard Home** | `https://your-domain.com/dns-query` |

*Note: You can omit `https://` when typing — DNSZen will auto-format it for you.*

---

## 🏗️ How It Works Under The Hood

```
+---------------------------------------------------------+
|                  Your Desktop Applications              |
|          (Browser, Terminal, Games, Docker, Apps)       |
+---------------------------------------------------------+
                            │
              Standard DNS (UDP/TCP Port 53)
                            ▼
+─────────────────────────────────────────────────────────+
|                  127.0.0.1:53 (DNSZen)                  |
|    - Local caching (optimistic, sub-millisecond hits)   |
|    - Independent bootstrap resolvers (no DNS loops)     |
+─────────────────────────────────────────────────────────+
                            │
               Encrypted DNS-over-HTTPS (DoH)
                            ▼
+─────────────────────────────────────────────────────────+
|                Your Custom DoH Endpoint                 |
|             (e.g., https://dns.nextdns.io/...)          |
+─────────────────────────────────────────────────────────+
```

1. **Auto-Detection**: DNSZen detects your OS (Debian/Ubuntu, Arch, Fedora, openSUSE, Alpine, macOS, Windows) and architecture (`x86_64`, `arm64` / Apple Silicon, `armv7`, `386`).
2. **Safe Verification**: Before altering any system settings, DNSZen spawns an ephemeral test proxy on port `55353` and executes a live DNS query to verify your DoH endpoint. If unreachable, your system DNS is untouched.
3. **Automatic Backups**:
   - On Linux: Saves `/etc/resolv.conf` (target symlink or static file) and integrates cleanly with `systemd-resolved` and `NetworkManager`.
   - On macOS: Saves existing DNS servers for all active network services.
   - On Windows: Exports adapter DNS settings to an XML backup file.
4. **Daemon Persistence**:
   - Linux: Systemd service (`dnszen.service`) enabled across reboots.
   - macOS: Launchd daemon (`com.dnszen.dnsproxy.plist`) enabled across reboots.
   - Windows: Scheduled task running at boot with highest privileges.
5. **Clean Revert**: Running `dnszen revert` stops the daemon, restores the exact backed up configuration, and deletes all installed components.

---

## 📦 Requirements

- **Linux**: Any standard distribution (systemd, OpenRC, etc.)
- **macOS**: 10.14+ (Intel or Apple Silicon)
- **Windows**: Windows 10 or Windows 11 (PowerShell 5.1+)
- **Root / Administrator privileges** (required to bind port 53 and configure system DNS)

---

## 📄 License

MIT License. See [LICENSE](LICENSE) for details.
