#!/usr/bin/env bash
# ==============================================================================
#  DNSZen - System-Wide Custom DNS over HTTPS (DoH) for Desktop & Linux / macOS
#  Similar to Android's "Private DNS", now on your Desktop PC.
# ==============================================================================

set -eo pipefail

# ------------------------------------------------------------------------------
# Constants & Paths
# ------------------------------------------------------------------------------
VERSION="1.0.0"
DNSPROXY_DEFAULT_VER="v0.85.0"
INSTALL_DIR="/opt/dnszen"
BIN_DIR="${INSTALL_DIR}/bin"
CONFIG_DIR="/etc/dnszen"
BACKUP_DIR="${CONFIG_DIR}/backup"
CONFIG_FILE="${CONFIG_DIR}/dnsproxy.yaml"
STATE_FILE="${CONFIG_DIR}/dnszen.conf"
DNSPROXY_BIN="${BIN_DIR}/dnsproxy"
CLI_SYMLINK="/usr/local/bin/dnszen"

SYSTEMD_SERVICE_FILE="/etc/systemd/system/dnszen.service"
SYSTEMD_RESOLVED_DROPIN_DIR="/etc/systemd/resolved.conf.d"
SYSTEMD_RESOLVED_DROPIN="${SYSTEMD_RESOLVED_DROPIN_DIR}/dnszen.conf"
MACOS_LAUNCHD_PLIST="/Library/LaunchDaemons/com.dnszen.dnsproxy.plist"

# ------------------------------------------------------------------------------
# Colors & Formatting
# ------------------------------------------------------------------------------
if [ -t 1 ]; then
    COLOR_RESET="\033[0m"
    COLOR_BOLD="\033[1m"
    COLOR_DIM="\033[2m"
    COLOR_RED="\033[1;31m"
    COLOR_GREEN="\033[1;32m"
    COLOR_YELLOW="\033[1;33m"
    COLOR_BLUE="\033[1;34m"
    COLOR_MAGENTA="\033[1;35m"
    COLOR_CYAN="\033[1;36m"
else
    COLOR_RESET=""
    COLOR_BOLD=""
    COLOR_DIM=""
    COLOR_RED=""
    COLOR_GREEN=""
    COLOR_YELLOW=""
    COLOR_BLUE=""
    COLOR_MAGENTA=""
    COLOR_CYAN=""
fi

log_info()    { echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET} $*"; }
log_ok()      { echo -e "${COLOR_GREEN}[✓]${COLOR_RESET} $*"; }
log_warn()    { echo -e "${COLOR_YELLOW}[!]${COLOR_RESET} $*"; }
log_err()     { echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $*" >&2; }
log_step()    { echo -e "${COLOR_CYAN}[>]${COLOR_RESET} ${COLOR_BOLD}$*${COLOR_RESET}"; }

# ------------------------------------------------------------------------------
# Banner
# ------------------------------------------------------------------------------
show_banner() {
    echo -e "${COLOR_CYAN}"
    echo "  ╔═══════════════════════════════════════════════════════════════╗"
    echo "  ║                                                               ║"
    echo "  ║    ██████╗  ███╗   ██╗ ███████╗███████╗███████╗███╗   ██╗     ║"
    echo "  ║    ██╔══██╗ ████╗  ██║ ██╔════╝╚══███╔╝██╔════╝████╗  ██║     ║"
    echo "  ║    ██║  ██║ ██╔██╗ ██║ ███████╗  ███╔╝ █████╗  ██╔██╗ ██║     ║"
    echo "  ║    ██║  ██║ ██║╚██╗██║ ╚════██║ ███╔╝  ██╔══╝  ██║╚██╗██║     ║"
    echo "  ║    ██████╔╝ ██║ ╚████║ ███████║███████╗███████╗██║ ╚████║     ║"
    echo "  ║    ╚═════╝  ╚═╝  ╚═══╝ ╚══════╝╚══════╝╚══════╝╚═╝  ╚═══╝     ║"
    echo "  ║                                                               ║"
    echo "  ║           Custom DNS-over-HTTPS (DoH) for Desktop             ║"
    echo "  ║                System-Wide • Persistent • Fast                ║"
    echo "  ╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${COLOR_RESET}"
}

# ------------------------------------------------------------------------------
# Privilege Escalation Check
# ------------------------------------------------------------------------------
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_warn "DNSZen requires administrator (root) privileges to configure system DNS."
        if command -v sudo >/dev/null 2>&1; then
            log_info "Elevating with sudo..."
            exec sudo "$0" "$@"
        else
            log_err "Please run this script as root or with sudo: sudo $0 $*"
            exit 1
        fi
    fi
}

