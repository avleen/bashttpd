#!/usr/bin/env bash
#
# scripts/gen-cert.sh -- generate a self-signed cert/key for bashttpd --tls.
#
# Usage: scripts/gen-cert.sh [CERT_OUT] [KEY_OUT]
# Defaults: certs/server.crt and certs/server.key
#
# The certificate is a self-signed EC cert for CN=localhost with SANs for
# localhost and 127.0.0.1, valid for 365 days. The key is written mode 600.

set -euo pipefail

CERT_OUT=${1:-certs/server.crt}
KEY_OUT=${2:-certs/server.key}

command -v openssl >/dev/null 2>&1 || {
    printf 'gen-cert: openssl is required but not found\n' >&2
    exit 1
}

mkdir -p -- "$(dirname -- "$CERT_OUT")" "$(dirname -- "$KEY_OUT")"

openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -nodes \
    -keyout "$KEY_OUT" \
    -out "$CERT_OUT" \
    -days 365 \
    -subj '/CN=localhost' \
    -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1' 2>/dev/null

chmod 600 -- "$KEY_OUT"

printf 'Wrote certificate: %s\n' "$CERT_OUT"
printf 'Wrote private key: %s (mode 600)\n' "$KEY_OUT"
printf '\nStart with TLS:\n  bin/bashttpd --tls --cert %s --key %s\n' "$CERT_OUT" "$KEY_OUT"
