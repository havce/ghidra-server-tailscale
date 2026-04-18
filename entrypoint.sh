#!/bin/bash
set -euo pipefail

CONF="${GHIDRA_HOME}/server/server.conf"

# Rebuild the wrapper.app.parameter.N list from env at start time so that
# deployment-specific flags (like -ip for the advertised hostname) can be
# injected without rebuilding the image. The repository path stays last.
params=()
if [ -n "${GHIDRA_PUBLIC_HOSTNAME:-}" ]; then
    params+=("-ip" "${GHIDRA_PUBLIC_HOSTNAME}")
fi
params+=("-a0" "-u" "-autoProvision" "-tailscale" '${ghidra.repositories.dir}')

sed -i '/^wrapper\.app\.parameter\.[0-9]\+=/d' "$CONF"

{
    echo
    i=1
    for p in "${params[@]}"; do
        echo "wrapper.app.parameter.${i}=${p}"
        i=$((i + 1))
    done
} >> "$CONF"

exec "$@"
