# syntax=docker/dockerfile:1.7
#
# Multi-stage build for the syncstorage-rs Home Assistant add-on.
#
# Why this Dockerfile is shaped the way it is:
#
#   * Upstream syncstorage-rs (>= 0.22.x) requires the `py_verifier` cargo
#     feature for FxA OAuth token verification. That feature pulls a Python
#     dependency (PyFxA) at runtime, so the runtime image needs Python 3 and
#     the Poetry-resolved wheel set. Disabling py_verifier compiles fine but
#     breaks token verification at runtime.
#
#   * We mirror upstream's cargo-chef + Poetry-export-to-wheels pipeline so
#     the dependency resolution matches what upstream tests against. Only the
#     final stage diverges: it sits on top of the Home Assistant Debian base
#     image (which already provides bashio and an init system), rather than
#     plain `debian:bookworm-slim`.
#
#   * Spanner is not built. We pass `--no-default-features --features
#     syncstorage-db/mysql --features py_verifier` to skip the
#     grpcio/protobuf/google-cloud-rust-raw dependency tree.
#
#   * MariaDB headers come from `libmariadb-dev-compat`, which provides the
#     `mysqlclient` symbols mysqlclient-sys (used by diesel) expects. Plain
#     `libmariadb-dev` is missing the compat shim and fails to link.
#
# hadolint global ignore=DL3008
#   Apt-pinning every transitive runtime dep across two Debian architectures
#   for two distinct base images is impractical for an add-on. Upstream does
#   not pin either.
#
ARG RUST_IMAGE=lukemathwalker/cargo-chef:0.1.73-rust-1.91.1-bookworm
ARG BUILD_FROM=ghcr.io/home-assistant/amd64-base-debian:bookworm
ARG SYNCSTORAGE_REF=0.22.3

# ---------------------------------------------------------------------------
# Stage: chef — base for both planner and builder, holds cargo-chef.
# ---------------------------------------------------------------------------
FROM ${RUST_IMAGE} AS chef
WORKDIR /app

# git + ca-certificates needed to clone the upstream source.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        git \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Stage: planner — produces a recipe.json describing the dependency graph.
# ---------------------------------------------------------------------------
FROM chef AS planner
ARG SYNCSTORAGE_REF
RUN git clone --depth 1 --branch "${SYNCSTORAGE_REF}" \
        https://github.com/mozilla-services/syncstorage-rs.git /app \
    && cargo chef prepare --recipe-path recipe.json

# ---------------------------------------------------------------------------
# Stage: builder — compiles the syncserver binary and resolves Python deps.
# ---------------------------------------------------------------------------
FROM chef AS builder
ARG SYNCSTORAGE_REF

