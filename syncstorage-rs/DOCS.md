# Syncstorage-rs

Self-hosted Firefox Sync server. See the [project README][readme] for the
full installation and reverse-proxy walkthrough — this page covers the add-on
configuration options and the upstream HTTP endpoints you can hit for
diagnostics.

[readme]: https://github.com/Aghabeiki/firefox-sync-addon#readme

## Configuration

All options live under the add-on's **Configuration** tab.

### `master_secret`

- **Type**: password (string)
- **Default**: *(empty — must be set)*
- **Required**: yes
- **Description**: Cryptographic root for Hawk authentication. Used to derive
  the signing and token secrets. Generate with `openssl rand -hex 32` and
  store somewhere safe — losing it makes existing data unreadable.
- **Example**: `c7e3...` (64 hex characters)

### `public_url`

- **Type**: url (string)
- **Default**: *(empty — must be set)*
- **Required**: yes
- **Description**: The publicly reachable HTTPS URL of your reverse proxy.
  Must start with `https://`. The add-on hard-fails on `http://`. Trailing
  slashes are stripped automatically.
- **Example**: `https://sync.example.com`

### `fxa_oauth_server_url`

- **Type**: url (string)
- **Default**: `https://oauth.accounts.firefox.com`
- **Required**: yes
- **Description**: Mozilla's FxA OAuth endpoint. Change only if you are
  testing against the FxA staging environment
  (`https://oauth.stage.mozaws.net`) or running your own FxA, which is well
  outside the scope of this add-on.
- **Example**: `https://oauth.accounts.firefox.com`

### `fxa_email_domain`

- **Type**: string
- **Default**: `api.accounts.firefox.com`
- **Required**: yes
- **Description**: Suffix applied when constructing tokenserver user
  identifiers from FxA UIDs. Leave at the default unless you know precisely
  why you're changing it.
- **Example**: `api.accounts.firefox.com`

### `enable_quota`

- **Type**: bool
- **Default**: `false`
- **Required**: no
- **Description**: Whether to enforce a per-user storage quota. Off is fine
  for personal use; turning this on without setting a quota limit elsewhere
  is rarely useful.
- **Example**: `false`

### `max_total_records`

- **Type**: int (minimum 100)
- **Default**: `1666`
- **Required**: no
- **Description**: Upper bound on records returned in a single batch.
  Defaults to `1666` because of upstream issues
  [#298](https://github.com/mozilla-services/syncstorage-rs/issues/298) and
  [#333](https://github.com/mozilla-services/syncstorage-rs/issues/333). If
  you see batch errors with very large bookmark or history collections, drop
  it lower (e.g. `1000`). Raise it once upstream has fixed the underlying
  bug.
- **Example**: `1666`

### `log_level`

- **Type**: list (`trace` | `debug` | `info` | `warn` | `error`)
- **Default**: `info`
- **Required**: no
- **Description**: Sets `RUST_LOG`. Use `debug` while you are getting Firefox
  to talk to the server; revert to `info` for normal operation.
- **Example**: `info`

### `human_logs`

- **Type**: bool
- **Default**: `true`
- **Required**: no
- **Description**: When `true`, logs are emitted as readable lines suitable
  for the Home Assistant log viewer. When `false`, logs are emitted as
  Mozilla's structured JSON format — useful if you forward logs to a
  centralised collector.
- **Example**: `true`

## Upstream HTTP endpoints

The server exposes four health/info endpoints. They are useful for
monitoring, smoke-testing, and reverse-proxy health checks.

| Endpoint           | Meaning                                                                                  |
| ------------------ | ---------------------------------------------------------------------------------------- |
| `/__heartbeat__`   | Full liveness check: opens a database connection and confirms FxA reachability.          |
| `/__lbheartbeat__` | Cheap liveness check: returns 200 without touching dependencies. Use for HTTP load-balancer probes. |
| `/__version__`     | Returns the upstream `version.json` (commit, source repository, build tag).             |
| `/__error__`       | Forces an error path — handy for verifying your alerting/log pipeline picks up 5xx.    |

Hit them through your reverse proxy:

```sh
curl -fsS https://sync.example.com/__heartbeat__
curl -fsS https://sync.example.com/__version__
```

## Where the database lives

The add-on talks to the official Home Assistant **MariaDB** add-on over the
Supervisor-injected `mysql` service binding. Two databases are created on
first start, both with `utf8mb4` / `utf8mb4_unicode_ci`:

- `syncstorage_rs` — encrypted user records (bookmarks, history, etc).
- `tokenserver_rs` — token issuance and node assignment metadata.

Schema migrations are applied automatically on startup
(`SYNC_TOKENSERVER__RUN_MIGRATIONS=true`).

You do not need to manage credentials yourself; the Supervisor passes them
to the add-on at runtime.
