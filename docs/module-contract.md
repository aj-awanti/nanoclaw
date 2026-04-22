# Module Contract

This doc is the authoritative reference for how core and modules connect. Everything downstream — extraction PRs, install skills, module authors — keys off these signatures and defaults. See [REFACTOR_PLAN.md](../REFACTOR_PLAN.md) for the broader plan; this doc is the narrow interface spec.

## Principles

- Core runs standalone (modulo default modules — see tiers below). The optional-module portion of the `src/modules/index.ts` barrel can be empty and NanoClaw still routes messages in and delivers responses out.
- Optional modules are independent. No optional module imports from another optional module. Cross-module coordination goes through a core registry (delivery action, response handler, etc.).
- Registries exist only when multiple modules plug into the same decision point. Single-consumer integrations use skill edits (`MODULE-HOOK` markers) or stay inline with `sqlite_master` guards.
- Removing an optional module = delete files + remove barrel imports + revert any `MODULE-HOOK` content. Migration files stay (data is preserved). Removing a default module is more invasive: it requires editing the core files that import from it.

## Module taxonomy

Three categories. All three live under `src/modules/` (or equivalent adapter dirs) with the same folder layout; the distinction is about **shipping** and **who can depend on them**.

### 1. Default modules

Ship with `main` in `src/modules/`. Imported by the default `src/modules/index.ts` barrel from day one. They are not really core — they live under `src/modules/` specifically to signal "not really core, rippable if needed" — but they're always present on a `main` install. Core imports from them directly. No hook, no registry indirection for the exports themselves.

Current: `typing`, `mount-security`.

### 2. Optional modules

Live on the `modules` branch. Installed via `/add-<name>` skills that cherry-pick files. Register into core via one of the four registries (or `MODULE-HOOK` skill edits). Core and other optional modules must not statically import an optional module's code.

Current: `interactive`, `approvals`, `scheduling`, `permissions`. Pending: `agent-to-agent`.

### 3. Channel adapters

Live on the `channels` branch, installed via `/add-<channel>` skills. Not covered by this contract; they use the pre-existing `ChannelAdapter` interface and `registerChannelAdapter()`.

## Dependency rule

```
core ← default modules ← optional modules
```

- **Core** may import from core and from default modules.
- **Default modules** may import from core and from other default modules. They must not import from optional modules.
- **Optional modules** may import from core and from default modules. They must not import from each other.

Peer-to-peer coupling between optional modules goes through a core registry — see "The four registries" below. This keeps the module dependency graph a DAG and install order irrelevant.

### Known transitional violations

- `src/access.ts` (core) imports from `src/modules/permissions/` (optional). Shim left from PR #5; resolved in the planned approvals re-tier (PR #7) which moves approver-picking into a new default `approvals-primitive` module that may then depend on permissions however it likes — at which point `src/access.ts` ceases to exist.

## The four registries

Each registry has an explicit default for when no module registers. Core must run when all four are empty.

### 1. Delivery action handlers

```typescript
// src/delivery.ts
type ActionHandler = (
  content: Record<string, unknown>,
  session: Session,
  inDb: Database.Database,
) => Promise<void>;

export function registerDeliveryAction(action: string, handler: ActionHandler): void;
```

**Purpose:** system-kind outbound messages (`msg.kind === 'system'`) carry an `action` string. Core dispatches to the registered handler.

**Default when action is unknown:** log `"Unknown system action"` at `warn` and return. Message is still marked delivered (it was consumed by the host, not sent to a channel).

**Current consumers:** scheduling (5 actions — `schedule_task`, `cancel_task`, `pause_task`, `resume_task`, `update_task`), approvals (2 actions — `install_packages`, `add_mcp_server`), agent-to-agent (`create_agent`, and the agent-routing branch keyed as a pseudo-action `agent_route`).

### 2. Router sender resolver + access gate

Two separate setters, called at different points in `routeInbound`. Preserves the pre-refactor ordering: sender-upsert side effects fire even when the message is ultimately dropped by wiring or trigger rules.

```typescript
// src/router.ts
type SenderResolverFn = (event: InboundEvent) => string | null;

export function setSenderResolver(fn: SenderResolverFn): void;

type AccessGateResult =
  | { allowed: true }
  | { allowed: false; reason: string };

type AccessGateFn = (
  event: InboundEvent,
  userId: string | null,
  mg: MessagingGroup,
  agentGroupId: string,
) => AccessGateResult;

export function setAccessGate(fn: AccessGateFn): void;
```

**Call order in `routeInbound`:**
1. Resolve messaging group.
2. **Sender resolver** (if set). Permissions upserts the users row here so the record exists even if agent resolution drops the message.
3. Resolve wired agents; `no_agent_wired` → record + drop. (Core writes the dropped_messages row.)
4. Pick agent by trigger rules; `no_trigger_match` → record + drop.
5. **Access gate** (if set). On refusal it writes its own `dropped_messages` row keyed by policy reason.

**Defaults when unset:** resolver returns null; gate defaults to `{ allowed: true }`. Every message routes through, no users table is needed, downstream tolerates `userId=null`.

**Current consumer:** permissions module (registers both).