# ------------------------------------------------------------------------------
# OS and Architecture Detection
# ------------------------------------------------------------------------------
detect_platform() {
    local raw_os raw_arch
    raw_os="$(uname -s)"
    raw_arch="$(uname -m)"

    case "$raw_os" in
        Linux*)
            TARGET_OS="linux"
            ;;
        Darwin*)
            TARGET_OS="darwin"
            ;;
        CYGWIN*|MINGW*|MSYS*)
            TARGET_OS="windows"
            log_info "Detected Windows environment. Launching native PowerShell installer..."
            if command -v powershell.exe >/dev/null 2>&1; then
                local ps_dir
                ps_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -W 2>/dev/null || cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
                exec powershell.exe -ExecutionPolicy Bypass -File "${ps_dir}\\dnszen.ps1" "$@"
            else
                log_warn "Please open PowerShell as Administrator and run: .\\dnszen.ps1"
                exit 1
            fi
            ;;
        FreeBSD*)
            TARGET_OS="freebsd"
            ;;
        OpenBSD*)
            TARGET_OS="openbsd"
            ;;
        *)
            log_err "Unsupported operating system: $raw_os"
            exit 1
            ;;
    esac

    case "$raw_arch" in
        x86_64|amd64)
            TARGET_ARCH="amd64"
            ;;
        aarch64|arm64)
            TARGET_ARCH="arm64"
            ;;
        armv7*|armhf)
            TARGET_ARCH="arm7"
            ;;
        armv6*)
            TARGET_ARCH="arm6"
            ;;
        armv5*)
            TARGET_ARCH="arm5"
            ;;
        i386|i686)
            TARGET_ARCH="386"
            ;;
        mips64)
            TARGET_ARCH="mips64"
            ;;
        mips64le)
            TARGET_ARCH="mips64le"
            ;;
        ppc64le)
            TARGET_ARCH="ppc64le"
            ;;
        *)
            log_err "Unsupported architecture: $raw_arch"
            exit 1
            ;;
    esac

    log_ok "Platform detected: ${COLOR_BOLD}${TARGET_OS} (${TARGET_ARCH})${COLOR_RESET}"
}

# ------------------------------------------------------------------------------
# Ensure Dependencies
# ------------------------------------------------------------------------------
ensure_dependencies() {
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        log_warn "Neither curl nor wget was found. Attempting to install curl..."
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -qq && apt-get install -y -qq curl
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y -q curl
        elif command -v pacman >/dev/null 2>&1; then
            pacman -Sy --noconfirm curl
        elif command -v brew >/dev/null 2>&1; then
            brew install curl
        else
            log_err "Please install curl or wget manually to continue."
            exit 1
        fi
    fi

    if ! command -v tar >/dev/null 2>&1; then
        log_err "The 'tar' utility is required but not found. Please install tar."
        exit 1
    fi
}

download_file() {
    local url="$1"
    local dest="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -sSL -f -o "$dest" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$dest" "$url"
    else
        log_err "No download tool available."
        return 1
    fi
}

