# Shared Source

Replace per-group agent-runner-src copies with a single shared read-only mount.

## Problem

Each agent group gets a full copy of `container/agent-runner/src/` at creation time. This copy is mounted RW at `/app/src` in the container. Consequences:

- Bug fixes and features don't propagate to existing groups
- Owner edits to `container/agent-runner/src/` silently don't apply to existing groups
- No tooling to diff or detect drift between groups and upstream
- The RW mount lets agents write to their own runtime source without approval
- Cross-cutting changes (host + container) break down when container code is per-group
- Skills have the same copy-and-drift problem

## Design

**Principle: RW is per-group, RO is shared.** Every mount is either read-only and shared across all groups, or read-write and scoped to one group. Source and skills become RO + shared. Personality, config, working files, and Claude state stay RW + per-group. This makes drift impossible by construction — no group can diverge from shared code because no group has write access to it.

### Shared source mount

Mount `container/agent-runner/src/` into all containers at `/app/src` as **read-only**.

```
container/agent-runner/src/ → /app/src (RO, shared)
```

Source is never baked into the image. `/app/src/` exists only via this mount — running without it is an intentional startup failure (entrypoint `bun run /app/src/index.ts` → ENOENT). Source-only changes never trigger image rebuilds; edits to `.ts` files take effect on next container spawn.

Image rebuilds are only needed for:
- Agent-runner npm dependency changes (`package.json` / `bun.lock`)
- System packages, runtime versions, global CLI version bumps
- Dockerfile/entrypoint changes

### Shared skills mount

Mount `container/skills/` into all containers at `/app/skills/` as **read-only**.

Per-group skill selection via `container.json`:

```jsonc
{
  "skills": ["welcome", "agent-browser", "self-customize"]
  // or "skills": "all" (default)
}
```

At every spawn, the host syncs symlinks in the group's `.claude-shared/skills/` directory to match the selected set. For `"all"`, the set is recomputed from the shared skills dir on each spawn — newly-added upstream skills appear without intervention. Symlinks for skills no longer in the set are removed.

Each symlink points to a container path:

```
.claude-shared/skills/welcome → /app/skills/welcome
.claude-shared/skills/agent-browser → /app/skills/agent-browser
```

Claude Code scans `/home/node/.claude/skills/`, follows the symlinks, loads the selected skills. Same dangling-symlink-on-host pattern as `.claude-global.md` — host tools don't resolve the target, the container mount makes it valid at read time.

### Per-group customization surface

What remains per-group (unchanged):

| Resource | Location | Mechanism |
|----------|----------|-----------|
| Personality / instructions | `groups/<folder>/CLAUDE.md` | Mount at `/workspace/agent` (RW, live) |
| MCP servers | `groups/<folder>/container.json` | Env var at spawn |
| apt/npm packages | `groups/<folder>/container.json` | Per-group image layer |
| Skill selection | `groups/<folder>/container.json` | Symlinks at spawn |
| Additional mounts | `groups/<folder>/container.json` | Validated bind mounts |
| Agent provider / model | `groups/<folder>/container.json` | Read by runner at startup |
| Claude Code settings | `.claude-shared/settings.json` | Mount at `/home/node/.claude` (RW) |
| Working files | `groups/<folder>/` | Mount at `/workspace/agent` (RW) |

### Self-modification

Existing config-level self-mod tools (`install_packages`, `add_mcp_server`) mutate `container.json` and per-group images, not source. Unchanged — stays per-group.

Source-level self-modification (not yet implemented) uses staging: edits happen against a copy of `container/agent-runner/src/`, reviewed and swapped in on approval. Owner can also edit source directly.

## Environment variables

Env is for things read by code we don't own: glibc, Node's http agent, CLIs we shell out to. Everything NanoClaw-specific moves out of env.

**Stays in env (read by non-nanoclaw code):**

| Var | Reader |
|---|---|
| `TZ` | glibc, child processes |
| `HTTPS_PROXY`, `NO_PROXY` | Node http agent, curl, git, etc. (OneCLI-injected) |
| `NODE_EXTRA_CA_CERTS` | Node at startup (OneCLI-injected) |

**Moves to `container.json` (read by runner at startup):**

| Var | Reason |
|---|---|
| `AGENT_PROVIDER` | Per-group config; runner reads before importing provider module |
| `NANOCLAW_AGENT_GROUP_NAME` | Per-group identity |
| `NANOCLAW_ASSISTANT_NAME` | Per-group identity |
| `NANOCLAW_MAX_MESSAGES_PER_PROMPT` | Config constant; per-group override possible |

**Deleted (admin gating moves to router):**

`NANOCLAW_ADMIN_USER_IDS` is removed entirely — not moved to a new location. The container no longer makes authorization decisions. See **Router command gate** below.

**Hardcoded as conventions:**

