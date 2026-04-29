# Changelog

All notable changes to this add-on are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## 0.1.1 — Friendlier MariaDB-not-running error

- Pre-flight check: detect when the `mysql` service binding is unavailable
  (typical cause: official MariaDB add-on is installed but not started) and
  print an actionable message pointing at the fix instead of letting bashio's
  cryptic `Service not enabled` line surface.

## 0.1.0 — Initial release

- Pinned upstream `mozilla-services/syncstorage-rs` at tag **`0.22.3`**.
- MariaDB backend only (`syncstorage-db/mysql` cargo feature). Spanner is
  deliberately not built — it pulls grpcio/protobuf/google-cloud-rust-raw and
  is irrelevant for self-hosted use.
- `py_verifier` cargo feature enabled, which is required by upstream from
  0.22.x onward for FxA OAuth token verification. Runtime image therefore
  ships Python 3.11 plus the upstream-vendored Poetry-resolved wheel set.
- Authentication delegated to Mozilla-hosted Firefox Accounts. No local
  auth, no embedded account server.
- Multi-arch images (`aarch64`, `amd64`) built and pushed to GitHub Container
  Registry by the repository's `build.yaml` workflow on tag push.
- `max_total_records` default of `1666` to work around upstream issues
  [#298](https://github.com/mozilla-services/syncstorage-rs/issues/298) and
  [#333](https://github.com/mozilla-services/syncstorage-rs/issues/333). To
  be re-evaluated on the next upstream bump.
