# Backlog

Deferred work items: design is locked but execution is parked. Pick up by reading
the linked sources and contracts; no further user clarification needed unless the
card explicitly says so.

---

## Client-cert (mTLS) auth in Settings

**Status**: Designed, deferred. User has approved every design decision below;
implementation just hasn't been scheduled.

### What

Add an "Authentication" panel to the existing Settings dialog with:

- A **"Require client certificate"** checkbox.
- A **"Generate new cert"** button.
- A **"Download cert"** button (returns a `.p12` for the user's browser).

When the checkbox is on, the edge nginx layer enforces `ssl_verify_client on`
on the whole `:5443` vhost — UI, `/api/*`, `/ws/*`. No cert -> connection
refused before TLS upgrade. (Cookie/password login still works once you've
gotten through TLS.)

### Locked design decisions (don't re-litigate)

| Decision | Choice |
|---|---|
| Cert model | **Single shared cert.** No per-user. Re-generate to invalidate everyone. |
| Enforcement scope | **Edge-wide on `:5443`** — UI + `/api` + `/ws`. No "cert OR password" mode. |
| Lockout safety | **The checkbox is disabled until the user has clicked "Download cert".** Flipping it on shows a confirm dialog warning the cert must be installed in the browser before reload. |
| Initial scope | **Local dev only.** Other hosts only when explicitly requested. |

### What already exists in the repo

- `docker/nginx/nginx.mtls.conf` — full mTLS nginx config (already references
  `/run/ab-tls/server.crt`, `server.key`, `browser-ca.crt`, with
  `ssl_verify_client on; ssl_verify_depth 2;`).
- `docker-compose.browser-mtls.yml` — overlay that swaps the edge to mount
  `nginx.mtls.conf` plus `${AB_TLS_BROWSER_CA_MOUNT_SRC}` as
  `/run/ab-tls/browser-ca.crt`.
- `.env.example` already has `AB_TLS_BROWSER_CA_MOUNT_SRC` placeholder.

So the nginx side is solved — toggling on is "swap which compose overlay is
loaded". We just need the cert-issuing UX and the toggle wiring.

### Moving parts to build

1. **CA + leaf cert lifecycle** (back). Files under `state/edge-tls/`:
   - `ca.key` + `ca.crt` — 10-year self-signed root, generated on first
     "Generate new cert" click.
   - `client.p12` — leaf bundled with private key, password-protected (random
     password printed once on download? or fixed empty? recommend random,
     printed in download response headers + body).
   - The CA is what nginx mounts via `AB_TLS_BROWSER_CA_MOUNT_SRC`. Leaves
     are signed by it.

2. **Back endpoints** (FastAPI, `ab-back/server.py`):
   - `GET  /api/auth/client-cert/status` → `{has_cert: bool, required: bool, fingerprint: string?}`
   - `POST /api/auth/client-cert/regenerate` → 200, body irrelevant. Generates
     CA if absent, issues a new leaf, drops `state/edge-tls/client.p12`.
   - `GET  /api/auth/client-cert/download` → `application/x-pkcs12` body =
     the `.p12`. Header `X-P12-Password: <random>` so the front can show it
     to the user.
   - `POST /api/auth/client-cert/require {enabled: bool}` → flips a
     `settings.client_cert_required` row. The actual nginx-config swap is a
     separate concern (see #3).

3. **Edge-config swap** — back container has no docker socket, so it can't
   `docker compose up -d edge` itself. Two paths, pick at impl time:
   - **(a)** A tiny side container `edge-applier` that has `/var/run/docker.sock`
     mounted and watches `state/edge-tls/.apply` flag. Cleanest.
   - **(b)** UI shows a "Click here to apply" instruction with the exact
     `docker compose ...` line; user runs it manually. Simplest.
   - Recommend (b) for v1, (a) later.

4. **Front Settings panel** — there's already a Settings dialog (find it by
   grepping `Settings` in `ab-front/src/components/`). Add a new
   "Authentication" tab/section:
   - "Generate new cert" button → `POST /api/auth/client-cert/regenerate`.
   - "Download cert" button → `GET /api/auth/client-cert/download`, save as
     `ab-client.p12`, surface the `X-P12-Password` header value with a "Copy"
     button.
   - "Require client certificate" checkbox — disabled until `has_cert: true`.
     Flipping ON shows a `ConfirmDialog` with the warning text and an
     "I've installed the cert" confirmation.

5. **Recovery path docs** — if the user locks themselves out, they SSH in and
   either flip the `settings.client_cert_required` row or swap the edge
   compose overlay back. Mention this in the panel's tooltip.

### Files that will change

- `ab-back/server.py` — 4 new endpoints + cert-issuing helpers (use stdlib
  `cryptography` package for X.509; back's pyproject already pulls it in).
- `ab-front/src/api/auth.ts` (or new `clientCert.ts`) — fetch wrappers.
- `ab-front/src/components/SettingsDialog.tsx` (or wherever Settings is) —
  new "Authentication" section.
- `docker-compose.yml` (or a new override) — when applied, mount the
  generated CA + flip to `nginx.mtls.conf`.
- No ab-pty changes (this is browser-edge concern only, not daemon-edge).

### Verification when picked up

1. Generate cert → file appears under `state/edge-tls/client.p12`. Download
   it, install in browser keychain, reload page. Browser prompts to pick a
   cert; pick the AB one; UI loads.
2. Flip "Require client cert" on → confirm dialog → swap compose overlay →
   reload in a different browser without cert installed → `ssl_verify_client`
   refuses the connection.
3. Reload with the cert browser → still works.
4. Re-run "Generate new cert" → old cert is invalidated; downloading + installing
   the new one is required to get back in.

### Out of scope

- Per-user certs (would need a `users` table; current setup is single-user).
- Cert revocation list (single-cert model handles invalidation by
  re-issuing, no CRL needed).
- Cross-host coordination (each host has its own CA + leaf).
- Daemon-side mTLS (`back`->`pty`) — that's `docker-compose.daemon-mtls.yml`,
  separate concern.