| Var | Convention |
|---|---|
| `SESSION_INBOUND_DB_PATH` | `/workspace/inbound.db` |
| `SESSION_OUTBOUND_DB_PATH` | `/workspace/outbound.db` |
| `SESSION_HEARTBEAT_PATH` | `/workspace/.heartbeat` |
| `NANOCLAW_AGENT_GROUP_ID` | Read from `/workspace/agent/container.json` at startup |

### Runner startup order

The runner can no longer assume DB paths or provider identity are handed to it in env. Revised startup:

1. Set up logging.
2. Read `/workspace/agent/container.json` (mounted RW but read-only here).
3. Open `/workspace/inbound.db` and `/workspace/outbound.db` (fixed paths).
4. Read bootstrap tables from `inbound.db` (destinations).
5. Import the provider module selected by `container.json`.
6. Enter the poll loop.

### Router command gate

The host router gates slash commands before writing to `messages_in`. The container still handles whatever reaches it; it just stops making authorization decisions.

1. **Filtered commands** (`/help`, `/login`, `/logout`, `/doctor`, `/config`, `/start`, `/remote-control`) → drop silently. Never reach the container.
2. **Admin commands** (`/clear`, `/compact`, `/context`, `/cost`, `/files`) → check sender against `user_roles` (owners + global admins + admins scoped to this agent group).
   - Denied: write "Permission denied: `<cmd>` requires admin access." directly to `messages_out` in the same thread. Do not write to `messages_in`.
   - Allowed: pass through to container unchanged.
3. **Normal messages** → pass through unchanged.

Admin commands that flow through continue to be handled the same way they are today:
- `/clear` — container's existing handler in `poll-loop.ts` resets session continuation and writes "Session cleared."
- `/compact`, `/context`, `/cost`, `/files` — container forwards them to Claude Code's native slash-command handler.

Container receives only authorized messages. The runner has no admin concept, no `adminUserIds` field, no admin-gate branch — but it still recognizes `/clear` to reset session state.

### Scope rules

Each channel answers a single scope question:

| Channel | Scope | What it holds |
|---|---|---|
| Env vars | Process | Things read by code we don't own (`TZ`, `HTTPS_PROXY`) |
| `container.json` | Per-group | Per-group config (MCP, packages, provider, model, skills, mounts) |
| `inbound.db` / `outbound.db` | Per-session | Messages, session state, and host-projected views of cross-group state (destinations) |
| Central DB (`data/v2.db`) | Cross-group | Users, roles, wiring, messaging groups, sessions |

