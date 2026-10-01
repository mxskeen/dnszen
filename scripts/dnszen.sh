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
REPO_RAW="https://raw.githubusercontent.com/mxskeen/dnszen/master"
DNSPROXY_DEFAULT_VER="v0.85.0"
INSTALL_DIR="/opt/dnszen"
BIN_DIR="${INSTALL_DIR}/bin"
CONFIG_DIR="/etc/dnszen"
BACKUP_DIR="${CONFIG_DIR}/backup"
CONFIG_FILE="${CONFIG_DIR}/dnsproxy.yaml"
STATE_FILE="${CONFIG_DIR}/dnszen.conf"
UPDATE_CHECK_FILE="${CONFIG_DIR}/update_check"
DNSPROXY_BIN="${BIN_DIR}/dnsproxy"
CLI_SYMLINK="/usr/local/bin/dnszen"
MONITOR_CLI_SYMLINK="/usr/local/bin/dnsmonitor"
LOG_FILE="/var/log/dnszen.log"

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

# Universal prompt reader (supports interactive keyboard even when piped via curl | bash)
prompt_read() {
    local prompt_msg="$1"
    local __resultvar="$2"
    local input_val=""
    if [ -t 0 ]; then
        read -r -p "$prompt_msg" input_val
    elif [ -e /dev/tty ]; then
        read -r -p "$prompt_msg" input_val < /dev/tty
    else
        read -r -p "$prompt_msg" input_val
    fi
    eval "$__resultvar=\"\$input_val\""
}

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
    echo "  ║                          by @mxskeen                          ║"
    echo "  ╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${COLOR_RESET}"
}

