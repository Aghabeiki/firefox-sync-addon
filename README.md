# Home Assistant add-on: `syncstorage-rs`

A Home Assistant OS add-on that runs Mozilla's
[`syncstorage-rs`](https://github.com/mozilla-services/syncstorage-rs) — the
self-hosted Firefox Sync server, written in Rust — backed by the official HA
MariaDB add-on.

> **Unofficial.** This add-on is not affiliated with, sponsored by, or endorsed
> by Mozilla. It packages an upstream open-source project for convenience on
> Home Assistant OS. Use at your own risk.

---

## What you get

- Pinned upstream `mozilla-services/syncstorage-rs` at tag **`0.22.3`**.
- MySQL/MariaDB storage backend only (no Spanner, no Google Cloud).
- Authentication delegated to **Mozilla-hosted Firefox Accounts** — no local
  account server.
- Pre-built multi-arch images for **`aarch64`** (Raspberry Pi 4/5) and
  **`amd64`**, published to GitHub Container Registry. The Supervisor pulls the
  image; nothing is built on your device.
- HA-native snapshots: add-on configuration is captured by HA backups, and the
  database lives inside the official MariaDB add-on which is also backed up.

## What this add-on does **not** provide

- **No TLS.** The server listens on plain HTTP on port `8000`. Firefox refuses
  to use a non-HTTPS sync URL, so you **must** put a reverse proxy with a valid
  certificate in front of it. See "Reverse proxy" below.
- **No web UI.** This is a headless API. Use the
  [health endpoints](syncstorage-rs/DOCS.md) for sanity checks.
- **No bundled MariaDB.** The database runs in the official `core_mariadb`
  add-on. Credentials are passed in by the Supervisor at runtime — you do not
  configure them here.
- **No migration tooling** from the legacy Python `syncserver`.

---

## Prerequisites

1. Home Assistant OS or Supervised, on `aarch64` or `amd64`.
2. The official **MariaDB** add-on installed and running.
3. A reverse proxy (NGINX Proxy Manager add-on, the HA NGINX add-on, or your
   own) with a valid TLS certificate.
4. A public DNS record pointing at your reverse proxy. Self-signed certificates
   will not work — Firefox requires a publicly trusted certificate chain.

---

## Installation

### 1. Add this repository to Home Assistant

In Home Assistant, go to **Settings → Add-ons → Add-on Store**, click the
three-dot menu (top right), choose **Repositories**, and add:

```
https://github.com/Aghabeiki/firefox-sync-addon
```

The **Syncstorage-rs** add-on will appear in the store.

### 2. Install MariaDB

If you have not already, install the official **MariaDB** add-on. The default
configuration is fine; you do not need to create databases manually — this
add-on creates `syncstorage_rs` and `tokenserver_rs` automatically on first
start.

### 3. Install Syncstorage-rs

Install the add-on but **do not start it yet**.

### 4. Generate a master secret

On any machine with OpenSSL:

```sh
openssl rand -hex 32
```

Copy the resulting 64-character string. This is your `master_secret`. Store it
somewhere safe — losing it means losing access to all encrypted data on the
server.

### 5. Configure the add-on

Open the add-on's **Configuration** tab and set:

| Option                 | Value                                                                                                |
| ---------------------- | ---------------------------------------------------------------------------------------------------- |
| `master_secret`        | The 64-character string from step 4.                                                                 |
| `public_url`           | The HTTPS URL Firefox will reach the server on, e.g. `https://sync.example.com`. **No trailing /.** |
| `fxa_oauth_server_url` | Leave at the default (`https://oauth.accounts.firefox.com`) unless you know why you'd change it.    |
| `fxa_email_domain`     | Leave at the default (`api.accounts.firefox.com`).                                                  |
| `enable_quota`         | `false` is fine for personal use.                                                                    |
| `max_total_records`    | Default `1666` — see *Troubleshooting*.                                                              |
| `log_level`            | `info` for normal operation, `debug` while you're getting it working.                                |
| `human_logs`           | `true` makes the HA log viewer readable; set `false` for JSON.                                       |

See [`syncstorage-rs/DOCS.md`](syncstorage-rs/DOCS.md) for the exhaustive
option reference.

### 6. Configure your reverse proxy

You need a publicly trusted HTTPS endpoint that proxies to
`http://<add-on-hostname>:8000`. With NGINX Proxy Manager, that is:

- **Domain Names**: `sync.example.com`
- **Scheme**: `http`
- **Forward Hostname / IP**: `a0d7b954-syncstorage-rs` (or whatever the
  Supervisor reports — use the add-on's hostname, not its slug)
- **Forward Port**: `8000`
- **Block Common Exploits**: on
- **Websockets Support**: not required
- **SSL**: request a Let's Encrypt certificate, force SSL, HTTP/2 enabled.

> **Without HTTPS, Firefox will refuse to use the server.** This is enforced
> by the browser, not by this add-on, and it is not optional.

### 7. Start the add-on

Start it from the **Info** tab and watch the **Log** tab. You should see
something like:

```
[INFO] Ensuring databases exist on core-mariadb:3306
[INFO] Starting syncstorage-rs on :8000 (public URL: https://sync.example.com)
```

Sanity-check from any machine that can reach the proxy:

```sh
curl -fsS https://sync.example.com/__heartbeat__
```

Expect HTTP 200 and a small JSON object with `"status":"Ok"` and
`"database":"Ok"`. For a more thorough probe, use the bundled script:

```sh
./scripts/healthcheck.sh https://sync.example.com
```

It runs all three health endpoints, parses the heartbeat JSON, and prints a
green/red verdict.

### 8. Point Firefox at your server

In every Firefox profile that should sync against your server (do this
**before** signing in to Firefox Sync, or sign out first):

1. Open `about:config` and accept the warning.
2. Set `identity.sync.tokenserver.uri` to:
   ```
   https://sync.example.com/1.0/sync/1.5
   ```
3. Restart Firefox.
4. Sign in to your Firefox Account. Sync data will now flow through your
   server.

To verify, open `about:sync-log` after a sync attempt — you should see traffic
to your domain, not Mozilla's.

---

## Backups

Home Assistant snapshots include both:

- The MariaDB add-on's data directory (so all sync state).
- This add-on's configuration (so the `master_secret`).

Restoring an HA snapshot restores the full sync state. The `master_secret` is
included in snapshots — treat snapshot files accordingly.

If you change `master_secret` after users have already synced, all existing
data becomes unreadable. Don't.

---

## Troubleshooting

### `__heartbeat__` returns non-200

Check the add-on log. Most commonly the MariaDB add-on isn't running or this
add-on couldn't create the databases. The log will say which.

### Firefox shows "Sync server returned an error"

Set `log_level: debug` in this add-on's config and restart it. Then trigger a
sync (`about:preferences#sync` → "Sync now") and grep the log for `ERROR` or
`WARN`. Common causes:

- **`public_url` mismatch**: the URL Firefox is hitting must match
  `public_url` exactly, including scheme and absence of trailing slash.
- **Clock skew**: FxA token verification will reject requests if the add-on
  host clock is more than a few minutes off. Make sure HA's time is correct.
- **Reverse-proxy stripping headers**: do not strip `Authorization` or
  `Content-Type`.

### `max_total_records` and large sync payloads

Upstream issues
[#298](https://github.com/mozilla-services/syncstorage-rs/issues/298) and
[#333](https://github.com/mozilla-services/syncstorage-rs/issues/333) describe
sync failures when a single batch exceeds the server's record cap. The
historical workaround is to lower `max_total_records` to `1666`, which is the
default here. If your Firefox profile has very large bookmark or history
collections and you see batch errors, try lowering further (e.g. `1000`); if
upstream has fixed the bug at a later tag, raise it. Track the linked issues
upstream.

### Health endpoints

The four upstream-provided endpoints are useful for monitoring:

| Endpoint           | Purpose                                              |
| ------------------ | ---------------------------------------------------- |
| `/__heartbeat__`   | Full health: database connectivity, FxA reachable.   |
| `/__lbheartbeat__` | Cheap liveness probe; doesn't touch the database.   |
| `/__version__`     | Returns the upstream `version.json` (commit/tag).   |
| `/__error__`       | Forces an error path; useful for log/alert testing. |

---

## Security notes

- The `master_secret` is the cryptographic root for Hawk authentication. Keep
  it private. Anyone with this string can mint authentication tokens.
- Snapshots contain the `master_secret`. Encrypt offsite snapshot copies.
- The add-on listens on `0.0.0.0:8000` inside the add-on network namespace.
  Do not publish port `8000` directly to the internet — always go through the
  reverse proxy so TLS is enforced and so you can rate-limit.

---

## Updating

To pick up a newer upstream `syncstorage-rs` release, this add-on must be
re-published with a new pinned `SYNCSTORAGE_REF`. Watch the
[Releases page](https://github.com/Aghabeiki/firefox-sync-addon/releases)
of this repository.

---

## Licence

The add-on packaging code in this repository is MIT-licensed. The packaged
upstream `syncstorage-rs` binary is MPL-2.0; see
[upstream LICENSE](https://github.com/mozilla-services/syncstorage-rs/blob/0.22.3/LICENSE).
