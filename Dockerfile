# syntax=docker/dockerfile:1

# -------- Build stage: compile Ghidra from source --------
FROM eclipse-temurin:21-jdk-jammy AS build

ARG GHIDRA_REPO=https://github.com/NationalSecurityAgency/ghidra.git
ARG GHIDRA_REF=Ghidra_12.0.4_build

ENV DEBIAN_FRONTEND=noninteractive \
    GRADLE_OPTS="-Dorg.gradle.daemon=false -Dfile.encoding=UTF-8"

RUN apt-get update && apt-get install -y --no-install-recommends \
        bash ca-certificates curl git unzip zip \
        python3 python3-pip python3-venv \
        build-essential gcc g++ make \
        zlib1g-dev libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# Upgrade pip and setuptools to ensure we can install any Python dependencies
RUN python3 -m pip install --no-cache-dir --upgrade 'pip>=24' setuptools wheel

WORKDIR /src
RUN git clone --depth 1 --branch "${GHIDRA_REF}" "${GHIDRA_REPO}" .

# Fetch third-party dependencies, then build the distribution zip.
# The produced archive lands in build/dist/ghidra_*.zip.
RUN ./gradlew -I gradle/support/fetchDependencies.gradle

# Apply all local patches in series. Using `git apply` keeps failures loud
# instead of silently producing a broken tree.
COPY patches/ /tmp/patches/
RUN set -eux; \
    for p in /tmp/patches/*.patch; do \
        echo "Applying $p"; \
        git apply --verbose "$p"; \
    done

# Build the Ghidra Server distribution
RUN ./gradlew buildGhidra \
 && unzip -q build/dist/ghidra_*.zip -d /opt \
 && mv /opt/ghidra_* /opt/ghidra

# -------- Runtime stage --------
FROM eclipse-temurin:21-jre-jammy

ARG TAILSCALE_VERSION=1.78.1

ENV DEBIAN_FRONTEND=noninteractive \
    GHIDRA_HOME=/opt/ghidra \
    GHIDRA_REPOSITORIES=/var/lib/ghidra/repositories

RUN apt-get update && apt-get install -y --no-install-recommends \
        bash ca-certificates curl tini \
 && arch="$(dpkg --print-architecture)" \
 && case "$arch" in \
        amd64) tsarch=amd64 ;; \
        arm64) tsarch=arm64 ;; \
        *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac \
 && curl -fsSL "https://pkgs.tailscale.com/stable/tailscale_${TAILSCALE_VERSION}_${tsarch}.tgz" -o /tmp/tailscale.tgz \
 && tar -xzf /tmp/tailscale.tgz -C /tmp \
 && install -m 0755 "/tmp/tailscale_${TAILSCALE_VERSION}_${tsarch}/tailscale" /usr/local/bin/tailscale \
 && rm -rf /tmp/tailscale* /var/lib/apt/lists/*

COPY --from=build /opt/ghidra ${GHIDRA_HOME}

# Redirect repositories to a volume-friendly path. Server startup flags
# (wrapper.app.parameter.N) are rewritten at container start by the entrypoint
# so deployment-specific options like -ip can be injected from env vars.
RUN sed -i "s|^ghidra\.repositories\.dir=.*|ghidra.repositories.dir=${GHIDRA_REPOSITORIES}|" ${GHIDRA_HOME}/server/server.conf

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

RUN groupadd -r -g 1001 ghidra \
 && useradd -r -u 1001 -g ghidra -d /home/ghidra -m -s /bin/bash ghidra \
 && mkdir -p ${GHIDRA_REPOSITORIES} \
 && chown -R ghidra:ghidra ${GHIDRA_HOME} /var/lib/ghidra

USER ghidra
WORKDIR ${GHIDRA_HOME}

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["/opt/ghidra/server/ghidraSvr", "console"]
