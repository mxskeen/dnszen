#!/usr/bin/env bash
# ==============================================================================
#  DNSZen - Universal Entrypoint & One-Line Installer Wrapper
#  Supports: sudo ./install.sh OR curl -sSL https://.../install.sh | sudo bash
# ==============================================================================
set -e

REPO_RAW="https://raw.githubusercontent.com/mxskeen/dnszen/master"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "")"
LOCAL_SCRIPT="${SCRIPT_DIR}/scripts/dnszen.sh"

if [ -n "${SCRIPT_DIR}" ] && [ -f "${LOCAL_SCRIPT}" ]; then
    chmod +x "${LOCAL_SCRIPT}" 2>/dev/null || true
    exec "${LOCAL_SCRIPT}" "$@"
else
    # Piped zero-clone mode
    TMP_DIR="$(mktemp -d /tmp/dnszen-install.XXXXXX)"
    mkdir -p "${TMP_DIR}/scripts"
    echo "[>] Fetching DNSZen installer from GitHub..."
    if command -v curl >/dev/null 2>&1; then
        curl -sSL -f "${REPO_RAW}/scripts/dnszen.sh" -o "${TMP_DIR}/scripts/dnszen.sh"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "${TMP_DIR}/scripts/dnszen.sh" "${REPO_RAW}/scripts/dnszen.sh"
    else
        echo "[ERROR] curl or wget is required to install DNSZen." >&2
        exit 1
    fi
    chmod +x "${TMP_DIR}/scripts/dnszen.sh"
    exec "${TMP_DIR}/scripts/dnszen.sh" "$@"
fi