# pipefail so `curl ... | python3` aborts on a failed download.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Build-time system deps. `libmariadb-dev-compat` provides the mysqlclient
# headers diesel's mysqlclient-sys expects. cmake is needed by some Rust
# crates (notably aws-lc-rs via jsonwebtoken). Python toolchain is needed for
# Poetry-driven wheel building.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        libmariadb-dev-compat \
        cmake \
        pkg-config \
        python3-dev \
        python3-pip \
        python3-setuptools \
        python3-wheel \
        python3-venv \
        curl \
    && rm -rf /var/lib/apt/lists/*

# Pull dependency recipe from the planner stage and cook the dep graph. This
# is the long-cached layer; source changes don't bust it.
COPY --from=planner /app/recipe.json recipe.json

RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,target=/usr/local/cargo/git,sharing=locked \
    --mount=type=cache,target=/app/target,sharing=locked \
    cargo chef cook --release \
        --no-default-features \
        --features=syncstorage-db/mysql \
        --features=py_verifier \
        --recipe-path recipe.json

# Bring the full upstream tree in. Doing this after the cook step lets the
# cached layer stay warm across upstream-source changes that don't move deps.
RUN git clone --depth 1 --branch "${SYNCSTORAGE_REF}" \
        https://github.com/mozilla-services/syncstorage-rs.git /tmp/syncstorage-rs \
    && cp -a /tmp/syncstorage-rs/. /app/ \
    && rm -rf /tmp/syncstorage-rs

# Install Poetry; export the three Poetry-managed dependency lists upstream
# ships (root, integration_tests, tokenserver) and pre-build wheels for them.
ENV POETRY_HOME="/opt/poetry" \
    POETRY_VIRTUALENVS_IN_PROJECT=1 \
    POETRY_NO_INTERACTION=1
ENV PATH="${POETRY_HOME}/bin:${PATH}"

RUN curl -sSL https://install.python-poetry.org | python3 - \
    && ln -s "${POETRY_HOME}/bin/poetry" /usr/local/bin/poetry \
    && poetry config virtualenvs.create false \
    && poetry self add poetry-plugin-export

RUN poetry export --no-interaction --without dev --without-hashes \
        --output requirements.txt \
    && poetry --directory=/app/tools/integration_tests export \
        --no-interaction --without dev --without-hashes \
        --output requirements.txt \
    && poetry --directory=/app/tools/tokenserver export \
        --no-interaction --without dev --without-hashes \
        --output requirements.txt

RUN mkdir -p /app/wheels \
    && pip3 wheel --no-cache-dir -r /app/requirements.txt -w /app/wheels \
    && pip3 wheel --no-cache-dir -r /app/tools/integration_tests/requirements.txt \
        -w /app/wheels \
    && pip3 wheel --no-cache-dir -r /app/tools/tokenserver/requirements.txt \
        -w /app/wheels

# Final binary build. cargo install puts it in /app/bin/syncserver.
RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,target=/usr/local/cargo/git,sharing=locked \
    --mount=type=cache,target=/app/target,sharing=locked \
    cargo install --path ./syncserver \
        --no-default-features \
        --features=syncstorage-db/mysql \
        --features=py_verifier \
        --locked \
        --root /app \
    && strip /app/bin/syncserver

# ---------------------------------------------------------------------------
# Stage: runtime — Home Assistant Debian base + minimal runtime deps.
# ---------------------------------------------------------------------------
FROM ${BUILD_FROM}

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Runtime deps:
#   libmariadb3, mariadb-client : MySQL client lib for diesel + the `mysql`
#                                 CLI used by run.sh to bootstrap databases.
#   libssl3, libffi8            : transitive Python deps.
#   libpython3.11, python3,
#   python3-pip, python3-venv   : PyFxA via py_verifier needs CPython.
#   curl, jq                    : healthcheck + log-friendly JSON poking.
#   ca-certificates             : trust roots for FxA OAuth calls.
#
# python3-cryptography from apt ships an outdated 2.x; the wheelset we ship
# bundles a current version, so remove the apt one to avoid conflicts. This
# matches upstream behaviour.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        libmariadb3 \
        mariadb-client \
        libssl3 \
        libffi8 \
        libpython3.11 \
        python3 \
        python3-pip \
        python3-venv \
        curl \
        jq \
        ca-certificates \
    && (apt-get remove -y python3-cryptography 2>/dev/null || true) \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=builder /app/requirements.txt /app/requirements.txt
COPY --from=builder /app/tools/integration_tests/requirements.txt \
    /app/tools/integration_tests/requirements.txt
COPY --from=builder /app/tools/tokenserver/requirements.txt \
    /app/tools/tokenserver/requirements.txt
COPY --from=builder /app/wheels /tmp/wheels

RUN pip3 install --break-system-packages --no-cache-dir --no-index \
        --find-links=/tmp/wheels -r /app/requirements.txt \
    && pip3 install --break-system-packages --no-cache-dir --no-index \
        --find-links=/tmp/wheels -r /app/tools/integration_tests/requirements.txt \
    && pip3 install --break-system-packages --no-cache-dir --no-index \
        --find-links=/tmp/wheels -r /app/tools/tokenserver/requirements.txt \
    && rm -rf /tmp/wheels /root/.cache/pip

COPY --from=builder /app/bin/syncserver /usr/local/bin/syncserver
COPY --from=builder /app/version.json /app/version.json

COPY run.sh /run.sh
RUN chmod +x /run.sh

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD curl -fsS http://localhost:8000/__heartbeat__ || exit 1

EXPOSE 8000

# The HA base image provides s6-overlay as PID 1; CMD is the service entry.
CMD ["/run.sh"]
