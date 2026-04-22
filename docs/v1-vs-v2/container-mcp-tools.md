# container mcp-tools: v1 vs v2

## Scope
- v1: `container/agent-runner/src/v1/mcp-tools.ts` (81 LOC) — single tool (`send_message`)
- v2: `container/agent-runner/src/mcp-tools/` — 7 modules (~971 LOC): `index.ts`, `core.ts`, `scheduling.ts`, `interactive.ts`, `agents.ts`, `self-mod.ts`, `types.ts`

## Tool map

| v1 tool | v2 file | Status | Schema / behavior diff |
|---|---|---|---|
| `send_message(text, channel, platformId, threadId)` | `core.ts:50-95` | **kept, enhanced** | v2 uses named destinations (`to`), auto-resolves via session default or lookup, preserves `thread_id` intelligently |
| — | `core.ts:133-177` `send_file` | **new** | Copies file to outbox dir, routes via destinations |
| — | `core.ts:179-218` `edit_message` | **new** | Edit previously-sent message by seq id |
| — | `core.ts:220-259` `add_reaction` | **new** | Emoji reaction by seq id |
| — | `scheduling.ts:33-79` `schedule_task` | **new** | One-shot or recurring (cron) |
| — | `scheduling.ts:81-137` `list_tasks` | **new** | Pending/paused tasks grouped by series |
| — | `scheduling.ts:139-165` `cancel_task` | **new** | |
| — | `scheduling.ts:167-192` `pause_task` | **new** | |
| — | `scheduling.ts:194-219` `resume_task` | **new** | |
| — | `scheduling.ts:221-266` `update_task` | **new** | Modify prompt/recurrence/processAfter/script |
| — | `interactive.ts:36-129` `ask_user_question` | **new** | Blocking with timeout — writes to outbound.db then polls inbound.db for response |
| — | `interactive.ts:131-166` `send_card` | **new** | Structured Chat SDK cards |
| — | `self-mod.ts` `install_packages` | **new** | apt/npm install, regex name validation, admin approval; approval handler auto-rebuilds image and restarts container |
| — | `self-mod.ts` `add_mcp_server` | **new** | Wire existing MCP server; approval handler restarts container (no image rebuild) |
| — | `agents.ts:30-63` `create_agent` | **new** | Admin-only sub-agent creation; not exposed to non-admin containers |

## New tools in v2
15 new tools split across 5 capability domains:
- **Message manipulation**: `send_file`, `edit_message`, `add_reaction`
- **Scheduling**: 6 task-management tools
- **Interactive**: `ask_user_question`, `send_card`
- **Self-modification**: `install_packages`, `add_mcp_server`
- **Agent management**: `create_agent`

## Missing from v2
**None.** v2 strictly adds; v1's only tool (`send_message`) was kept and enhanced.

## Behavioral discrepancies
1. **Destination resolution**: v1 used explicit channel/platformId/threadId params; v2 resolves named destinations from `destinations` map with fallback to session routing
2. **Two-DB split pattern**: all scheduling/self-mod tools write system actions to **outbound.db**; host processes (applies to inbound.db). Container never writes directly to inbound
3. **`ask_user_question` is blocking**: synchronously polls inbound.db until response arrives or timeout — agent perception is blocking, transport is async
4. **Admin enforcement**: `create_agent` + self-mod tools check admin approval host-side (`NANOCLAW_ADMIN_USER_IDS` env controls tool visibility)
5. **Message editing/reactions**: use internal seq id (not user-visible numeric message ID) — requires outbound.db lookup

## Transport pattern (v2 common)
1. Agent invokes tool → validation (regex, enum, length)
2. Tool writes `messages_out` or system-action row
3. Tool returns success immediately (fire-and-forget)
4. Host polls outbound.db, applies approval / routing / side effects

## Worth preserving?
**Yes, fully.** The v2 modular architecture is a large improvement:
- Clear separation by capability domain
- Two-DB constraint cleanly encoded (container → outbound, host → inbound)
- Named destination abstraction (better UX than raw JIDs)
- Admin-only tool filtering at the MCP server level

v1 is retained as historical reference only. No merge-back.
