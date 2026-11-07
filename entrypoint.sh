#!/bin/bash
set -euo pipefail

CONF="${GHIDRA_HOME}/server/server.conf"
TLS_DIR="${GHIDRA_TLS_DIR:-/var/lib/ghidra/tls}"
TLS_CERT="${TLS_DIR}/server.crt"
TLS_KEY="${TLS_DIR}/server.key"
TLS_KEYSTORE="${TLS_DIR}/server.p12"
# How often to ask tailscaled for a fresh certificate, and how much validity
# must remain before it is renewed (Let's Encrypt certificates last 90 days).
RENEW_INTERVAL="${GHIDRA_TLS_RENEW_INTERVAL:-12h}"
MIN_VALIDITY="${GHIDRA_TLS_MIN_VALIDITY:-720h}"

log() {
    echo "[entrypoint] $*" >&2
}

# Fetch (or refresh) the Let's Encrypt certificate for the advertised
# hostname from the tailscale sidecar. tailscaled caches the certificate and
# only contacts the CA when less than MIN_VALIDITY remains.
fetch_cert() {
    tailscale cert \
        --cert-file "${TLS_CERT}" \
        --key-file "${TLS_KEY}" \
        --min-validity "${MIN_VALIDITY}" \
        "${GHIDRA_PUBLIC_HOSTNAME}" >/dev/null
}

cert_fingerprint() {
    sha256sum "${TLS_CERT}" | cut -d' ' -f1
}

# Watch for renewed certificates. Ghidra Server only reads its keystore at
# startup, so when the certificate changes we stop the container (SIGTERM to
# tini, PID 1) and let Docker's restart policy bring it back with the new
# certificate.
renew_loop() {
    local current
    current="$(cert_fingerprint)"
    while sleep "${RENEW_INTERVAL}"; do
        if ! fetch_cert; then
            log "certificate renewal check failed; retrying in ${RENEW_INTERVAL}"
            continue
        fi
        if [ "$(cert_fingerprint)" != "${current}" ]; then
            log "certificate renewed; restarting container to load it"
            kill -TERM 1
            return
        fi
    done
}

# Ghidra Server only accepts network connections when it has a keystore, and
# 12.2+ clients reject its self-signed fallback certificate. Obtain a publicly
# trusted certificate for the tailnet hostname and build a PKCS#12 keystore.
tls_props=()
if [ -n "${GHIDRA_PUBLIC_HOSTNAME:-}" ]; then
    mkdir -p "${TLS_DIR}"
    chmod 0700 "${TLS_DIR}"

    # The sidecar may still be starting; depends_on does not wait for it.
    attempt=1
    until fetch_cert; do
        if [ "${attempt}" -ge 30 ]; then
            log "unable to obtain certificate for ${GHIDRA_PUBLIC_HOSTNAME}"
            exit 1
        fi
        log "waiting for tailscale to issue a certificate (attempt ${attempt})"
        attempt=$((attempt + 1))
        sleep 5
    done

    keystore_password="$(openssl rand -hex 32)"
    openssl pkcs12 -export \
        -name ghidra-server \
        -inkey "${TLS_KEY}" \
        -in "${TLS_CERT}" \
        -out "${TLS_KEYSTORE}" \
        -passout "pass:${keystore_password}"
    chmod 0600 "${TLS_KEY}" "${TLS_KEYSTORE}"

    tls_props+=("wrapper.java.additional.9=-Dghidra.keystore=${TLS_KEYSTORE}")
    tls_props+=("wrapper.java.additional.10=-Dghidra.password=${keystore_password}")
    log "using certificate for ${GHIDRA_PUBLIC_HOSTNAME}"
fi

# Rebuild the wrapper.app.parameter.N list from env at start time so that
# deployment-specific flags (like -ip for the advertised hostname) can be
# injected without rebuilding the image. The repository path stays last.
params=()
if [ -n "${GHIDRA_PUBLIC_HOSTNAME:-}" ]; then
    params+=("-ip" "${GHIDRA_PUBLIC_HOSTNAME}")
fi
params+=("-a0" "-u" "-autoProvision" "-tailscale" '${ghidra.repositories.dir}')

sed -i \
    -e '/^wrapper\.app\.parameter\.[0-9]\+=/d' \
    -e '/^wrapper\.java\.additional\.\(9\|10\)=/d' \
    "$CONF"

{
    echo
    for p in "${tls_props[@]}"; do
        echo "${p}"
    done
    i=1
    for p in "${params[@]}"; do
        echo "wrapper.app.parameter.${i}=${p}"
        i=$((i + 1))
    done
} >> "$CONF"

if [ -n "${GHIDRA_PUBLIC_HOSTNAME:-}" ]; then
    renew_loop &
fi

exec "$@"