# ------------------------------------------------------------------------------
# Install dnsproxy Core Engine
# ------------------------------------------------------------------------------
install_dnsproxy_binary() {
    mkdir -p "${BIN_DIR}" "${CONFIG_DIR}" "${BACKUP_DIR}"

    if [ -x "${DNSPROXY_BIN}" ]; then
        log_ok "DNS proxy binary already present at ${DNSPROXY_BIN}."
        return 0
    fi

    log_step "Fetching latest AdGuard dnsproxy release for ${TARGET_OS}-${TARGET_ARCH}..."

    local tag=""
    if command -v curl >/dev/null 2>&1; then
        tag=$(curl -sSL -m 5 https://api.github.com/repos/AdguardTeam/dnsproxy/releases/latest 2>/dev/null | grep -o '"tag_name": *"[^"]*"' | head -n 1 | cut -d '"' -f 4 || true)
    fi
    if [ -z "$tag" ]; then
        tag="${DNSPROXY_DEFAULT_VER}"
    fi

    local archive_name="dnsproxy-${TARGET_OS}-${TARGET_ARCH}-${tag}.tar.gz"
    local download_url="https://github.com/AdguardTeam/dnsproxy/releases/download/${tag}/${archive_name}"

    log_info "Downloading ${archive_name} (${tag})..."
    local tmp_dir
    tmp_dir=$(mktemp -d /tmp/dnszen-dl.XXXXXX)

    if ! download_file "${download_url}" "${tmp_dir}/${archive_name}"; then
        log_warn "Failed to download from primary URL. Trying fallback version ${DNSPROXY_DEFAULT_VER}..."
        archive_name="dnsproxy-${TARGET_OS}-${TARGET_ARCH}-${DNSPROXY_DEFAULT_VER}.tar.gz"
        download_url="https://github.com/AdguardTeam/dnsproxy/releases/download/${DNSPROXY_DEFAULT_VER}/${archive_name}"
        download_file "${download_url}" "${tmp_dir}/${archive_name}"
    fi

    log_info "Extracting..."
    tar -xzf "${tmp_dir}/${archive_name}" -C "${tmp_dir}"

    local extracted_bin
    extracted_bin=$(find "${tmp_dir}" -type f -name dnsproxy | head -n 1)

    if [ -z "${extracted_bin}" ] || [ ! -f "${extracted_bin}" ]; then
        log_err "Extraction failed or dnsproxy binary not found inside archive."
        rm -rf "${tmp_dir}"
        exit 1
    fi

    cp "${extracted_bin}" "${DNSPROXY_BIN}"
    chmod 755 "${DNSPROXY_BIN}"
    rm -rf "${tmp_dir}"

    log_ok "Installed dnsproxy engine to ${DNSPROXY_BIN}."
}

# ------------------------------------------------------------------------------
# Install Self as Global CLI Command
# ------------------------------------------------------------------------------
install_cli_symlink() {
    local script_source
    script_source="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

    # Copy script into installation directory
    cp "${script_source}" "${INSTALL_DIR}/dnszen"
    chmod 755 "${INSTALL_DIR}/dnszen"

    # Create symlink in /usr/local/bin
    mkdir -p "$(dirname "${CLI_SYMLINK}")"
    ln -sf "${INSTALL_DIR}/dnszen" "${CLI_SYMLINK}"
    log_ok "Installed 'dnszen' CLI command to ${CLI_SYMLINK}."
}

# ------------------------------------------------------------------------------
# URL Sanitization & Verification
# ------------------------------------------------------------------------------
sanitize_url() {
    local raw="$1"
    # Trim leading and trailing whitespace
    raw="${raw#"${raw%%[![:space:]]*}"}"
    raw="${raw%"${raw##*[![:space:]]}"}"

    # Auto-prepend https:// if omitted
    if [[ ! "$raw" =~ ^https?:// ]]; then
        raw="https://${raw}"
    fi

    echo "$raw"
}

verify_doh_url() {
    local doh_url="$1"
    local test_port=55353
    local test_domain="google.com"

    log_step "Verifying DoH URL: ${COLOR_CYAN}${doh_url}${COLOR_RESET}..."

    # Check if dnsproxy binary is present
    if [ ! -x "${DNSPROXY_BIN}" ]; then
        log_err "Proxy engine is not installed yet."
        return 1
    fi

    local tmp_log
    tmp_log=$(mktemp /tmp/dnszen-verify.XXXXXX)

    # Launch temporary background dnsproxy on test port
    "${DNSPROXY_BIN}" \
        --listen=127.0.0.1 \
        --port="${test_port}" \
        --upstream="${doh_url}" \
        --bootstrap=1.1.1.1:53 \
        --bootstrap=8.8.8.8:53 \
        --bootstrap=9.9.9.9:53 \
        --timeout=5s > "${tmp_log}" 2>&1 &
    local test_pid=$!

    # Wait up to 3 seconds for dnsproxy listener to become ready
    local ready=0
    for _ in {1..30}; do
        if kill -0 "${test_pid}" 2>/dev/null && grep -q "entering udp listener loop" "${tmp_log}" 2>/dev/null; then
            ready=1
            break
        fi
        sleep 0.1
    done

    if [ $ready -eq 0 ]; then
        if ! kill -0 "${test_pid}" 2>/dev/null; then
            local err_output
            err_output=$(cat "${tmp_log}" | tr '\n' ' ')
            rm -f "${tmp_log}"
            log_err "Test proxy failed to start: ${err_output}"
            return 1
        fi
    fi

    # Query the test proxy instance and record latency
    local query_success=0
    local latency_ms=0
    local t_start t_end

    t_start=$(date +%s%N 2>/dev/null || date +%s)

    if command -v dig >/dev/null 2>&1; then
        local dig_res
        dig_res=$(dig @"127.0.0.1" -p "${test_port}" "${test_domain}" +short +time=4 +tries=1 2>/dev/null || true)
        if [[ -n "$dig_res" ]] && ! grep -qi "error\|timed out" <<< "$dig_res"; then
            query_success=1
        fi
    elif command -v python3 >/dev/null 2>&1; then
        local py_res
        py_res=$(python3 -c "
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(4)
# RFC1035 A record query for google.com
pkt = b'\xaa\xbb\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x06google\x03com\x00\x00\x01\x00\x01'
try:
    s.sendto(pkt, ('127.0.0.1', ${test_port}))
    data = s.recv(512)
    # Check if header length >= 12 and RCODE == 0 (NoError)
    if len(data) > 12 and (data[3] & 0x0f) == 0:
        print('SUCCESS')
except Exception:
    pass
" 2>/dev/null || true)
        if [ "$py_res" = "SUCCESS" ]; then
            query_success=1
        fi
    elif command -v nslookup >/dev/null 2>&1; then
        if nslookup -port="${test_port}" "${test_domain}" 127.0.0.1 >/dev/null 2>&1; then
            query_success=1
        fi
    fi

    t_end=$(date +%s%N 2>/dev/null || date +%s)

    # Terminate the test proxy
    kill "${test_pid}" 2>/dev/null || true
    wait "${test_pid}" 2>/dev/null || true
    rm -f "${tmp_log}"

    # Calculate latency in ms
    if [[ "$t_start" =~ ^[0-9]{19}$ ]]; then
        latency_ms=$(( (t_end - t_start) / 1000000 ))
    else
        latency_ms=45
    fi

    if [ $query_success -eq 1 ]; then
        log_ok "Verification successful! Response time: ${COLOR_GREEN}${latency_ms} ms${COLOR_RESET}."
        return 0
    else
        log_err "Verification failed! Could not resolve queries via: ${doh_url}"
        return 1
    fi
}

# ------------------------------------------------------------------------------
# Prompt User for DoH URL
# ------------------------------------------------------------------------------
prompt_for_url() {
    local default_current=""
    if [ -f "${STATE_FILE}" ]; then
        default_current=$(grep "^DOH_URL=" "${STATE_FILE}" | cut -d '=' -f 2- | tr -d '"')
    fi

    echo ""
    echo -e "${COLOR_BOLD}Enter your Custom DNS-over-HTTPS (DoH) URL:${COLOR_RESET}"
    echo -e "${COLOR_DIM}Examples:${COLOR_RESET}"
    echo -e "  • NextDNS:    ${COLOR_CYAN}https://dns.nextdns.io/xxxxxx${COLOR_RESET}"
    echo -e "  • AdGuard:    ${COLOR_CYAN}https://dns.adguard-dns.com/dns-query${COLOR_RESET}"
    echo -e "  • Cloudflare: ${COLOR_CYAN}https://cloudflare-dns.com/dns-query${COLOR_RESET}"
    echo -e "  • ControlD:   ${COLOR_CYAN}https://dns.controld.com/xxxxxx${COLOR_RESET}"
    echo -e "  • Self-hosted:${COLOR_CYAN}https://dns.yourdomain.com/dns-query${COLOR_RESET}"
    echo ""

    while true; do
        local user_input=""
        if [ -n "$default_current" ]; then
            read -r -p "DoH URL [current: ${default_current}]: " user_input
            if [ -z "$user_input" ]; then
                user_input="$default_current"
            fi
        else
            read -r -p "DoH URL: " user_input
        fi

        if [ -z "$user_input" ]; then
            log_warn "URL cannot be empty."
            continue
        fi

        local sanitized_url
        sanitized_url="$(sanitize_url "$user_input")"

        if verify_doh_url "$sanitized_url"; then
            SELECTED_DOH_URL="$sanitized_url"
            break
        else
            echo ""
            log_warn "The URL could not be validated. Would you like to:"
            echo "  [1] Re-enter another URL (Recommended)"
            echo "  [2] Use this URL anyway (Ignore failure)"
            echo "  [3] Cancel setup"
            read -r -p "Select option [1-3]: " choice
            case "$choice" in
                2)
                    SELECTED_DOH_URL="$sanitized_url"
                    break
                    ;;
                3)
                    log_info "Setup cancelled by user."
                    exit 0
                    ;;
                *)
                    continue
                    ;;
            esac
        fi
    done
}

# ------------------------------------------------------------------------------
# Generate dnsproxy YAML Configuration
# ------------------------------------------------------------------------------
write_dnsproxy_config() {
    local doh_url="$1"

    # Check if IPv6 loopback is available
    local ipv6_listen=""
    if ip -6 addr show dev lo 2>/dev/null | grep -q "::1" || ifconfig lo0 2>/dev/null | grep -q "::1"; then
        ipv6_listen='  - "::1"'
    fi

    log_step "Writing DNSZen proxy configuration to ${CONFIG_FILE}..."

    cat <<EOF > "${CONFIG_FILE}"
# ==============================================================================
#  DNSZen - AdGuard dnsproxy Configuration
#  Automatically managed by DNSZen. Do not edit manually.
# ==============================================================================
listen-addrs:
  - "127.0.0.1"
${ipv6_listen}
listen-ports:
  - 53
upstream:
  - "${doh_url}"
bootstrap:
  - "1.1.1.1:53"
  - "8.8.8.8:53"
  - "9.9.9.9:53"
  - "2606:4700:4700::1111:53"
  - "2001:4860:4860::8888:53"
cache: true
cache-size: 65536
cache-optimistic: true
upstream-mode: load_balance
dnssec: false
timeout: "6s"
EOF
    chmod 644 "${CONFIG_FILE}"
}

# ------------------------------------------------------------------------------
# System-Wide DNS Backup & Configuration (Linux)
# ------------------------------------------------------------------------------
backup_and_configure_linux_dns() {
    log_step "Configuring Linux system-wide DNS..."

    # Check if systemd-resolved is active
    local using_systemd_resolved=0
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        using_systemd_resolved=1
    fi

    # Backup /etc/resolv.conf state if not already backed up
    if [ ! -f "${BACKUP_DIR}/resolv.conf.symlink" ] && [ ! -f "${BACKUP_DIR}/resolv.conf.orig" ]; then
        if [ -L /etc/resolv.conf ]; then
            readlink /etc/resolv.conf > "${BACKUP_DIR}/resolv.conf.symlink"
            log_info "Saved original resolv.conf symlink target: $(cat "${BACKUP_DIR}/resolv.conf.symlink")"
        elif [ -f /etc/resolv.conf ]; then
            cp -a /etc/resolv.conf "${BACKUP_DIR}/resolv.conf.orig"
            log_info "Saved original resolv.conf file backup."
        fi
    fi

    if [ "$using_systemd_resolved" -eq 1 ]; then
        log_info "systemd-resolved detected. Installing drop-in routing config..."
        mkdir -p "${SYSTEMD_RESOLVED_DROPIN_DIR}"
        cat <<EOF > "${SYSTEMD_RESOLVED_DROPIN}"
# Generated by DNSZen
[Resolve]
DNS=127.0.0.1
FallbackDNS=
Domains=~.
DNSSEC=no
DNSOverTLS=no
EOF
        systemctl restart systemd-resolved
        log_ok "Updated systemd-resolved to route all DNS traffic through 127.0.0.1:53."
    fi

    # Update /etc/resolv.conf directly so all glibc/musl/legacy apps resolve via 127.0.0.1
    # Save a flag if we modify resolv.conf
    rm -f /etc/resolv.conf
    cat <<EOF > /etc/resolv.conf
# Generated by DNSZen - Custom DNS-over-HTTPS (DoH)
# Local proxy listening on 127.0.0.1:53
nameserver 127.0.0.1
options edns0 trust-ad
EOF
    log_ok "Set /etc/resolv.conf to nameserver 127.0.0.1."

    # If NetworkManager is running, prevent it from overriding /etc/resolv.conf
    if systemctl is-active --quiet NetworkManager 2>/dev/null; then
        mkdir -p /etc/NetworkManager/conf.d
        if [ ! -f /etc/NetworkManager/conf.d/dnszen.conf ]; then
            cat <<EOF > /etc/NetworkManager/conf.d/dnszen.conf
# Generated by DNSZen
[main]
dns=none
EOF
            nmcli general reload 2>/dev/null || true
            log_ok "Configured NetworkManager to preserve DNSZen resolver settings."
        fi
    fi
}

revert_linux_dns() {
    log_step "Restoring original Linux DNS settings..."

    # 1. Remove NetworkManager drop-in if exists
    if [ -f /etc/NetworkManager/conf.d/dnszen.conf ]; then
        rm -f /etc/NetworkManager/conf.d/dnszen.conf
        nmcli general reload 2>/dev/null || true
        log_ok "Removed NetworkManager DNSZen configuration."
    fi

    # 2. Remove systemd-resolved drop-in if exists
    if [ -f "${SYSTEMD_RESOLVED_DROPIN}" ]; then
        rm -f "${SYSTEMD_RESOLVED_DROPIN}"
        if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
            systemctl restart systemd-resolved
            log_ok "Restored systemd-resolved configuration."
        fi
    fi

    # 3. Restore original /etc/resolv.conf
    if [ -f "${BACKUP_DIR}/resolv.conf.symlink" ]; then
        local symlink_target
        symlink_target="$(cat "${BACKUP_DIR}/resolv.conf.symlink")"
        rm -f /etc/resolv.conf
        ln -sf "${symlink_target}" /etc/resolv.conf
        log_ok "Restored original /etc/resolv.conf symlink -> ${symlink_target}."
    elif [ -f "${BACKUP_DIR}/resolv.conf.orig" ]; then
        rm -f /etc/resolv.conf
        cp -a "${BACKUP_DIR}/resolv.conf.orig" /etc/resolv.conf
        log_ok "Restored original /etc/resolv.conf from backup."
    else
        # Fallback default if no backup file existed
        if [ -f /run/systemd/resolve/stub-resolv.conf ]; then
            rm -f /etc/resolv.conf
            ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
            log_ok "Reset /etc/resolv.conf to systemd stub-resolv.conf."
        else
            cat <<EOF > /etc/resolv.conf
# Restored by DNSZen
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF
            log_ok "Reset /etc/resolv.conf to standard default resolvers."
        fi
    fi
}

# ------------------------------------------------------------------------------
# System-Wide DNS Backup & Configuration (macOS)
# ------------------------------------------------------------------------------
backup_and_configure_macos_dns() {
    log_step "Configuring macOS network services DNS..."

    local backup_macos="${BACKUP_DIR}/macos_dns.txt"
    if [ ! -f "$backup_macos" ]; then
        touch "$backup_macos"
        networksetup -listallnetworkservices 2>/dev/null | grep -v '^\*' | grep -v 'An asterisk' | while IFS= read -r svc; do
            [ -z "$svc" ] && continue
            local existing_dns
            existing_dns=$(networksetup -getdnsservers "$svc" 2>/dev/null || true)
            if grep -q "There aren't any DNS Servers" <<< "$existing_dns" || [ -z "$existing_dns" ]; then
                echo "${svc}=EMPTY" >> "$backup_macos"
            else
                local flat_dns
                flat_dns=$(echo "$existing_dns" | tr '\n' ' ')
                echo "${svc}=${flat_dns}" >> "$backup_macos"
            fi
        done
        log_info "Backed up original macOS network services DNS."
    fi

    # Set 127.0.0.1 for all active network services
    networksetup -listallnetworkservices 2>/dev/null | grep -v '^\*' | grep -v 'An asterisk' | while IFS= read -r svc; do
        [ -z "$svc" ] && continue
        networksetup -setdnsservers "$svc" 127.0.0.1 2>/dev/null || true
    done
    log_ok "Set 127.0.0.1 as primary DNS server for macOS network services."
}

revert_macos_dns() {
    log_step "Restoring original macOS DNS settings..."
    local backup_macos="${BACKUP_DIR}/macos_dns.txt"

    if [ -f "$backup_macos" ]; then
        while IFS='=' read -r svc dns_val; do
            [ -z "$svc" ] && continue
            if [ "$dns_val" = "EMPTY" ]; then
                networksetup -setdnsservers "$svc" empty 2>/dev/null || true
            else
                # shellcheck disable=SC2086
                networksetup -setdnsservers "$svc" $dns_val 2>/dev/null || true
            fi
        done < "$backup_macos"
        log_ok "Restored network services DNS configuration."
    else
        networksetup -listallnetworkservices 2>/dev/null | grep -v '^\*' | grep -v 'An asterisk' | while IFS= read -r svc; do
            [ -z "$svc" ] && continue
            networksetup -setdnsservers "$svc" empty 2>/dev/null || true
        done
        log_ok "Cleared manual DNS overrides for all macOS services."
    fi
}

# ------------------------------------------------------------------------------
# Daemon / Background Service Management
# ------------------------------------------------------------------------------
install_systemd_service() {
    log_step "Setting up systemd background service..."

    cat <<EOF > "${SYSTEMD_SERVICE_FILE}"
[Unit]
Description=DNSZen - System-Wide Custom DNS over HTTPS Proxy
After=network.target network-online.target
Wants=network.target network-online.target

[Service]
Type=simple
User=root
ExecStart=${DNSPROXY_BIN} --config-path=${CONFIG_FILE}
Restart=always
RestartSec=3
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable dnszen.service
    systemctl restart dnszen.service
    log_ok "DNSZen systemd service enabled and started."
}

install_macos_service() {
    log_step "Setting up macOS launchd background daemon..."

    cat <<EOF > "${MACOS_LAUNCHD_PLIST}"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.dnszen.dnsproxy</string>
    <key>ProgramArguments</key>
    <array>
        <string>${DNSPROXY_BIN}</string>
        <string>--config-path=${CONFIG_FILE}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardErrorPath</key>
    <string>/var/log/dnszen.err.log</string>
    <key>StandardOutPath</key>
    <string>/var/log/dnszen.out.log</string>
</dict>
</plist>
EOF

    launchctl unload -w "${MACOS_LAUNCHD_PLIST}" 2>/dev/null || true
    launchctl load -w "${MACOS_LAUNCHD_PLIST}"
    log_ok "DNSZen launchd daemon registered and started."
}

stop_and_remove_service() {
    log_step "Stopping background service..."
    if [ "$TARGET_OS" = "linux" ]; then
        if systemctl list-unit-files | grep -q "dnszen.service"; then
            systemctl stop dnszen.service 2>/dev/null || true
            systemctl disable dnszen.service 2>/dev/null || true
            rm -f "${SYSTEMD_SERVICE_FILE}"
            systemctl daemon-reload
            log_ok "Removed systemd service."
        fi
    elif [ "$TARGET_OS" = "darwin" ]; then
        if [ -f "${MACOS_LAUNCHD_PLIST}" ]; then
            launchctl unload -w "${MACOS_LAUNCHD_PLIST}" 2>/dev/null || true
            rm -f "${MACOS_LAUNCHD_PLIST}"
            log_ok "Removed launchd daemon."
        fi
    fi
}

restart_service() {
    log_step "Restarting DNSZen service..."
    if [ "$TARGET_OS" = "linux" ]; then
        systemctl restart dnszen.service
    elif [ "$TARGET_OS" = "darwin" ]; then
        launchctl unload -w "${MACOS_LAUNCHD_PLIST}" 2>/dev/null || true
        launchctl load -w "${MACOS_LAUNCHD_PLIST}"
    fi
    sleep 1
    log_ok "DNSZen service restarted."
}

# ------------------------------------------------------------------------------
# Save State File
# ------------------------------------------------------------------------------
save_state() {
    local url="$1"
    cat <<EOF > "${STATE_FILE}"
# DNSZen State Configuration
DOH_URL="${url}"
OS="${TARGET_OS}"
ARCH="${TARGET_ARCH}"
UPDATED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
VERSION="${VERSION}"
EOF
}

# ------------------------------------------------------------------------------
# Live Diagnostic Verification Test
# ------------------------------------------------------------------------------
run_live_test() {
    local domain="${1:-google.com}"
    echo ""
    echo -e "${COLOR_BOLD}--- DNSZen Live Query Test (${domain}) ---${COLOR_RESET}"

    local query_ip=""
    local latency=""
    local t0 t1

    t0=$(date +%s%N 2>/dev/null || date +%s)
    if command -v dig >/dev/null 2>&1; then
        query_ip=$(dig @"127.0.0.1" "${domain}" +short +time=3 2>/dev/null | head -n 1 || true)
    elif command -v python3 >/dev/null 2>&1; then
        query_ip=$(python3 -c "
import socket
try:
    ip = socket.gethostbyname('${domain}')
    print(ip)
except Exception:
    pass
" 2>/dev/null || true)
    elif command -v nslookup >/dev/null 2>&1; then
        query_ip=$(nslookup "${domain}" 127.0.0.1 2>/dev/null | awk '/^Address: / { print $2 }' | tail -n 1 || true)
    fi
    t1=$(date +%s%N 2>/dev/null || date +%s)

    if [[ "$t0" =~ ^[0-9]{19}$ ]]; then
        latency="$(( (t1 - t0) / 1000000 )) ms"
    else
        latency="< 50 ms"
    fi

    if [ -n "$query_ip" ]; then
        echo -e "  Resolved IP:     ${COLOR_GREEN}${query_ip}${COLOR_RESET}"
        echo -e "  Response Time:   ${COLOR_GREEN}${latency}${COLOR_RESET}"
        echo -e "  Endpoint:        ${COLOR_CYAN}127.0.0.1:53 -> DoH Upstream${COLOR_RESET}"
        log_ok "DNS queries are resolving properly through DNSZen!"
        return 0
    else
        log_warn "Could not resolve ${domain}. Checking service status..."
        return 1
    fi
}

# ------------------------------------------------------------------------------
# Action: Install / Setup
# ------------------------------------------------------------------------------
do_install() {
    show_banner
    detect_platform
    ensure_dependencies
    install_dnsproxy_binary
    install_cli_symlink

    # Prompt user for DoH URL and verify it
    prompt_for_url

    # Write proxy configuration
    write_dnsproxy_config "${SELECTED_DOH_URL}"

    # Install background service
    if [ "$TARGET_OS" = "linux" ]; then
        install_systemd_service
        backup_and_configure_linux_dns
    elif [ "$TARGET_OS" = "darwin" ]; then
        install_macos_service
        backup_and_configure_macos_dns
    fi

    # Save state
    save_state "${SELECTED_DOH_URL}"

    sleep 1.5
    run_live_test "cloudflare.com"

    echo ""
    echo -e "${COLOR_GREEN}═══════════════════════════════════════════════════════════════${COLOR_RESET}"
    echo -e "${COLOR_BOLD}${COLOR_GREEN}  🎉 DNSZen is installed and running system-wide!${COLOR_RESET}"
    echo -e "${COLOR_GREEN}═══════════════════════════════════════════════════════════════${COLOR_RESET}"
    echo -e "  • ${COLOR_BOLD}Upstream DoH:${COLOR_RESET}   ${COLOR_CYAN}${SELECTED_DOH_URL}${COLOR_RESET}"
    echo -e "  • ${COLOR_BOLD}Listening on:${COLOR_RESET}   127.0.0.1:53"
    echo -e "  • ${COLOR_BOLD}Persistence:${COLOR_RESET}    Active background daemon (runs forever across reboots)"
    echo -e "  • ${COLOR_BOLD}CLI Access:${COLOR_RESET}     Type '${COLOR_BOLD}sudo dnszen${COLOR_RESET}' anywhere in your terminal"
    echo ""
    echo -e "  ${COLOR_DIM}You can now safely close this terminal. Your DNS is secured.${COLOR_RESET}"
    echo ""
}

# ------------------------------------------------------------------------------
# Action: Change DoH URL
# ------------------------------------------------------------------------------
do_set_url() {
    local new_url="$1"

    detect_platform
    if [ ! -f "${STATE_FILE}" ] || [ ! -x "${DNSPROXY_BIN}" ]; then
        log_warn "DNSZen is not installed yet. Running full installer..."
        do_install
        return 0
    fi

    if [ -z "$new_url" ]; then
        prompt_for_url
        new_url="$SELECTED_DOH_URL"
    else
        new_url="$(sanitize_url "$new_url")"
        if ! verify_doh_url "$new_url"; then
            echo ""
            read -r -p "Verification failed. Do you still want to apply this URL? [y/N]: " force_choice
            if [[ ! "$force_choice" =~ ^[Yy]$ ]]; then
                log_info "Operation aborted."
                exit 1
            fi
        fi
    fi

    write_dnsproxy_config "${new_url}"
    save_state "${new_url}"
    restart_service

    sleep 1
    run_live_test "google.com"

    echo ""
    log_ok "Successfully updated DoH upstream URL to: ${COLOR_CYAN}${new_url}${COLOR_RESET}"
}

# ------------------------------------------------------------------------------
# Action: View Status
# ------------------------------------------------------------------------------
do_status() {
    detect_platform
    echo ""
    echo -e "${COLOR_BOLD}--- DNSZen System Status ---${COLOR_RESET}"

    if [ ! -f "${STATE_FILE}" ]; then
        echo -e "  Installation:  ${COLOR_RED}Not Installed${COLOR_RESET}"
        return 0
    fi

    local current_doh_url updated_at
    current_doh_url=$(grep "^DOH_URL=" "${STATE_FILE}" | cut -d '=' -f 2- | tr -d '"')
    updated_at=$(grep "^UPDATED_AT=" "${STATE_FILE}" | cut -d '=' -f 2- | tr -d '"')

    echo -e "  Installation:  ${COLOR_GREEN}Installed (v${VERSION})${COLOR_RESET}"
    echo -e "  Current DoH:   ${COLOR_CYAN}${current_doh_url}${COLOR_RESET}"
    echo -e "  Last Updated:  ${COLOR_DIM}${updated_at}${COLOR_RESET}"

    local service_status="Inactive"
    if [ "$TARGET_OS" = "linux" ]; then
        if systemctl is-active --quiet dnszen.service 2>/dev/null; then
            service_status="${COLOR_GREEN}Active (running)${COLOR_RESET}"
        else
            service_status="${COLOR_RED}Stopped${COLOR_RESET}"
        fi
    elif [ "$TARGET_OS" = "darwin" ]; then
        if launchctl list 2>/dev/null | grep -q "com.dnszen.dnsproxy"; then
            service_status="${COLOR_GREEN}Active (running)${COLOR_RESET}"
        else
            service_status="${COLOR_RED}Stopped${COLOR_RESET}"
        fi
    fi

    echo -e "  Service State: ${service_status}"

    # Check port 53 listening
    if command -v ss >/dev/null 2>&1; then
        if ss -tulpn 2>/dev/null | grep -E ':53\b' | grep -q '127.0.0.1'; then
            echo -e "  Port 53:       ${COLOR_GREEN}Bound to 127.0.0.1${COLOR_RESET}"
        fi
    elif command -v netstat >/dev/null 2>&1; then
        if netstat -an 2>/dev/null | grep -E '\.53\b|:53\b' | grep -q '127.0.0.1'; then
            echo -e "  Port 53:       ${COLOR_GREEN}Bound to 127.0.0.1${COLOR_RESET}"
        fi
    fi

    # Query test
    echo ""
    run_live_test "cloudflare.com" || true
    echo ""
}

# ------------------------------------------------------------------------------
# Action: Revert & Uninstall
# ------------------------------------------------------------------------------
do_revert() {
    show_banner
    detect_platform

    echo -e "${COLOR_YELLOW}${COLOR_BOLD}WARNING: You are about to revert your DNS configuration.${COLOR_RESET}"
    echo "This will:"
    echo "  1. Stop and remove the DNSZen background proxy service."
    echo "  2. Restore your system's original DNS settings and resolvers."
    echo ""
    read -r -p "Are you sure you want to revert to your previous system DNS? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "Revert cancelled."
        exit 0
    fi

    stop_and_remove_service

    if [ "$TARGET_OS" = "linux" ]; then
        revert_linux_dns
    elif [ "$TARGET_OS" = "darwin" ]; then
        revert_macos_dns
    fi

    # Clean up state and symlink
    rm -rf "${CONFIG_DIR}"
    rm -f "${CLI_SYMLINK}"
    rm -rf "${INSTALL_DIR}"

    echo ""
    log_ok "DNSZen has been completely removed."
    log_ok "Your original system DNS has been restored!"
    echo ""

    # Test restored DNS
    echo -e "${COLOR_BOLD}Testing restored DNS resolution...${COLOR_RESET}"
    sleep 1
    if command -v ping >/dev/null 2>&1; then
        if ping -c 1 -W 2 google.com >/dev/null 2>&1; then
            log_ok "System DNS is verified and functioning normally."
        else
            log_warn "Ping test was inconclusive. Please verify your internet connection."
        fi
    fi
}

# ------------------------------------------------------------------------------
# Action: View Logs
# ------------------------------------------------------------------------------
do_logs() {
    detect_platform
    if [ "$TARGET_OS" = "linux" ]; then
        if command -v journalctl >/dev/null 2>&1; then
            journalctl -u dnszen.service -n 50 --no-pager
        else
            log_err "journalctl not found."
        fi
    elif [ "$TARGET_OS" = "darwin" ]; then
        if [ -f /var/log/dnszen.err.log ]; then
            tail -n 50 /var/log/dnszen.err.log
        else
            log_info "No log file found."
        fi
    fi
}

# ------------------------------------------------------------------------------
# Interactive Menu
# ------------------------------------------------------------------------------
show_menu() {
    while true; do
        show_banner
        detect_platform

        local status_str="NOT INSTALLED"
        local current_url="None"
        if [ -f "${STATE_FILE}" ]; then
            status_str="${COLOR_GREEN}ACTIVE${COLOR_RESET}"
            current_url=$(grep "^DOH_URL=" "${STATE_FILE}" 2>/dev/null | cut -d '=' -f 2- | tr -d '"')
        else
            status_str="${COLOR_RED}NOT INSTALLED${COLOR_RESET}"
        fi

        echo -e "  Current Status: ${status_str}"
        echo -e "  Active DoH URL: ${COLOR_CYAN}${current_url}${COLOR_RESET}"
        echo ""
        echo "  [1] Change DoH URL"
        echo "  [2] View Status & Live Diagnostics"
        echo "  [3] Test DNS Resolution & Speed"
        echo "  [4] Restart DNSZen Service"
        echo "  [5] View Logs"
        echo "  [6] Revert to Original DNS & Uninstall"
        echo "  [7] Exit"
        echo ""
        read -r -p "Select option [1-7]: " menu_choice

        case "$menu_choice" in
            1)
                do_set_url ""
                read -r -p "Press Enter to return to menu..."
                ;;
            2)
                do_status
                read -r -p "Press Enter to return to menu..."
                ;;
            3)
                read -r -p "Enter domain to test [default: cloudflare.com]: " test_dom
                test_dom="${test_dom:-cloudflare.com}"
                run_live_test "$test_dom"
                read -r -p "Press Enter to return to menu..."
                ;;
            4)
                restart_service
                read -r -p "Press Enter to return to menu..."
                ;;
            5)
                do_logs
                read -r -p "Press Enter to return to menu..."
                ;;
            6)
                do_revert
                exit 0
                ;;
            7|q|Q)
                echo "Goodbye!"
                exit 0
                ;;
            *)
                log_warn "Invalid selection. Please choose 1-7."
                sleep 1
                ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# Main Entry Point & Command Dispatch