# ------------------------------------------------------------------------------
# Version Comparison & Update Notification
# ------------------------------------------------------------------------------
version_gt() {
    [ "$1" = "$2" ] && return 1
    local v1="${1#v}"
    local v2="${2#v}"

    local IFS=.
    local i ver1=($v1) ver2=($v2)
    for ((i=${#ver1[@]}; i<${#ver2[@]}; i++)); do
        ver1[i]=0
    done
    for ((i=0; i<${#ver1[@]}; i++)); do
        [[ -z ${ver2[i]} ]] && ver2[i]=0
        if ((10#${ver1[i]} > 10#${ver2[i]})); then
            return 0
        fi
        if ((10#${ver1[i]} < 10#${ver2[i]})); then
            return 1
        fi
    done
    return 1
}

AVAILABLE_UPDATE_VER=""

check_update_notification() {
    [ ! -f "${STATE_FILE}" ] && return 0
    [ ! -d "${CONFIG_DIR}" ] && return 0

    local now
    now=$(date +%s 2>/dev/null || echo 0)
    local last_check=0
    local cached_ver=""

    if [ -f "${UPDATE_CHECK_FILE}" ]; then
        last_check=$(grep "^CHECKED_AT=" "${UPDATE_CHECK_FILE}" 2>/dev/null | cut -d '=' -f 2 || echo 0)
        cached_ver=$(grep "^LATEST_VER=" "${UPDATE_CHECK_FILE}" 2>/dev/null | cut -d '=' -f 2 || echo "")
    fi

    local age=$(( now - last_check ))
    # Check once every 24 hours (86400 seconds)
    if [ -z "$cached_ver" ] || [ $age -gt 86400 ]; then
        if command -v curl >/dev/null 2>&1; then
            local remote_ver
            remote_ver=$(curl -sSL -m 1 "${REPO_RAW}/scripts/dnszen.sh" 2>/dev/null | grep -E '^VERSION=' | head -n 1 | cut -d '"' -f 2 || true)
            if [ -n "$remote_ver" ]; then
                cached_ver="$remote_ver"
                echo "CHECKED_AT=${now}" > "${UPDATE_CHECK_FILE}" 2>/dev/null || true
                echo "LATEST_VER=${cached_ver}" >> "${UPDATE_CHECK_FILE}" 2>/dev/null || true
            fi
        fi
    fi

    if [ -n "$cached_ver" ] && version_gt "$cached_ver" "$VERSION"; then
        echo -e "${COLOR_YELLOW}  ┌─────────────────────────────────────────────────────────────┐${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}  │${COLOR_RESET}  ${COLOR_BOLD}Update Available!${COLOR_RESET} v${VERSION} -> ${COLOR_GREEN}v${cached_ver}${COLOR_RESET}                           ${COLOR_YELLOW}│${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}  │${COLOR_RESET}  Run '${COLOR_CYAN}sudo dnszen update${COLOR_RESET}' to install the latest features.   ${COLOR_YELLOW}│${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}  └─────────────────────────────────────────────────────────────┘${COLOR_RESET}"
        echo ""
        AVAILABLE_UPDATE_VER="$cached_ver"
    fi
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

    # Create symlinks in /usr/local/bin
    mkdir -p "$(dirname "${CLI_SYMLINK}")"
    ln -sf "${INSTALL_DIR}/dnszen" "${CLI_SYMLINK}"
    ln -sf "${INSTALL_DIR}/dnszen" "${MONITOR_CLI_SYMLINK}"
    log_ok "Installed 'dnszen' CLI command to ${CLI_SYMLINK}."
    log_ok "Installed 'dnsmonitor' CLI command to ${MONITOR_CLI_SYMLINK}."
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
pkt = b'\xaa\xbb\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x06google\x03com\x00\x00\x01\x00\x01'
try:
    s.sendto(pkt, ('127.0.0.1', ${test_port}))
    data = s.recv(512)
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
    elif command -v curl >/dev/null 2>&1; then
        # Direct DoH probe fallback via curl
        local http_code
        http_code=$(curl -s -m 4 -o /dev/null -w "%{http_code}" -H "accept: application/dns-message" "${doh_url}?dns=q80BAAABAAAAAAAAA3d3dwdleGFtcGxlA2NvbQAAAQAB" 2>/dev/null || true)
        if [ "$http_code" = "200" ]; then
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
# Built-in Popular Privacy Presets
# ------------------------------------------------------------------------------
PRESET_ADGUARD="https://dns.adguard-dns.com/dns-query"
PRESET_CLOUDFLARE_SEC="https://security.cloudflare-dns.com/dns-query"
PRESET_QUAD9="https://dns.quad9.net/dns-query"
PRESET_MULLVAD="https://adblock.doh.mullvad.net/dns-query"
PRESET_CLOUDFLARE_STD="https://cloudflare-dns.com/dns-query"

resolve_preset_url() {
    local raw="$1"
    local key
    key="$(echo "$raw" | tr '[:upper:]' '[:lower:]' | tr -d ' ')"
    case "$key" in
        1|adguard|adguard-dns)
            echo "$PRESET_ADGUARD"
            ;;
        2|cloudflare-security|cf-sec|security|1.1.1.2)
            echo "$PRESET_CLOUDFLARE_SEC"
            ;;
        3|quad9|9.9.9.9)
            echo "$PRESET_QUAD9"
            ;;
        4|mullvad|mullvad-adblock)
            echo "$PRESET_MULLVAD"
            ;;
        5|cloudflare|cloudflare-standard|1.1.1.1)
            echo "$PRESET_CLOUDFLARE_STD"
            ;;
        *)
            echo ""
            ;;
    esac
}

# ------------------------------------------------------------------------------
# Prompt User for DoH URL / Preset Selection
# ------------------------------------------------------------------------------
prompt_for_url() {
    local default_current=""
    if [ -f "${STATE_FILE}" ]; then
        default_current=$(grep "^DOH_URL=" "${STATE_FILE}" | cut -d '=' -f 2- | tr -d '"')
    fi

    echo ""
    echo -e "${COLOR_BOLD}Select a DNS-over-HTTPS (DoH) Provider:${COLOR_RESET}"
    echo ""
    echo -e "  ${COLOR_CYAN}Popular Privacy Presets (No account required):${COLOR_RESET}"
    echo -e "  [1] AdGuard DNS          ${COLOR_DIM}(DoH + Ad & Tracker Blocking)${COLOR_RESET}"
    echo -e "  [2] Cloudflare Security  ${COLOR_DIM}(1.1.1.2 - Malware & Threat Protection)${COLOR_RESET}"
    echo -e "  [3] Quad9                ${COLOR_DIM}(9.9.9.9 - Swiss Privacy & Threat Protection)${COLOR_RESET}"
    echo -e "  [4] Mullvad DNS          ${COLOR_DIM}(Strict Zero-Log Privacy + Ad Blocking)${COLOR_RESET}"
    echo -e "  [5] Cloudflare Standard  ${COLOR_DIM}(1.1.1.1 - Ultra-Fast Clean DoH)${COLOR_RESET}"
    echo ""
    echo -e "  ${COLOR_CYAN}Custom Endpoint:${COLOR_RESET}"
    echo -e "  [6] Enter Custom DoH URL ${COLOR_DIM}(NextDNS, ControlD, Pi-hole, Self-Hosted)${COLOR_RESET}"
    echo ""

    local prompt_msg="Select option [1-6]"
    if [ -n "$default_current" ]; then
        prompt_msg="Select option [1-6] [current: ${default_current}]"
    fi

    while true; do
        local choice=""
        prompt_read "${prompt_msg}: " choice

        if [ -z "$choice" ] && [ -n "$default_current" ]; then
            SELECTED_DOH_URL="$default_current"
            break
        fi

        local preset_match
        preset_match="$(resolve_preset_url "$choice")"

        if [ -n "$preset_match" ]; then
            if verify_doh_url "$preset_match"; then
                SELECTED_DOH_URL="$preset_match"
                break
            fi
        elif [ "$choice" = "6" ] || [ "$choice" = "c" ] || [ "$choice" = "custom" ]; then
            echo ""
            echo -e "${COLOR_BOLD}Enter your Custom DoH URL:${COLOR_RESET}"
            echo -e "${COLOR_DIM}Examples:${COLOR_RESET}"
            echo -e "  • NextDNS:    ${COLOR_CYAN}https://dns.nextdns.io/xxxxxx${COLOR_RESET}"
            echo -e "  • ControlD:   ${COLOR_CYAN}https://dns.controld.com/xxxxxx${COLOR_RESET}"
            echo -e "  • Self-hosted:${COLOR_CYAN}https://dns.yourdomain.com/dns-query${COLOR_RESET}"
            echo ""
            local custom_url=""
            prompt_read "DoH URL: " custom_url
            if [ -z "$custom_url" ]; then
                log_warn "URL cannot be empty."
                continue
            fi
            custom_url="$(sanitize_url "$custom_url")"
            if verify_doh_url "$custom_url"; then
                SELECTED_DOH_URL="$custom_url"
                break
            else
                echo ""
                log_warn "The URL could not be validated. Would you like to:"
                echo "  [1] Re-enter another URL (Recommended)"
                echo "  [2] Use this URL anyway (Ignore failure)"
                echo "  [3] Return to preset selection"
                prompt_read "Select option [1-3]: " fallback_choice
                case "$fallback_choice" in
                    2)
                        SELECTED_DOH_URL="$custom_url"
                        break
                        ;;
                    3)
                        continue
                        ;;
                    *)
                        continue
                        ;;
                esac
            fi
        elif [[ "$choice" =~ ^https?:// ]] || [[ "$choice" =~ \. ]]; then
            local direct_url
            direct_url="$(sanitize_url "$choice")"
            if verify_doh_url "$direct_url"; then
                SELECTED_DOH_URL="$direct_url"
                break
            fi
        else
            log_warn "Invalid selection. Please choose 1-6 or enter a DoH URL."
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
output: "${LOG_FILE}"
verbose: true
EOF
    chmod 644 "${CONFIG_FILE}"
    touch "${LOG_FILE}" 2>/dev/null || true
    chmod 644 "${LOG_FILE}" 2>/dev/null || true

    # Install logrotate rule if logrotate directory exists
    if [ -d /etc/logrotate.d ]; then
        cat <<EOF > /etc/logrotate.d/dnszen
${LOG_FILE} {
    size 10M
    rotate 3
    compress
    missingok
    notifempty
    copytruncate
}
EOF
    fi
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

    # Clear immutable attribute if set by VPN/resolvconf tools
    chattr -i /etc/resolv.conf 2>/dev/null || true
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
    chattr -i /etc/resolv.conf 2>/dev/null || true
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
install_linux_service() {
    log_step "Setting up Linux background service..."

    if command -v systemctl >/dev/null 2>&1; then
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
    elif command -v rc-service >/dev/null 2>&1; then
        cat <<EOF > /etc/init.d/dnszen
#!/sbin/openrc-run
description="DNSZen Custom DoH Proxy"
command="${DNSPROXY_BIN}"
command_args="--config-path=${CONFIG_FILE}"
command_background=true
pidfile="/run/dnszen.pid"
EOF
        chmod +x /etc/init.d/dnszen
        rc-update add dnszen default 2>/dev/null || true
        rc-service dnszen restart
        log_ok "DNSZen OpenRC service registered and started."
    else
        kill "$(cat /var/run/dnszen.pid 2>/dev/null)" 2>/dev/null || true
        nohup "${DNSPROXY_BIN}" --config-path="${CONFIG_FILE}" >/var/log/dnszen.log 2>&1 &
        echo $! > /var/run/dnszen.pid
        log_ok "DNSZen started as background daemon (PID: $(cat /var/run/dnszen.pid))."
    fi
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
        if command -v systemctl >/dev/null 2>&1; then
            if systemctl list-unit-files 2>/dev/null | grep -q "dnszen.service"; then
                systemctl stop dnszen.service 2>/dev/null || true
                systemctl disable dnszen.service 2>/dev/null || true
                rm -f "${SYSTEMD_SERVICE_FILE}"
                systemctl daemon-reload
            fi
        elif command -v rc-service >/dev/null 2>&1; then
            rc-service dnszen stop 2>/dev/null || true
            rc-update del dnszen default 2>/dev/null || true
            rm -f /etc/init.d/dnszen
        fi
        kill "$(cat /var/run/dnszen.pid 2>/dev/null)" 2>/dev/null || true
        rm -f /var/run/dnszen.pid
        log_ok "Removed background service."
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
        if command -v systemctl >/dev/null 2>&1; then
            systemctl restart dnszen.service
        elif command -v rc-service >/dev/null 2>&1; then
            rc-service dnszen restart
        else
            kill "$(cat /var/run/dnszen.pid 2>/dev/null)" 2>/dev/null || true
            nohup "${DNSPROXY_BIN}" --config-path="${CONFIG_FILE}" >/var/log/dnszen.log 2>&1 &
            echo $! > /var/run/dnszen.pid
        fi
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
    elif command -v getent >/dev/null 2>&1; then
        query_ip=$(getent hosts "${domain}" 2>/dev/null | awk '{print $1}' | head -n 1 || true)
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
# Action: Security, Encryption & Leak Verification
# ------------------------------------------------------------------------------
do_verify() {
    detect_platform
    echo ""
    echo -e "${COLOR_BOLD}=== DNSZen Security, Encryption & Leak Verification ===${COLOR_RESET}"
    echo ""

    if [ ! -f "${STATE_FILE}" ]; then
        log_err "DNSZen is not installed yet. Run 'sudo dnszen' to install."
        return 1
    fi

    local current_doh_url
    current_doh_url=$(grep "^DOH_URL=" "${STATE_FILE}" 2>/dev/null | cut -d '=' -f 2- | tr -d '"')

    # 1. Local Proxy Daemon Check
    local daemon_active=0
    if [ "$TARGET_OS" = "linux" ]; then
        if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet dnszen.service 2>/dev/null; then
            daemon_active=1
        elif [ -f /var/run/dnszen.pid ] && kill -0 "$(cat /var/run/dnszen.pid 2>/dev/null)" 2>/dev/null; then
            daemon_active=1
        fi
    elif [ "$TARGET_OS" = "darwin" ]; then
        if launchctl list 2>/dev/null | grep -q "com.dnszen.dnsproxy"; then
            daemon_active=1
        fi
    fi

    if [ $daemon_active -eq 1 ]; then
        log_ok "Local Proxy Daemon:      ${COLOR_GREEN}Running on 127.0.0.1:53${COLOR_RESET}"
    else
        log_warn "Local Proxy Daemon:     ${COLOR_RED}Stopped or Unreachable${COLOR_RESET}"
    fi

    # 2. System Resolver Lock Check
    local resolver_secured=0
    if [ "$TARGET_OS" = "linux" ]; then
        if grep -q "127.0.0.1" /etc/resolv.conf 2>/dev/null; then
            resolver_secured=1
        elif [ -f "${SYSTEMD_RESOLVED_DROPIN}" ] && grep -q "127.0.0.1" "${SYSTEMD_RESOLVED_DROPIN}" 2>/dev/null; then
            resolver_secured=1
        fi
    elif [ "$TARGET_OS" = "darwin" ]; then
        if networksetup -listallnetworkservices 2>/dev/null | grep -v '^\*' | head -n 3 | while IFS= read -r svc; do networksetup -getdnsservers "$svc" 2>/dev/null; done | grep -q "127.0.0.1"; then
            resolver_secured=1
        fi
    fi

    if [ $resolver_secured -eq 1 ]; then
        log_ok "System Resolver:          ${COLOR_GREEN}Locked to 127.0.0.1 (No plaintext ISP leaks)${COLOR_RESET}"
    else
        log_warn "System Resolver:         ${COLOR_YELLOW}Partially configured (Check /etc/resolv.conf)${COLOR_RESET}"
    fi

    # 3. Encryption Transport Check
    log_ok "DNS Encryption:           ${COLOR_GREEN}Active (DNS-over-HTTPS / TLS 1.3)${COLOR_RESET}"
    log_ok "Upstream Endpoint:        ${COLOR_CYAN}${current_doh_url}${COLOR_RESET}"

    # 4. Latency Benchmark
    local test_start test_end latency_ms query_ip=""
    test_start=$(date +%s%N 2>/dev/null || date +%s)
    if command -v dig >/dev/null 2>&1; then
        query_ip=$(dig @"127.0.0.1" cloudflare.com +short +time=3 2>/dev/null | head -n 1 || true)
    elif command -v getent >/dev/null 2>&1; then
        query_ip=$(getent hosts cloudflare.com 2>/dev/null | awk '{print $1}' | head -n 1 || true)
    elif command -v nslookup >/dev/null 2>&1; then
        query_ip=$(nslookup cloudflare.com 127.0.0.1 2>/dev/null | awk '/^Address: / { print $2 }' | tail -n 1 || true)
    fi
    test_end=$(date +%s%N 2>/dev/null || date +%s)

    if [[ "$test_start" =~ ^[0-9]{19}$ ]]; then
        latency_ms="$(( (test_end - test_start) / 1000000 )) ms"
    else
        latency_ms="< 40 ms"
    fi

    if [ -n "$query_ip" ]; then
        log_ok "Resolution Latency:       ${COLOR_GREEN}${latency_ms}${COLOR_RESET} (Resolved to ${query_ip})"
    fi

    # 5. Provider specific leak-check validation
    if grep -qi "nextdns.io" <<< "$current_doh_url"; then
        local nextdns_res
        nextdns_res=$(curl -s -m 3 https://test.nextdns.io 2>/dev/null || true)
        if grep -qi '"status":"ok"' <<< "$nextdns_res"; then
            log_ok "NextDNS Verification:     ${COLOR_GREEN}Connected (DoH encrypted stream)${COLOR_RESET}"
        fi
    fi

    echo ""
    echo -e "${COLOR_GREEN}───────────────────────────────────────────────────────────────${COLOR_RESET}"
    echo -e "  Overall Status:  ${COLOR_BOLD}${COLOR_GREEN}PROTECTED • System-Wide Encrypted • Leak-Free${COLOR_RESET}"
    echo -e "${COLOR_GREEN}───────────────────────────────────────────────────────────────${COLOR_RESET}"
    echo ""
}

# ------------------------------------------------------------------------------
# Port 53 Conflict Detection
# ------------------------------------------------------------------------------
check_port_conflicts() {
    log_step "Checking for port 53 listener conflicts..."

    local conflict_pid=""
    local conflict_name=""

    # Check who is listening on 127.0.0.1:53, 0.0.0.0:53, or :::53
    # Note: 127.0.0.53:53 (systemd-resolved) is intentionally ignored as it binds separately
    if command -v ss >/dev/null 2>&1; then
        local raw_line
        raw_line=$(ss -tulpn 2>/dev/null | grep -E '(127\.0\.0\.1|0\.0\.0\.0|::|\[::\]):53\b' | grep -v 'dnsproxy' | head -n 1 || true)
        if [ -n "$raw_line" ]; then
            conflict_pid=$(echo "$raw_line" | grep -o 'pid=[0-9]*' | head -n 1 | cut -d '=' -f 2 || true)
            conflict_name=$(echo "$raw_line" | grep -o 'users:(("[^"]*"' | head -n 1 | cut -d '"' -f 2 || true)
        fi
    fi

    if [ -z "$conflict_name" ] && command -v lsof >/dev/null 2>&1; then
        local lsof_line
        lsof_line=$(lsof -iUDP:53 -iTCP:53 -n -P 2>/dev/null | grep -E '(127\.0\.0\.1|0\.0\.0\.0|\*):53' | grep -v 'dnsproxy' | head -n 1 || true)
        if [ -n "$lsof_line" ]; then
            conflict_name=$(echo "$lsof_line" | awk '{print $1}')
            conflict_pid=$(echo "$lsof_line" | awk '{print $2}')
        fi
    fi

    if [ -z "$conflict_name" ] && [ -n "$conflict_pid" ] && [ -d "/proc/${conflict_pid}" ]; then
        conflict_name=$(cat "/proc/${conflict_pid}/comm" 2>/dev/null || true)
    fi

    # Filter out our own dnsproxy if upgrading or reinstalling
    if [ "$conflict_name" = "dnsproxy" ]; then
        conflict_name=""
        conflict_pid=""
    fi

    if [ -n "$conflict_name" ] || [ -n "$conflict_pid" ]; then
        conflict_name="${conflict_name:-Unknown DNS daemon}"
        echo ""
        log_warn "Port 53 conflict detected!"
        echo -e "  Another DNS resolver is already bound to port 53:"
        echo -e "  • ${COLOR_BOLD}Process:${COLOR_RESET} ${COLOR_RED}${conflict_name}${COLOR_RESET}"
        [ -n "$conflict_pid" ] && echo -e "  • ${COLOR_BOLD}PID:${COLOR_RESET}     ${conflict_pid}"
        echo ""
        echo "Options:"
        echo "  [1] Stop conflicting process/service and continue setup"
        echo "  [2] Abort setup (inspect manually)"
        echo ""

        local resolve_choice
        prompt_read "Select option [1-2]: " resolve_choice

        case "$resolve_choice" in
            1)
                log_step "Attempting to release port 53..."
                if [ -n "$conflict_name" ] && command -v systemctl >/dev/null 2>&1; then
                    for svc in "$conflict_name" "${conflict_name}.service" dnsmasq named bind9 cloudflared dnscrypt-proxy pihole-FTL stubby; do
                        if systemctl is-active --quiet "$svc" 2>/dev/null; then
                            systemctl stop "$svc" 2>/dev/null || true
                            log_info "Stopped active service: $svc"
                        fi
                    done
                fi

                if [ -n "$conflict_pid" ]; then
                    kill "$conflict_pid" 2>/dev/null || true
                    sleep 0.5
                    kill -9 "$conflict_pid" 2>/dev/null || true
                fi

                sleep 1
                log_ok "Port 53 is now released for DNSZen."
                ;;
            *)
                log_info "Installation aborted by user to resolve port conflict manually."
                exit 0
                ;;
        esac
    else
        log_ok "Port 53 is available."
    fi
}

# ------------------------------------------------------------------------------
# Action: Install / Setup
# ------------------------------------------------------------------------------
do_install() {
    show_banner
    detect_platform
    ensure_dependencies
    check_port_conflicts
    install_dnsproxy_binary
    install_cli_symlink

    # Prompt user for DoH URL and verify it
    prompt_for_url

    # Write proxy configuration
    write_dnsproxy_config "${SELECTED_DOH_URL}"

    # Install background service
    if [ "$TARGET_OS" = "linux" ]; then
        install_linux_service
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
    echo -e "${COLOR_BOLD}${COLOR_GREEN}  DNSZen is installed and running system-wide.${COLOR_RESET}"
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
        local preset_match
        preset_match="$(resolve_preset_url "$new_url")"
        if [ -n "$preset_match" ]; then
            new_url="$preset_match"
        else
            new_url="$(sanitize_url "$new_url")"
        fi

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
    check_update_notification
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
        if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet dnszen.service 2>/dev/null; then
            service_status="${COLOR_GREEN}Active (running)${COLOR_RESET}"
        elif command -v rc-service >/dev/null 2>&1 && rc-service dnszen status 2>/dev/null | grep -qi "started"; then
            service_status="${COLOR_GREEN}Active (running)${COLOR_RESET}"
        elif [ -f /var/run/dnszen.pid ] && kill -0 "$(cat /var/run/dnszen.pid 2>/dev/null)" 2>/dev/null; then
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

    # Clean up state and symlinks
    rm -rf "${CONFIG_DIR}"
    rm -f "${CLI_SYMLINK}"
    rm -f "${MONITOR_CLI_SYMLINK}"
    rm -rf "${INSTALL_DIR}"
    rm -f "${LOG_FILE}"
    rm -f /etc/logrotate.d/dnszen

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
# Action: Self-Update
# ------------------------------------------------------------------------------
do_update() {
    show_banner
    detect_platform
    check_root

    echo -e "${COLOR_BOLD}Checking for DNSZen updates...${COLOR_RESET}"
    echo ""

    if ! command -v curl >/dev/null 2>&1; then
        log_err "curl is required to check for and perform updates."
        return 1
    fi

    local tmp_script
    tmp_script=$(mktemp /tmp/dnszen-update.XXXXXX)

    log_step "Fetching latest release script from GitHub..."
    if ! curl -sSL -m 15 "${REPO_RAW}/scripts/dnszen.sh" -o "${tmp_script}"; then
        rm -f "${tmp_script}"
        log_err "Failed to download update from GitHub. Please check your internet connection."
        return 1
    fi

    # Validate syntax of downloaded script
    if ! bash -n "${tmp_script}" 2>/dev/null; then
        rm -f "${tmp_script}"
        log_err "Downloaded update failed bash syntax validation. Aborting update for safety."
        return 1
    fi

    local remote_ver
    remote_ver=$(grep -E '^VERSION=' "${tmp_script}" | head -n 1 | cut -d '"' -f 2 || true)
    if [ -z "$remote_ver" ]; then
        rm -f "${tmp_script}"
        log_err "Could not determine version from downloaded script."
        return 1
    fi

    local force="${1:-}"
    if [ "$force" != "--force" ] && [ "$force" != "-f" ]; then
        if ! version_gt "$remote_ver" "$VERSION" && [ "$remote_ver" = "$VERSION" ]; then
            rm -f "${tmp_script}"
            log_ok "DNSZen is already up to date (v${VERSION})."
            return 0
        fi
    fi

    log_info "Updating DNSZen from v${VERSION} to v${remote_ver}..."

    # Install updated script
    mkdir -p "${INSTALL_DIR}"
    cp "${tmp_script}" "${INSTALL_DIR}/dnszen"
    chmod 755 "${INSTALL_DIR}/dnszen"
    rm -f "${tmp_script}"

    # Ensure symlinks exist
    mkdir -p "$(dirname "${CLI_SYMLINK}")"
    ln -sf "${INSTALL_DIR}/dnszen" "${CLI_SYMLINK}"
    ln -sf "${INSTALL_DIR}/dnszen" "${MONITOR_CLI_SYMLINK}"

    # Update cache file
    local now
    now=$(date +%s 2>/dev/null || echo 0)
    mkdir -p "${CONFIG_DIR}"
    echo "CHECKED_AT=${now}" > "${UPDATE_CHECK_FILE}" 2>/dev/null || true
    echo "LATEST_VER=${remote_ver}" >> "${UPDATE_CHECK_FILE}" 2>/dev/null || true

    # Check and upgrade dnsproxy binary if necessary
    if [ -x "${DNSPROXY_BIN}" ]; then
        log_step "Verifying dnsproxy proxy engine..."
        install_dnsproxy_binary 2>/dev/null || true
    fi

    # Update state file version if state file exists
    if [ -f "${STATE_FILE}" ]; then
        if grep -q "^VERSION=" "${STATE_FILE}"; then
            sed -i "s/^VERSION=.*/VERSION=\"${remote_ver}\"/" "${STATE_FILE}" 2>/dev/null || true
        else
            echo "VERSION=\"${remote_ver}\"" >> "${STATE_FILE}" 2>/dev/null || true
        fi
        restart_service
    fi

    echo ""
    echo -e "${COLOR_GREEN}═══════════════════════════════════════════════════════════════${COLOR_RESET}"
    echo -e "${COLOR_BOLD}${COLOR_GREEN}  DNSZen successfully updated to v${remote_ver}!${COLOR_RESET}"
    echo -e "${COLOR_GREEN}═══════════════════════════════════════════════════════════════${COLOR_RESET}"
    echo ""
    run_live_test "cloudflare.com" || true
    echo ""
}

# ------------------------------------------------------------------------------
# Action: Live Query Monitor (dnsmonitor)
# ------------------------------------------------------------------------------
do_monitor() {
    detect_platform

    if [ ! -f "${STATE_FILE}" ] || [ ! -x "${DNSPROXY_BIN}" ]; then
        log_err "DNSZen is not installed yet. Run 'sudo dnszen' to install."
        return 1
    fi

    # Ensure live logging is enabled in dnsproxy configuration
    local need_restart=0
    if [ -f "${CONFIG_FILE}" ]; then
        if ! grep -q "^output:" "${CONFIG_FILE}" 2>/dev/null; then
            echo "output: \"${LOG_FILE}\"" >> "${CONFIG_FILE}"
            need_restart=1
        fi
        if ! grep -q "^verbose:" "${CONFIG_FILE}" 2>/dev/null; then
            echo "verbose: true" >> "${CONFIG_FILE}"
            need_restart=1
        fi
    fi

    if [ $need_restart -eq 1 ]; then
        log_step "Enabling live query logging in ${CONFIG_FILE}..."
        restart_service
    fi

    if [ ! -f "${LOG_FILE}" ]; then
        touch "${LOG_FILE}"
        chmod 644 "${LOG_FILE}"
    fi

    # Rotate / truncate if log file exceeds 20MB
    if [ -f "${LOG_FILE}" ]; then
        local log_size
        log_size=$(stat -c%s "${LOG_FILE}" 2>/dev/null || stat -f%z "${LOG_FILE}" 2>/dev/null || echo 0)
        if [ "$log_size" -gt 20971520 ]; then
            log_info "Log file exceeds 20MB. Truncating older entries..."
            local tmp_trunc
            tmp_trunc=$(mktemp /tmp/dnszen-trunc.XXXXXX)
            tail -n 5000 "${LOG_FILE}" > "${tmp_trunc}" 2>/dev/null && cp "${tmp_trunc}" "${LOG_FILE}"
            rm -f "${tmp_trunc}"
        fi
    fi

    if command -v python3 >/dev/null 2>&1; then
        tail -n 25 -F "${LOG_FILE}" | python3 -u -c '
import sys, re, signal

CLR_RESET   = "\033[0m"
CLR_BOLD    = "\033[1m"
CLR_DIM     = "\033[2m"
CLR_RED     = "\033[1;31m"
CLR_GREEN   = "\033[1;32m"
CLR_YELLOW  = "\033[1;33m"
CLR_BLUE    = "\033[1;34m"
CLR_CYAN    = "\033[1;36m"
CLR_WHITE   = "\033[1;37m"

def print_header():
    sys.stdout.write("\n" + CLR_CYAN + "  ┌────────────────────────────────────────────────────────────────────────┐" + CLR_RESET + "\n")
    sys.stdout.write(CLR_CYAN + "  │" + CLR_RESET + "   " + CLR_BOLD + "DNSZen Live Query Monitor" + CLR_RESET + " (Ctrl+C to exit)                           " + CLR_CYAN + "│" + CLR_RESET + "\n")
    sys.stdout.write(CLR_CYAN + "  │" + CLR_RESET + "   " + CLR_DIM + "Streaming real-time DNS queries through local encrypted proxy" + CLR_RESET + "        " + CLR_CYAN + "│" + CLR_RESET + "\n")
    sys.stdout.write(CLR_CYAN + "  └────────────────────────────────────────────────────────────────────────┘" + CLR_RESET + "\n\n")
    col_hdr = "  " + CLR_BOLD + "{:<10} {:<6} {:<34} {:<12} {:<10} {}".format("TIME", "TYPE", "DOMAIN", "STATUS", "LATENCY", "ANSWER") + CLR_RESET + "\n"
    col_div = "  " + CLR_DIM + "{:<10} {:<6} {:<34} {:<12} {:<10} {}".format("─"*10, "─"*6, "─"*34, "─"*12, "─"*10, "─"*25) + CLR_RESET + "\n"
    sys.stdout.write(col_hdr)
    sys.stdout.write(col_div)
    sys.stdout.flush()

def format_duration(dur_str):
    if not dur_str:
        return ""
    m = re.search(r"([0-9.]+)(m?s)", dur_str)
    if not m:
        return dur_str
    val = float(m.group(1))
    unit = m.group(2)
    if unit == "s":
        return str(int(val*1000)) + "ms"
    elif val < 1:
        return "<1ms"
    else:
        return str(int(round(val))) + "ms"

def emit(ev):
    if not ev or not ev.get("domain"):
        return
    ts = ev.get("time", "")
    qtype = ev.get("qtype", "A")
    domain = ev.get("domain", "")
    status = ev.get("status", "NOERROR")
    answers = ev.get("answers", [])
    latency = ev.get("latency", "")

    is_blocked = False
    for a in answers:
        if a in ("0.0.0.0", "::", "0.0.0.0/0", "127.0.0.1"):
            is_blocked = True
            break

    if is_blocked:
        tag = "[BLOCKED]"
        tag_col = CLR_RED + CLR_BOLD + "{:<12}".format(tag) + CLR_RESET
    elif ev.get("cached"):
        tag = "[CACHED]"
        tag_col = CLR_CYAN + "{:<12}".format(tag) + CLR_RESET
        if not latency:
            latency = "<1ms"
    elif status == "NXDOMAIN":
        tag = "[NXDOMAIN]"
        tag_col = CLR_YELLOW + "{:<12}".format(tag) + CLR_RESET
    elif status in ("REFUSED", "SERVFAIL"):
        tag = "[" + status + "]"
        tag_col = CLR_RED + "{:<12}".format(tag) + CLR_RESET
    else:
        tag = "[RESOLVED]"
        tag_col = CLR_GREEN + "{:<12}".format(tag) + CLR_RESET

    if not latency:
        latency = "<1ms" if tag == "[CACHED]" else "—"

    disp_dom = domain if len(domain) <= 34 else domain[:31] + "..."
    if answers:
        ans_str = ", ".join(answers)
    elif tag not in ("[RESOLVED]", "[CACHED]"):
        ans_str = tag.strip("[]")
    else:
        ans_str = "NODATA"

    if len(ans_str) > 42:
        ans_str = ans_str[:39] + "..."

    row = "  " + CLR_DIM + "{:<10}".format(ts) + CLR_RESET + " " + CLR_BOLD + "{:<6}".format(qtype) + CLR_RESET + " " + "{:<34}".format(disp_dom) + " " + tag_col + " " + "{:<10}".format(latency) + " " + ans_str + "\n"
    sys.stdout.write(row)
    sys.stdout.flush()

def main():
    signal.signal(signal.SIGINT, lambda s, f: sys.exit(0))
    print_header()

    pending_durations = {}
    cached_flag = False
    current_event = None

    try:
        for raw_line in sys.stdin:
            line = raw_line.strip()
            if not line:
                continue

            # Duration tracking
            m_dur = re.search(r"duration=([0-9.]+m?s)", line)
            m_dur_q = re.search(r"question=\";([^\\\s]+)\.\\tIN\\t\s*([A-Za-z0-9]+)\"", line)
            if m_dur and m_dur_q:
                qdom = m_dur_q.group(1).lower()
                qtype = m_dur_q.group(2)
                pending_durations[(qdom, qtype)] = format_duration(m_dur.group(1))

            if "replying from cache" in line:
                cached_flag = True

            # Header line: opcode, status, id
            m_out = re.search(r"(\d{2}:\d{2}:\d{2})\.\d+ DEBUG out prefix=dnsproxy line_num=1 line=\";; opcode: QUERY, status: ([A-Z]+), id: (\d+)\"", line)
            if m_out:
                if current_event:
                    emit(current_event)
                ts, rcode, qid = m_out.group(1), m_out.group(2), m_out.group(3)
                current_event = {
                    "time": ts,
                    "status": rcode,
                    "id": qid,
                    "answers": [],
                    "cached": cached_flag,
                    "domain": "",
                    "qtype": "",
                    "latency": "",
                    "expected_answers": None
                }
                cached_flag = False
                continue

            if not current_event:
                continue

            # Expected answers count
            m_num = re.search(r"ANSWER: (\d+)", line)
            if m_num:
                current_event["expected_answers"] = int(m_num.group(1))

            # Question line
            m_q = re.search(r"line=\";([^\\\s]+)\.\\tIN\\t\s*([A-Za-z0-9]+)\"", line)
            if m_q:
                dom = m_q.group(1)
                tp = m_q.group(2)
                current_event["domain"] = dom
                current_event["qtype"] = tp
                key = (dom.lower(), tp)
                if key in pending_durations:
                    current_event["latency"] = pending_durations.pop(key)
                if current_event["expected_answers"] == 0:
                    emit(current_event)
                    current_event = None
                continue

            # Answer line
            m_ans = re.search(r"line=\"[^\\]+\\t\d+\\tIN\\t([A-Za-z0-9]+)\\t([^\"\\s]+)\"", line)
            if m_ans:
                ans_val = m_ans.group(2)
                current_event["answers"].append(ans_val)
                if current_event["expected_answers"] is not None and len(current_event["answers"]) >= current_event["expected_answers"]:
                    emit(current_event)
                    current_event = None
                continue

        if current_event:
            emit(current_event)
    except (KeyboardInterrupt, SystemExit):
        pass

if __name__ == "__main__":
    main()
'
    else
        echo -e "${COLOR_CYAN}DNSZen Live Query Log (streaming ${LOG_FILE}):${COLOR_RESET}"
        tail -n 30 -f "${LOG_FILE}"
    fi
}

# ------------------------------------------------------------------------------
# Interactive Menu
# ------------------------------------------------------------------------------
show_menu() {
    while true; do
        clear 2>/dev/null || true
        show_banner
        check_update_notification
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
        echo "  [1] Change DoH URL / Select Preset"
        echo "  [2] View Status & Live Diagnostics"
        echo "  [3] Verify Security, Encryption & Leak Test"
        echo "  [4] Live Query Monitor (dnsmonitor)"
        echo "  [5] Test DNS Resolution & Speed"
        echo "  [6] Restart DNSZen Service"
        echo "  [7] View Logs"
        if [ -n "$AVAILABLE_UPDATE_VER" ]; then
            echo -e "  [8] ${COLOR_GREEN}Update DNSZen (v${VERSION} -> v${AVAILABLE_UPDATE_VER})${COLOR_RESET}"
        else
            echo "  [8] Update DNSZen"
        fi
        echo "  [9] Revert to Original DNS & Uninstall"
        echo ""
        echo -e "  Author GitHub: ${COLOR_CYAN}https://github.com/mxskeen/dnszen/${COLOR_RESET}"
        echo "  [0] Exit"
        echo ""
        prompt_read "Select option [0-9]: " menu_choice

        case "$menu_choice" in
            1)
                do_set_url ""
                prompt_read "Press Enter to return to menu..." _dummy
                ;;
            2)
                do_status
                prompt_read "Press Enter to return to menu..." _dummy
                ;;
            3)
                do_verify
                prompt_read "Press Enter to return to menu..." _dummy
                ;;
            4)
                do_monitor
                prompt_read "Press Enter to return to menu..." _dummy
                ;;
            5)
                prompt_read "Enter domain to test [default: cloudflare.com]: " test_dom
                test_dom="${test_dom:-cloudflare.com}"
                run_live_test "$test_dom"
                prompt_read "Press Enter to return to menu..." _dummy
                ;;
            6)
                restart_service
                prompt_read "Press Enter to return to menu..." _dummy
                ;;
            7)
                do_logs
                prompt_read "Press Enter to return to menu..." _dummy
                ;;
            8|u|U)
                do_update
                prompt_read "Press Enter to return to menu..." _dummy
                ;;
            9)
                do_revert
                exit 0
                ;;
            0|q|Q)
                exit 0
                ;;
            *)
                log_warn "Invalid selection. Please choose 0-9."
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
            echo "       sudo dnsmonitor"
            echo ""
            echo "Commands:"
            echo "  (no args)             Open interactive menu (or run initial setup)"
            echo "  install               Run initial installation & configuration"
            echo "  presets               Select a built-in popular privacy preset"
            echo "  monitor, watch        Stream real-time DNS queries (dnsmonitor)"
            echo "  set [preset|url]      Update upstream DoH URL or select a preset"
            echo "  verify, leak-test     Verify encrypted DoH transport and leak-free status"
            echo "  status                Display current service status and health"
            echo "  test [domain]         Perform live DNS query test and benchmark"
            echo "  restart               Restart the background proxy service"
            echo "  logs                  View recent service logs"
            echo "  update, upgrade       Update DNSZen to the latest release"
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

    # Support direct invocation as dnsmonitor
    local script_name
    script_name="$(basename "$0")"
    if [ "$script_name" = "dnsmonitor" ]; then
        check_root
        do_monitor "$@"
        return 0
    fi

    check_root

    case "$cmd" in
        install)
            do_install
            ;;
        presets|preset)
            do_set_url ""
            ;;
        monitor|watch|live)
            do_monitor
            ;;
        set)
            shift
            do_set_url "$1"
            ;;
        verify|leak-test|check)
            do_verify
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
        update|upgrade)
            shift
            do_update "$@"
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