The runner reads from env (for external-convention vars), `container.json` (for its own group's config), and `inbound.db` (for messages + projected views). It never reads central DB directly — that's always host-projected through inbound.db first.

After this change, the spawn-time `-e` flags shrink from ~10 to ~3-5 (TZ + OneCLI networking). No `NANOCLAW_*` env var survives.

## Image layer strategy

Single Dockerfile with aggressive layer ordering: stable layers first, frequently-bumped layers last. BuildKit's layer cache handles "upstream layers unchanged" rebuilds efficiently — a separate base image isn't justified.

Two image tags exist at runtime:

```
nanoclaw-agent:latest          — shared base (rebuild: dep/CLI bumps + Dockerfile changes)
  └── nanoclaw-agent:<group>   — per-group apt/npm packages (rebuild: per-group via install_packages)
```

Layer order within the base:

```dockerfile
FROM node:22-slim

# System deps (apt) — rarely change
RUN apt-get install ...

# Bun — pinned version, rarely changes
RUN ... bun

# Agent-runner deps — cached independently of CLI versions
COPY agent-runner/package.json agent-runner/bun.lock /app/
RUN cd /app && bun install --frozen-lockfile

# Global CLIs — most stable first, most frequently bumped last
RUN pnpm install -g "vercel@${VERCEL_VERSION}"
RUN pnpm install -g "agent-browser@${AGENT_BROWSER_VERSION}"
RUN pnpm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"
```

Bumping claude-code (the most common change) only rebuilds one layer. Agent-runner deps and other CLIs stay cached.

Source is never baked into the image — always provided by the shared RO mount at runtime.

### Agent-triggered version bumps

Agents can request a claude-code version bump via a new self-mod tool (`bump_claude_code`). Same fire-and-forget pattern as `install_packages`: agent requests → owner approves → host rebuilds base image → kill all running containers. Unlike `install_packages` (per-group image), this rebuilds the shared base image and affects all groups.

## Changes

### `group-init.ts`

- Remove the `agent-runner-src` copy block (lines 109–117)
- Remove the `skills/` copy block (lines 100–107)
- Skill symlinks are no longer created at init — sync is spawn-owned (see `container-runner.ts`)

### `container-runner.ts` `buildMounts()`

- Remove per-group `agent-runner-src` mount (lines 206–209)
- Add shared RO mount: `container/agent-runner/src/` → `/app/src`
- Add shared RO mount: `container/skills/` → `/app/skills`
- Sync skill symlinks in `.claude-shared/skills/` at spawn: write desired set from `container.json` (`"all"` = every skill in the shared dir, recomputed per spawn), remove symlinks not in the set

### `container-runner.ts` `buildContainerArgs()`

- Remove `-e SESSION_INBOUND_DB_PATH`, `-e SESSION_OUTBOUND_DB_PATH`, `-e SESSION_HEARTBEAT_PATH` (hardcoded conventions now)
- Remove `-e AGENT_PROVIDER` (moves to `container.json`)
- Remove `-e NANOCLAW_ASSISTANT_NAME`, `-e NANOCLAW_AGENT_GROUP_ID`, `-e NANOCLAW_AGENT_GROUP_NAME`
- Remove `-e NANOCLAW_MAX_MESSAGES_PER_PROMPT`
- Remove the `user_roles` join + `-e NANOCLAW_ADMIN_USER_IDS` block (lines 269–287) entirely. Admin gating moves to the router — no admin data passed to the container.
- Keep: `-e TZ`, OneCLI-contributed env (`HTTPS_PROXY`, `NODE_EXTRA_CA_CERTS`, `NO_PROXY`)

### `router.ts` (new command gate)

- Classify inbound slash commands before writing to `messages_in`: filtered / admin / normal.
- Filtered (`/help`, `/login`, `/logout`, `/doctor`, `/config`, `/start`, `/remote-control`) → drop silently.
- Admin commands (`/clear`, `/compact`, `/context`, `/cost`, `/files`) from non-admins → write "Permission denied" directly to `messages_out`, skip `messages_in`.
- All authorized messages (admin commands from admins, and normal messages) → pass through unchanged to `messages_in`. Container handles them as today.
- The `ADMIN_COMMANDS` and `FILTERED_COMMANDS` lists move from `container/agent-runner/src/formatter.ts` to a host-side module.

### `container/agent-runner/src/` (runner)

- New `config.ts` module: loads `/workspace/agent/container.json` at startup, exposes a typed config singleton. All previous `process.env.NANOCLAW_*` reads go through this.
- `db/connection.ts`: use hardcoded paths `/workspace/inbound.db` and `/workspace/outbound.db`; drop `SESSION_*_DB_PATH` lookups.
- `formatter.ts`: remove `ADMIN_COMMANDS`, `FILTERED_COMMANDS`, and the `filtered` / admin-gate categorization. Keep enough to recognize `/clear` so `poll-loop.ts` can route it (e.g., a narrow `isClearCommand(msg)` helper).
- `poll-loop.ts`: remove `adminUserIds` field from config type and the admin-gate branch (lines 113–126). Keep the `/clear` handler (lines 128–142) — `/clear` still flows through from the router.
- Provider selection (`providers/index.ts` or equivalent): read provider from config singleton, not env.

### `container-config.ts`

- Add `skills` field to `ContainerConfig` (`string[] | "all"`, default `"all"`)
- Add fields: `provider`, `groupName`, `assistantName`, `maxMessagesPerPrompt` (optional, falls back to code default)

### `.env` / `.env.example`

- Remove any `NANOCLAW_*` entries that were documented as tunables. Update `.env.example` to list only TZ and OneCLI-related vars as valid overrides.

### DB migration

- Drop `agent_groups.agent_provider` column and `sessions.agent_provider` column. Source of truth becomes `container.json.provider`.
- One-time data migration reads existing values and writes them to each group's `container.json`. Sessions lose any per-session provider override — provider is a per-group property now.

### Migration

**This is a breaking change.** Host restart kills all running containers. No gradual rollout. Any code referencing dropped columns or removed env vars must be updated before the migration runs.

- Provider install skills (`/add-opencode`, `/add-ollama-tool`) now write to the shared `container/agent-runner/src/providers/` tree. The per-group `providers/` overlay pattern is removed. Any uncommitted provider overlays must be upstreamed before cutover.
- Delete existing `data/v2-sessions/<id>/agent-runner-src/` directories on first run after cutover.
- Existing `.claude-shared/skills/` directories get replaced with symlinks on next spawn.
- DB migration (see above) reads `agent_provider` columns and projects into `container.json`, then drops the columns.

## What triggers what

| Change | Action needed | Scope |
|--------|--------------|-------|
| Agent-runner `.ts` source | Kill running containers | All groups |
| Agent-runner npm deps | Rebuild `nanoclaw-agent` + kill all | All groups |
| System deps, Bun, Node | Rebuild `nanoclaw-agent` + kill all | All groups |
| Claude-code version bump | Rebuild `nanoclaw-agent` + kill all | All groups (agent-triggerable) |
| Skill content | Kill running containers | All groups |
| Per-group apt/npm packages | `buildAgentGroupImage()` + kill | One group |
| Per-group config (MCP, mounts, provider, model, skills) | Kill that group's containers | One group |
| CLAUDE.md, working files | Nothing (live via RW mount) | One group |