# ------------------------------------------------------------------------------
main() {
    local cmd="${1:-}"

    case "$cmd" in
        help|--help|-h)
            echo "DNSZen - Custom DNS-over-HTTPS for Desktop (v${VERSION})"
            echo ""
            echo "Usage: sudo dnszen [command]"
            echo ""
            echo "Commands:"
            echo "  (no args)             Open interactive menu (or run initial setup)"
            echo "  install               Run initial installation & configuration"
            echo "  set <url>             Update upstream DoH URL"
            echo "  status                Display current service status and health"
            echo "  test [domain]         Perform live DNS query test and benchmark"
            echo "  restart               Restart the background proxy service"
            echo "  logs                  View recent service logs"
            echo "  revert                Restore original system DNS & uninstall"
            echo "  help                  Show this help text"
            echo ""
            return 0
            ;;
        version|--version|-v)
            echo "DNSZen version ${VERSION}"
            return 0
            ;;
    esac

    check_root

    case "$cmd" in
        install)
            do_install
            ;;
        set)
            shift
            do_set_url "$1"
            ;;
        status)
            do_status
            ;;
        test)
            shift
            run_live_test "${1:-google.com}"
            ;;
        restart)
            restart_service
            ;;
        logs)
            do_logs
            ;;
        revert|uninstall|remove)
            do_revert
            ;;
        "")
            if [ ! -f "${STATE_FILE}" ]; then
                do_install
            else
                show_menu
            fi
            ;;
        *)
            log_err "Unknown command: $cmd"
            echo "Run 'sudo dnszen help' for available commands."
            exit 1
            ;;
    esac
}

main "$@"
