# Agent-Bridge (AB) Topology

## Goal
`ab` is the deploy/orchestration root. It is not a monorepo.

Each subsystem lives in its own git repository and is checked out into the deploy root at a known path.

The intended user flow is:
1. clone `ab`
2. run `scripts/stack.sh up --mode prod` for production-style startup
   - default install also includes one internal docker demo agent plus seeded backend row
   - use `scripts/stack.sh up --mode prod --skip-test-data` for a clean stack
3. optionally clone child repos into the expected folders inside `ab` for development, test/demo, and local release work
4. use `scripts/stack.sh up --mode dev` when bind-mount development is needed

## Target Repository Split

### Deploy root
- repo: `ab`
- responsibility:
  - deployment orchestration
  - compose files
  - `.env` handling
  - bootstrap and helper scripts
  - deployment docs
  - clone/update/launch contract for child repos

### Child repositories
- `ab-back`
  - backend server
  - DB logic and migrations
  - API contracts
- `ab-front`
  - new canvas/Miro-like frontend
- `ab-pty`
  - PTY daemon
  - Claude hooks
  - Codex PTY status heuristics
  - published daemon binaries

## Recommended Directory Layout

```text
ab/
  .env
  .env.example
  docker-compose.yml
  docker-compose.demo.yml
  docker-compose.dev.yml
  docker-compose.dev-demo.yml
  docker-compose.test.yml
  docs/
    TOPOLOGY.md
    DEPLOY.md
  scripts/
    bootstrap.sh
    build-daemon-artifact.sh
    daemon-deploy.ssh
    stack.sh
    test-up.sh
    test-down.sh
  ab-back/
  ab-front/
  ab-pty/
```

The folder names above are the contract. Compose and helper scripts should assume these exact paths.
The deploy root also owns one absolute workspace mount path, exposed as `AB_WORKSPACE_PATH`, and any workspace-backed PTY flow depends on that path being visible inside both `back` and `pty`.

Each child folder is expected to be its own git repository:
- `ab/.git`
- `ab/ab-back/.git`
- `ab/ab-front/.git`
- `ab/ab-pty/.git`

`ab` compose/bootstrap should treat those child repos as part of the development and test working layout.
The default production-style startup must not depend on those child repos being present.
The default development startup should include the same internal demo-agent layer unless explicitly disabled with `--skip-test-data`.

## PTY Modes

PTY is a first-class subsystem with two supported deployment modes.

### Mode 1: Host daemon
- PTY runs on the host as a service, typically `ab-pty.service`
- backend runs in docker
- frontend runs in docker or a dev container
- backend connects to PTY through `host.docker.internal:8421`
- this is the default mode for production-like servers

### Mode 2: Docker daemon
- PTY runs inside a local runtime container built from the deploy root
- backend and frontend continue to run under docker
- this mode is valid when the machine is already operated mainly through docker
- PTY runtime container still needs the required mounts, permissions, and persisted runtime/auth state

## PTY Policy
- both modes are supported as normal deployment choices
- operators choose one PTY mode per host
- mixed host-plus-container PTY on the same host should be avoided except during an explicit migration window
- backend integration should stay as uniform as possible across both modes:
  - same PTY API
  - same env contract
  - same persistence expectations

## Optional TLS Layers

### Browser TLS edge
- an optional `nginx` edge can sit in front of `front` and `back`
- browser traffic then goes through the edge over HTTPS
- browser mTLS is an optional second layer on top of that edge
- the default plain browser entrypoint remains supported unless operators explicitly move traffic to the TLS edge

### Remote daemon TLS / mTLS
- an optional TLS edge can also sit in front of a remote host daemon
- backend then talks to the remote PTY endpoint over `https://...`
- client certificates are the recommended hardening layer when a PTY daemon is exposed beyond a private network
- this keeps the PTY HTTP/WebSocket API shape unchanged while hardening the transport

## Test Topology

The deploy root owns two extra runtime layers on top of the base production compose:
- `docker-compose.demo.yml`
  - default install-time demo agent layer
- `docker-compose.dev-demo.yml`
  - default developer-mode demo agent layer
- `docker-compose.test.yml`
  - isolated disposable test stack
- `scripts/test-up.sh`
- `scripts/test-down.sh`

The test stack is meant for local validation and demos:
- isolated state under `state/test`
- test `ab-front`
- test `ab-back`
- two seeded remote docker PTY agents

This test environment should be treated as a separate runtime from the default stack.

## Legacy Compatibility
- external naming should converge on `ab`
- remaining internal runtime naming should be reduced incrementally rather than through a single destructive rename
