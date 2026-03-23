# AGENTS

This file is for agentic coding tools working inside Agent-Bridge (`ab`).

## Scope

Work only inside the current `ab` checkout and its child repos:
- `ab`
- `ab-back`
- `ab-front`
- `ab-pty`

Do not treat old repos outside this checkout as the active source of truth.

## Repository Model

- `ab` is the deploy/orchestration root
- each child folder is its own git repository
- root `ab` is also its own git repository
- changes should be committed in the repo that owns them

## Current Product Split

- `ab-back`: backend/API
- `ab-front`: main canvas frontend on `5281`
- `ab-pty`: PTY daemon

## Quick Setup

1. Ensure `.env` exists:

```bash
cp .env.example .env
```

2. Ensure `AB_JWT_SECRET_PATH` points to a real file:

```bash
mkdir -p state/back
openssl rand -hex 32 > state/back/jwt-secret
```

3. Bootstrap and start the default production-style stack:

```bash
scripts/bootstrap.sh
scripts/stack.sh up --mode prod
```

Default install mode includes one seeded docker demo agent plus its daemon container.

For a clean install without demo data:

```bash
scripts/stack.sh up --mode prod --skip-test-data
```

## Developer Setup

Development, test/demo, and local release work require the child repos at:
- `./ab-back`
- `./ab-front`
- `./ab-pty`

Start the bind-mount development stack with:

```bash
scripts/stack.sh up --mode dev
```

Default developer mode also includes the seeded `docker-demo-agent`.

For a clean dev stack:

```bash
scripts/stack.sh up --mode dev --skip-test-data
```

## Quick Verify

```bash
scripts/stack.sh ps --mode prod
curl http://127.0.0.1:8520/health
curl http://127.0.0.1:8520/api/auth/status
```

Frontends:
- `http://127.0.0.1:5281`

Default install also seeds:
- `docker-demo-agent`

## Test Stack

For an isolated clickable test environment with a fresh DB and two seeded docker remote agents:

```bash
scripts/test-up.sh
```

Required host tools:
- `docker`
- `docker compose`
- `bash`
- `curl`
- `python3`
- `realpath`

If the test stack already exists, the script prompts before tearing it down.
Answering `no` must leave the current test environment untouched and exit cleanly.

Before startup, `scripts/test-up.sh` must also fail fast if any of the test ports are already bound on `127.0.0.1`.

Expected test endpoints:
- `http://127.0.0.1:5381`
- `http://127.0.0.1:8620`
- `http://127.0.0.1:19421/health`
- `http://127.0.0.1:19422/health`

Expected test credentials:
- username: `admin`
- password: `admin`

Expected test agents:
- `docker-test-agent-1`
- `docker-test-agent-2`

Tear it down with:

```bash
scripts/test-down.sh
```

Host daemon deploy wizard:

```bash
scripts/daemon-deploy.ssh
```

Current contract:
- `scripts/daemon-deploy.ssh` must not build the daemon
- it downloads the published release artifact for the detected remote architecture
- local artifact mode is an explicit fallback only:
  - `scripts/build-daemon-artifact.sh`
  - `AB_PTY_ARTIFACT_SOURCE=local scripts/daemon-deploy.ssh`

The wizard is for deploying `ab-pty` to a remote host over SSH with:
- SSH mode prompt: alias from `~/.ssh/config` or host/user target with private key
- alias prompt in alias mode
- private key path and SSH port prompts in key mode
- release tag prompt in release mode
- overwrite confirmation for existing install
- optional JWT secret rotation
- optional onboarding JWT output at the end
- existing/no-overwrite mode must still print daemon address and onboarding JWT for manual agent creation

## Auth Contract

- browser auth is cookie-based
- backend issues `HttpOnly` session cookie `ab_session`
- do not reintroduce browser bearer auth via `localStorage`
- do not reintroduce `Authorization` header auth from frontend JS for normal browser flow
- do not expose PTY JWTs to browser clients
- do not mount host `~/.ssh` into containers by default
- do not mount host CA certificate files into containers by default
- any SSH key access inside containers must be an explicit manual operator choice, not the default stack behavior

## Safe Change Boundaries

If you change ports, paths, or startup flow, update:
- `README.md`
- `docs/DEPLOY.md`
- `docs/TOPOLOGY.md`

If you change auth behavior, verify:
- login
- logout
- frontend auth gate
- protected API access
- websocket auth

## Git / Release Notes

Current release tag used across repos:
- `v0.1.6`

Keep tags and commits per-repo. Do not assume one commit covers all child repos.
