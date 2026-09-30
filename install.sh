#!/usr/bin/env bash
# Entrypoint wrapper for DNSZen
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
chmod +x "${SCRIPT_DIR}/scripts/dnszen.sh" 2>/dev/null || true
exec "${SCRIPT_DIR}/scripts/dnszen.sh" "$@"
