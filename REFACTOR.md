# NanoClaw Refactor — Forward-Looking Reference

Consolidates what's still relevant from `REFACTOR_PLAN.md` and `REFACTOR_EXECUTION.md`: open decisions, remaining work, operational patterns worth keeping. Historical PR timeline and phase framing have been dropped — the work is in the commit history.

---

## Architecture (still authoritative)

### Module tiers

Three categories, distinguished by shipping model and dependency direction:

| Tier | Where it lives | Loaded by default? | Removal cost |
|------|----------------|--------------------|--------------|
| **Core** | `src/**` (outside `src/modules/`, `src/channels/`, `src/providers/`) | always | N/A — can't remove |
| **Default modules** | `src/modules/<name>/` on main | yes — imported by `src/modules/index.ts` | edit core imports (intentional friction) |
| **Optional modules** | `src/modules/<name>/` on main (for now — see open q #7) | yes, via barrel import | delete files + barrel line + revert `MODULE-HOOK` edits |
| **Channel adapters** | `src/channels/<name>.ts` on `channels` branch | no — cherry-pick via `/add-<name>` | delete files + barrel line |
| **Providers** | on `providers` branch | no — cherry-pick via `/add-<provider>` | delete files + barrel line |

Default modules today: `typing`, `mount-security`, `approvals`, `cli`.
Optional modules: `interactive`, `scheduling`, `permissions`, `agent-to-agent`, `self-mod`.

Dependency rule: **core ← default modules ← optional modules**. Optional modules must not depend on each other. Known transitional violation (flagged): `src/db/messaging-groups.ts` auto-wires `agent_destinations` when agent-to-agent is installed.

### The four registries

Full contract in [`docs/module-contract.md`](docs/module-contract.md). Summary:

1. **Delivery action handlers** — `delivery.ts`; modules call `registerDeliveryAction(name, fn)`.
2. **Router inbound gate** — `router.ts`; single setter (`setSenderResolver` + `setAccessGate`). Default: allow-all.
3. **Response dispatcher** — `response-registry.ts`; modules call `registerResponseHandler(fn)`. First to return `true` claims.
4. **Container MCP tool self-registration** — `container/agent-runner/src/mcp-tools/server.ts`; modules call `registerTools([...])` at import.

Anything else single-consumer uses either a `sqlite_master`-guarded inline read or a `MODULE-HOOK:<name>:start/end` skill edit.

### Module distribution (pending)

- **`main`** — core + default modules + default channel (`cli`). Ships clean.
- **`channels`** — fully loaded runnable branch with all channel adapters; skills cherry-pick from it.
- **`providers`** — same pattern for agent providers (OpenCode).
- **`modules` branch** — proposed but NOT created yet. See "Remaining work" below.

---

## Remaining work

### Phase 5: merge `v2` → `main`

Cut-over the refactor. Pre-reqs (already met): green build, green tests, green service boot, clean `channels` / `providers` syncs.

Open logistics:
- Release versioning: bump to `1.3.0` at merge time or cut a `v2-rc` tag first for internal testing? Non-blocking — decide at merge.
- Coordinate with anyone still running the old `main` (v1.2.53) — breaking change for them.
- Announce the new layout + the one shell command that changed (`pnpm run chat` is new default).

### `modules` branch — create, skip, or defer?

The original plan (PR #10) was to fork a `modules` branch and populate it with the 5 optional modules, so future `/add-<module>` skills pull via `git show origin/modules:path`. Three paths:

- **(a) Create it now.** Matches the `channels`/`providers` pattern for consistency. Extra surface to maintain: every core change must be merged into `modules` at phase boundaries (same cadence as channels/providers). Pays off if we ever want to make a module *truly* optional (not shipped on main).
- **(b) Skip it.** Leave all 5 optional modules shipped on main. No `modules` branch, no install skills, no cherry-picking. Simpler but loses the "opt-in" property for users who want a leaner install.
- **(c) Defer.** Ship main without the modules branch; create it later if someone actually wants to slim their install. No-cost option for now.

Recommendation leans toward (c) — we've already paid the architectural cost (tier boundary, dependency rule, registries) without needing the branch today.

### Per-module follow-ups (tracked as open questions below)

Each has a specific landing zone when we get to it:
- #11–13 (admin mechanism, providers registry, container-runner audit) — scope a focused cleanup pass.
- #14 (CLAUDE.md review) — single dedicated PR touching every module.
- #15 (A2A / destinations rethink) — requires design, not just cleanup.
- #17–18 (self-mod rethink, per-group source) — requires design.
- #19 (system vs user CLAUDE.md) — requires install-skill tooling.

---

## Operational patterns (keep using these)

### Standing checks for every PR

Non-negotiable; a unit test suite alone doesn't catch circular-import TDZ bugs:

1. `pnpm run build` clean.
2. `pnpm test` + `bun test` (in `container/agent-runner/`) all green.
3. **Service actually starts.** `gtimeout 5 node dist/index.js` (or `launchctl kickstart`) must reach `NanoClaw running`. Unit tests import individual files; only `main()` exercises the module-init order.
4. Expected boot log lines present (at least: `Central DB ready`, `Delivery polls started`, `Host sweep started`, `NanoClaw running`, plus any module lifecycle line like `OneCLI approval handler started` or `CLI channel listening`).

### Module architecture rule (TDZ bug, PR #3)

Any registry state a module writes to at import time must live in a file with **no back-edge to `src/index.ts`** — transitively. `src/index.ts` imports `src/modules/index.js` for side effects; if a module calls `registerX()` at top level and `X` lives in `src/index.ts`, the ES module loader hits a TDZ reference on the const declaration. Fix: registry state lives in its own dependency-free file (e.g. `src/response-registry.ts`). Any new registry follows the same pattern.

### Branch sync procedure

After every `v2` (or future `main`) sync into `channels` / `providers` / future `modules`:

1. **File-presence diff.** Enumerate files that existed pre-sync but are missing post-sync:
   ```
   git ls-tree -r <pre-sync>  | awk '{print $4}' | sort > /tmp/pre.txt
   git ls-tree -r <post-sync> | awk '{print $4}' | sort > /tmp/post.txt
   comm -23 /tmp/pre.txt /tmp/post.txt
   ```
   Classify each missing file:
   - **Intentional** (core deleted it) → leave deleted.
   - **Branch-owned** (channels branch still needs it) → restore from pre-sync HEAD.

   This has caught real losses on both `channels` (17 adapter files plus 3 setup scripts after PR #2's channel move) and `providers` (opencode files after PR #2).

2. **Cross-file consistency.** When restoring a file, check whether something *else* that also changed references it (e.g. `setup/index.ts`'s `STEPS` map).

3. **Run the standing checks** against the synced branch (not just v2).

### Prettier drift pattern

The `format:fix` pre-commit hook sometimes reformats peer files *after* the commit completes, leaving cosmetic-only diffs in the working tree. Discard with `git checkout -- <files>`. Do not re-commit the drift — it's trivial whitespace and noise.

---

## Open questions (curated)

### Design / architecture

1. **`NANOCLAW_ADMIN_USER_IDS` as the admin mechanism.** Host queries `user_roles` at container wake, collapses into env var, container compares sender IDs. Conflates identity-at-send with privilege-at-wake and forces the container to care about namespaced user IDs. Revisit during a container-runner audit.

2. **Host-side `src/providers/` registry.** One real consumer (OpenCode). A registry is probably overkill — the install skill could just edit `container-runner.ts` via `MODULE-HOOK`. Fold into the container-runner audit.

3. **Container-runner audit.** `src/container-runner.ts` has accreted wake/spawn/kill, mount assembly, OneCLI credential application, admin-ID env var, idle timers, image rebuild. Some pieces should pull apart or move into modules. Not blocking. Related to #1 and #2.

4. **Revisit destinations + A2A capability holistically.** The destination projection invariant, dual-purpose routing+ACL table, channel vs agent destination shapes, `createMessagingGroupAgent` auto-wire coupling — more machinery than the feature warrants. Phase 3 moved it out of core intact; a redesign is warranted but scoped post-refactor.

5. **Self-mod approach rethink.** _Partially addressed_ — the redundant `request_rebuild` tool was removed; approval of `install_packages` now bundles rebuild + container restart, and `add_mcp_server` approval restarts without rebuilding (bun runs TS directly). Still to consider: collapsing `install_packages` + `add_mcp_server` into a single "apply this container-config diff" approval primitive to reduce post-rebuild latency further.

6. **Per-agent-group source / per-group base image.** Self-mod today layers packages/MCP on a shared base. As groups diverge (different base images, provider configs, runtime toolchains), the shared-base assumption won't scale. Scope post-refactor.

### Distribution / operational

7. **Providers on a consolidated `modules` branch?** Staying separate for now. Revisit if a second optional provider appears.

8. **Per-group module enablement.** Modules are currently project-wide. If one agent group wants approvals and another doesn't, we'd need per-group feature flags. Flag if asked.

9. **Module removal UX.** We do not drop tables on uninstall. Is that the right default? (Alternative: `/remove-<module>` optionally runs a down migration. YAGNI until requested.)

10. **Cross-module ordering for the response dispatcher.** Registration order determines who claims a given `questionId`. IDs are disjoint in practice (`q-…` vs `appr-…`), so first-match-wins is safe. If a third response-consuming module arrives, we may need keyed dispatch.

11. **Versioned module migrations.** Reinstalls are idempotent (migrator skips anything already in `schema_version`). If a module ships a *new* migration in a later version, the install skill must append the new file + barrel entry without touching prior ones. Simplest rule: install skills are additive; content changes to an already-applied migration are a hard error.

12. **Telegram pairing imports from permissions (channels branch).** `src/channels/telegram.ts` reaches into `src/modules/permissions/db/*` for `grantRole`/`hasAnyOwner`/`upsertUser` in the pairing-bootstrap branch. Cross-branch tier violation. Fix: extract those writes into a pairing helper (e.g. `src/channels/telegram-pairing-accept.ts` or `setup/pair-telegram.ts`). Non-blocking.

### Core slotting (files not explicitly discussed)

13. **`state-sqlite.ts`, `webhook-server.ts`, `timezone.ts`.** state-sqlite is likely core (host tracker). Webhook-server likely core (channel infra). Timezone likely core utility. Confirm if any of them prove to be module-shaped during future audits.

14. **Chat SDK bridge location.** `src/channels/chat-sdk-bridge.ts` is channel infra that bridges adapters on the `channels` branch. Stays in `src/channels/` for now.

15. **OneCLI credential injection.** Lives in `container-runner.ts`. Every agent call uses it, no clean optional boundary. Stays core. Related: `onecli-approvals.ts` is bundled inside the `approvals` default module on the assumption OneCLI stays in core. If OneCLI later moves to its own module, `onecli-approvals` follows.

### Documentation

16. **CLAUDE.md content per module.** Every module ships with project.md + agent.md. Need a dedicated review pass: (a) write the missing agent-to-agent snippets, (b) audit other modules for accuracy/tone, (c) confirm `agent.md` files are actually tailored for the agent vs. copy-pastes of `project.md`.

17. **Split system CLAUDE.md from user CLAUDE.md.** Project `CLAUDE.md` and `groups/global/CLAUDE.md` mix system-authored content (module contracts, install-skill appends) with user customizations. Updates currently risk clobbering user intent. Look at a system-owned region (or separate file) that skills rewrite freely plus a user-owned one that's never touched. Related to #16.

---

## Where the canonical references live

- **Module contract** — [`docs/module-contract.md`](docs/module-contract.md)
- **Architecture overview** — [`docs/architecture.md`](docs/architecture.md)
- **DB layout** — [`docs/db.md`](docs/db.md), [`docs/db-central.md`](docs/db-central.md), [`docs/db-session.md`](docs/db-session.md)
- **Agent-runner internals** — [`docs/agent-runner-details.md`](docs/agent-runner-details.md)
- **Channel isolation model** — [`docs/isolation-model.md`](docs/isolation-model.md)
- **Build + runtime split** — [`docs/build-and-runtime.md`](docs/build-and-runtime.md)
- **Top-level** — [`CLAUDE.md`](CLAUDE.md)

This doc (`REFACTOR.md`) is transient — prune when open questions close; retire entirely once the refactor is fully behind us and the operational patterns have been absorbed into `CLAUDE.md` or `docs/`.
