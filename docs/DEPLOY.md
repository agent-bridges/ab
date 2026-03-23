# Agent-Bridge (AB) Deployment

## Scope
This document defines how the deploy root should launch Agent-Bridge services and how operators should choose between PTY deployment modes.

## Intended Operator Flow
The expected operator flow is:
1. clone the `ab` repo
2. create `.env` from `.env.example`; bootstrap should seed `AB_WORKSPACE_PATH` to the absolute `ab` repo path by default
3. run `scripts/bootstrap.sh` and `scripts/stack.sh up --mode prod` for the default production-style stack
   - default install also starts one docker demo agent and seeds it into the main backend database
   - use `scripts/stack.sh up --mode prod --skip-test-data` for a clean stack without demo data
4. optionally clone `ab-back`, `ab-front`, and `ab-pty` into matching folders inside `ab` for development, test/demo, and local release work
   - `scripts/stack.sh up --mode dev` uses those child repos as bind mounts
   - default dev mode also includes the internal docker demo agent
   - use `scripts/stack.sh up --mode dev --skip-test-data` for a clean dev stack
5. use `scripts/stack.sh up --mode dev` for the bind-mount development stack
6. optionally run `scripts/test-up.sh` for an isolated demo/test stack with seeded remote docker agents

`ab` is the single entry point. Operators should not have to manually stitch together sibling repos outside the `ab` directory.

## Deployment Model

### Deploy root responsibilities
The `ab` repo should own:
- `.env` and environment loading
- compose entrypoints
- production, development, and test compose files
- bootstrap/update scripts
- daemon artifact and host-deploy helpers
- service topology docs
- the contract for where child repos live inside `ab`
- the workspace bind mount contract via `AB_WORKSPACE_PATH`

Child repositories should own their application code, build logic, and service-specific runtime details.

## Workspace Path Contract

Local-agent flows depend on `back` and `pty` seeing the checked-out workspace at the same absolute path.

- `AB_WORKSPACE_PATH` must be an absolute path
- in the default layout it should point at the `ab` repo root
- `back` and `pty` must both bind-mount that path to the same absolute target inside their containers

Without this, session creation for paths like `/srv/ab` or `/lxd-exch/ab` will fail even if the services themselves are healthy.

## PTY Mode Selection

### Choose host daemon when
- the server is production-like and PTY needs broad host OS access
- systemd supervision is preferred
- Claude/Codex terminal behavior depends on host-level process visibility
- operator overhead for one extra host service is acceptable

### Choose docker daemon when
- the machine is already managed primarily through docker
- minimizing host-level setup matters more than strict production parity
- required PTY mounts and permissions can be provided cleanly
- auth and runtime persistence can be bound to durable storage

### Policy
- host daemon is the default recommendation
- docker daemon is an explicitly supported alternative, not a deprecated leftover
- one host should run one PTY mode at a time in steady state

## Runtime Topology

### Host daemon topology
```text
host
  systemd: ab-pty.service
  docker: backend
  docker: front

backend -> host.docker.internal:8421 -> PTY daemon
```

### Docker daemon topology
```text
docker compose
  backend
  front
  pty

backend -> pty:8421
```

## Runtime State Ownership

### Deploy root owns
- `.env`
- compose configuration
- operator-facing scripts
- host-level bind mount declarations
- default and test state roots under `state/`

### Service repos own
- service code
- Dockerfiles and build assets
- service-specific default config templates

### Persisted state that must be planned explicitly
- database files or DB connection settings
- TLS certs
- Claude auth state
- PTY runtime data
- any terminal/session persistence

These should not be left implicit inside ephemeral containers.

## Recommended Persistence Rules
- keep secrets and durable runtime state outside container layers
- mount PTY auth/runtime directories explicitly in both PTY modes
- document exact ownership for `.claude/`, `.claude.json`, PTY working data, and any session metadata
- prefer stable host paths or named volumes chosen by the deploy repo
- keep screenshots and operator docs in the deploy repo, not in service repos

## Secure Defaults
- PTY JWT material should stay in backend storage and should not be returned to browser clients
- browser flows should remain cookie-authenticated and should not expose PTY secrets to frontend code

## Startup Expectations

### Bootstrap phase
- validate `.env`
- ensure `AB_WORKSPACE_PATH` resolves to the actual `ab` checkout path
- in development mode, fail clearly if child repos are missing

### Launch phase
- in install mode, start backend/front from published images
- in install mode, build the local PTY runtime layer from the root repo and fetch the published `ab-pty` binary release
- in development mode, start backend/frontends/pty from the checked-out child repos with bind mounts
- verify backend to PTY connectivity

### Verification phase
- confirm PTY health endpoint or equivalent API
- confirm backend can create and observe terminal sessions
- confirm Claude/Codex status behavior works with the selected PTY mode

## Test Stack Expectations

The test stack is a separate compose project intended for demos and validation.

- `scripts/test-up.sh` should create isolated state under `state/test`
- it should seed a fresh test backend DB
- it should expose two remote docker PTY agents for multi-agent workflows
- it should not reuse the default stack database or runtime state

The current default test ports are:
- `5381` for `ab-front`
- `8620` for `ab-back`
- `19421` and `19422` for the two remote PTY agents

## Host Daemon Deployment

Host PTY deployment now defaults to a release-artifact flow:

- `scripts/daemon-deploy.ssh`

The current contract is:
- `daemon-deploy.ssh` downloads the published `ab-pty` release artifact for the detected remote architecture
- `daemon-deploy.ssh` uploads that binary to the remote host
- the wizard can either install/overwrite the daemon or inspect an existing install
- the wizard should return the daemon address and onboarding JWT needed for agent creation

Local artifact deployment remains available only as an explicit fallback:
- `scripts/build-daemon-artifact.sh`
- `AB_PTY_ARTIFACT_SOURCE=local scripts/daemon-deploy.ssh`

## Backward Compatibility
- deploy scripts may need to accept temporary compatibility shims during migration
- external documentation should prefer `ab` naming