**Not registries, setters.** There is one sender and one access decision per inbound message and one module that owns both. Calling `setSenderResolver` / `setAccessGate` twice overwrites; core does not iterate.

### 3. Response dispatcher

```typescript
// src/index.ts (or src/response-dispatch.ts if it grows)
interface ResponsePayload {
  questionId: string;
  value: string;
  userId: string | null;
  channelType: string;
  platformId: string;
  threadId: string | null;
}

type ResponseHandler = (payload: ResponsePayload) => Promise<boolean>;

export function registerResponseHandler(handler: ResponseHandler): void;
```

**Purpose:** button-click / question responses arrive via the channel adapter's `onAction` callback. Core iterates registered handlers in registration order. The first one that returns `true` claims the response.

**Default when empty:** log `"Unclaimed response"` at `warn` and drop.

**Current consumers:** interactive (matches `pending_questions`), approvals (matches `pending_approvals`). The two tables have disjoint `question_id` / `approval_id` namespaces in practice (`q-*` vs `appr-*`), so first-match-wins is safe.

### 4. Container MCP tool self-registration

```typescript
// container/agent-runner/src/mcp-tools/server.ts
export function registerTools(tools: McpToolDefinition[]): void;
```

**Purpose:** each tool module calls `registerTools([...])` at import time. The MCP server uses whatever was registered.

**Default:** only `mcp-tools/core.ts` (`send_message`) registered.

**Current consumers:** all container-side modules (scheduling, interactive, agents, self-mod).

## Skill edits to core

For one-off integrations with a single consumer, install skills edit core directly between `MODULE-HOOK` markers. No registry.

Marker format:

```typescript
// MODULE-HOOK:<module>-<site>:start
// MODULE-HOOK:<module>-<site>:end
```

The skill inserts between markers on install and clears between them on uninstall. Markers live in core from day one (empty until a skill fills them).

**Current uses:**

- `src/host-sweep.ts` → `MODULE-HOOK:scheduling-recurrence` — call to scheduling module's `handleRecurrence`.
- `container/agent-runner/src/poll-loop.ts` → `MODULE-HOOK:scheduling-pre-task` — call to scheduling module's `applyPreTaskScripts`.

**Promotion rule:** if a third consumer appears for any marker, promote to a registry.

## Guarded inline (core)

Some code stays in core but references module-owned tables. These use `sqlite_master` checks to degrade cleanly when the owning module isn't installed.

| Site | Owning module | Fallback |
|------|---------------|----------|
| `container-runner.ts` admin-ID query (`user_roles`, `agent_group_members`) | permissions | returns `[]` |
| `container-runner.ts` `writeDestinations` (`agent_destinations`) | agent-to-agent | no-op |
| `delivery.ts` channel-permission check (`agent_destinations`) | agent-to-agent | permit (origin-chat always OK) |
| `delivery.ts` `createPendingQuestion` (`pending_questions`) | interactive | no-op (log warning) |

Container-side admin gating no longer exists. Admin authorization is now performed host-side in `src/command-gate.ts`, which queries `user_roles` directly — no env var is passed to the container, and no agent-runner fallback exists.

## Migrations

All migrations live in `src/db/migrations/` as TypeScript files exporting a `Migration` object:

```typescript
export interface Migration {
  version: number;
  name: string;
  up: (db: Database.Database) => void;
}
```

The barrel `src/db/migrations/index.ts` imports each and lists them in an ordered array.

**Uniqueness key is `name`, not `version`.** The migrator applies any migration whose `name` isn't in `schema_version`. Version stays as an ordering hint; integer collisions across modules are allowed.

**Module migration naming:**

- File: `src/db/migrations/module-<module>-<short>.ts`
- `Migration.name`: `'<module>-<short>'` (e.g. `'approvals-pending-approvals'`)

**Uninstall behavior:** migration files and barrel entries stay. Tables persist across reinstalls. No down migrations.

## What a registry-based module provides

Each `src/modules/<name>/` module must supply:

- `index.ts` — imported by `src/modules/index.ts` for side-effect registration (calls `registerDeliveryAction` / `setInboundGate` / `registerResponseHandler` at module load time).
- `project.md` — appended to project `CLAUDE.md` by the install skill. Describes module architecture for anyone reading the codebase.
- `agent.md` — appended to `groups/global/CLAUDE.md` by the install skill. Describes the module's tools for the agent.
- Migration file in `src/db/migrations/` if the module owns any tables.
- Barrel entry in `src/db/migrations/index.ts` for that migration.

Optionally:

- Container-side additions to `container/agent-runner/src/mcp-tools/<name>.ts` that call `registerTools([...])`, with a barrel entry in `container/agent-runner/src/mcp-tools/index.ts`.
- `MODULE-HOOK` edits to specific core files, applied by the install skill.

## What a module must not do

- Import from another module.
- Write to core-owned tables (`sessions`, `agent_groups`, `messaging_groups`, `schema_version`, etc.) outside of migrations.
- Depend on a specific channel adapter being installed.
- Break core behavior when unloaded. If a module's absence leaves a core feature non-functional, that feature belongs in core, not the module.
