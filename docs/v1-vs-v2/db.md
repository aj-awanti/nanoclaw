# db: v1 vs v2

## Scope

**v1 (historical, not runtime):**
- `/Users/gavriel/nanoclaw4/src/v1/db.ts` (659 lines)
- `/Users/gavriel/nanoclaw4/src/v1/db.test.ts` (592 lines)
- `/Users/gavriel/nanoclaw4/src/v1/db-migration.test.ts` (60 lines)
- **Single database:** `<STORE_DIR>/messages.db` (better-sqlite3)
- No session/agent-runner separation; chat metadata + message history only

**v2 counterparts:**
- Central: `/Users/gavriel/nanoclaw4/src/db/*.ts` (index, schema, connection, 9 modules + 7 migrations)
- Session: `/Users/gavriel/nanoclaw4/src/db/session-db.ts` (200+ lines)
- Chat SDK state: `/Users/gavriel/nanoclaw4/src/state-sqlite.ts` (250+ lines)
- Docs: `docs/db.md`, `docs/db-central.md`, `docs/db-session.md`

---

## High-Level Shift

| Aspect | v1 | v2 |
|--------|----|----|
| **Database count** | 1 | 3 (central + per-session inbound + per-session outbound) |
| **Primary purpose** | Message history for a WhatsApp/multi-channel bot | Admin plane (identity, wiring, approvals) + per-session message queues |
| **Writer model** | Single process | Single writer per file (host writes central + inbound; container writes outbound) |
| **Schema evolution** | Ad-hoc ALTER TABLE in `createSchema()` | Versioned migrations in `src/db/migrations/` |
| **Multi-tenant** | No (one bot per instance) | Yes (multiple agent groups, isolation levels, approval flows) |
| **Key invariants** | Bot prefix filter, last-bot-timestamp cursor | Seq parity (even host, odd container), journal_mode=DELETE cross-mount visibility |

---

## Capability Map

| v1 Behavior | v2 Location | Status | Notes |
|-------------|-------------|--------|-------|
| **`chats` table** (jid, name, last_message_time, channel, is_group) | `messaging_groups` (central DB) | Kept, renamed | v1: chat metadata only, no messages stored. v2: per-platform chat, with `unknown_sender_policy`, routing to multiple agents. |
| **`messages` table** (id, chat_jid, sender, content, timestamp, is_from_me, is_bot_message, reply_to_*) | `messages_in` (session inbound) | Moved to session DB | v1: indexed by `timestamp`, filtered by bot prefix + flag. v2: indexed by `series_id` (recurring), seq-numbered, multi-kind (chat|task|system), host-written with even seq. Container reads pending/unprocessed. |
| **`scheduled_tasks` table** (id, group_folder, chat_jid, prompt, script, schedule_type, schedule_value, next_run, context_mode, status) | `messages_in` (session inbound, kind='task') | Moved to session messages | v1: separate table with status='active'\|'paused'\|'completed'. v2: unified into `messages_in` with kind='task', status per message. Scheduling engine lives in v2 `host-sweep.ts`. |
| **`task_run_logs` table** (task_id, run_at, duration_ms, status, result, error) | No direct counterpart | Removed | v2 doesn't persist task execution logs in DB; host-sweep handles recurrence in-memory and via `processing_ack` acks. |
| **`router_state` table** (key, value) | Not needed in v2 | Removed | v1: stored `last_timestamp`, `last_agent_timestamp` for polling cursor. v2: central DB and message tables eliminate need for manual state; routing is deterministic via `messaging_group_agents` and session queues. |
| **`sessions` table** (group_folder, session_id) | `sessions` (central DB) | Kept, extended | v1: maps group folder to session ID. v2: central registry: id, agent_group_id, messaging_group_id, thread_id, status, container_status, last_active. Keyed by `(agent_group_id, messaging_group_id, thread_id)` tuples. |
| **`registered_groups` table** (jid, name, folder, trigger_pattern, requires_trigger, is_main, container_config) | `agent_groups` (central DB) | Converted | v1: per-JID trigger; one agent per bot instance. v2: agent_groups independent of channels; multiple messaging_groups wire to each agent via `messaging_group_agents`. Container config moved to disk (`groups/<folder>/container.json`). |
| **Bot message filtering (is_bot_message flag + prefix)** | `messages_in` schema + container read filter | Kept, schema-level | v1: dual check (flag + `content LIKE 'Andy:%'` backstop). v2: container-side filtering in agent-runner. |
| **Reply context (reply_to_message_id, reply_to_content, reply_to_sender_name)** | `messages_in` columns | Kept | v1: nullable columns added via migration. v2: same schema, inherited from v1 shape. |
| **Chat metadata sync (last_message_time, channel, is_group)** | `messaging_groups` + lazy platform discovery | Converted | v1: timestamps in `chats.last_message_time`. v2: platform metadata in `messaging_groups`; `last_active` in `sessions` for activity tracking. |
| **Group discovery** (getAllChats) | Channel adapters + `messaging_groups` query | Removed from DB | v1: `getAllChats()` queries local DB. v2: adapters populate `messaging_groups` on first message; host discovers channels via routing, not polling DB. |
| **Message filtering by timestamp window** | `getNewMessages()`, `getMessagesSince()` with LIMIT subquery | Moved to session inbound | v1: queries with ORDER BY DESC, LIMIT N, then re-sort chronologically. v2: host writes to inbound; container polls. Cursor logic inverted (container drives processing, host feeds). |
| **Limit behavior (cap to N most recent)** | Hardcoded LIMIT 200 with timestamp filter | Kept, per-session | v1: `getNewMessages(limit=200)` by default. v2: `messages_in` has process-after and recurrence; container pulls per poll batch. |
| **Journal mode** | Not explicitly configured | DELETE (session), WAL (central) | v1: better-sqlite3 default (volatile). v2: `journal_mode=DELETE` on session DBs for cross-mount visibility; WAL on central DB for consistency. See `db/connection.ts:17` and `db/session-db.ts:15`. |
| **Foreign key constraints** | Soft (checked in code) | Hard (enforced in schema) | v1: no FK constraints. v2: all references are `REFERENCES table(id)` with implicit RESTRICT. Central DB enforces full FK graph. |
| **Pragmas** | Not set | `foreign_keys=ON`, `busy_timeout=5000` | v1: defaults only. v2: explicit, cross-mount-safe timeouts. |
| **Index coverage** | `idx_timestamp` on messages, `idx_next_run` on tasks, `idx_status` on tasks | Expanded | v1: 3 indexes. v2: series_id, user_roles scope, sessions lookup, agent_destinations target, pending_approvals action+status. |

---

## Schema Diff: Table-by-Table

### **Chats → Messaging Groups**

**v1 `chats` (PK: jid):**
```sql
jid, name, last_message_time, channel, is_group
```

**v2 `messaging_groups` (PK: id, UNIQUE: channel_type, platform_id):**
```sql
id, channel_type, platform_id, name, is_group, unknown_sender_policy, created_at
```

**Diff:**
- v1: jid is the platform ID directly (`"tg:123"`, `"group@g.us"`)
- v2: splits into `channel_type` ("telegram", "whatsapp") + `platform_id` (normalized ID)
- v1: no `unknown_sender_policy`; dropped messages silently
- v2: adds policy for first-time senders: `strict` (drop), `request_approval` (ask admin), `public` (allow)
- v1: `last_message_time` per chat; v2: moved to `sessions.last_active`
- **Table lifecycle:** `chats` is ephemeral in v2 (discovered lazily); `messaging_groups` is central registry

### **Messages → Messages In (Session)**

**v1 `messages` (PK: id + chat_jid):**
```sql
id, chat_jid, sender, sender_name, content, timestamp, is_from_me, is_bot_message,
reply_to_message_id, reply_to_message_content, reply_to_sender_name
```

**v2 `messages_in` (PK: id, UNIQUE: seq):**
```sql
id, seq, kind, timestamp, status, process_after, recurrence, series_id, tries,
platform_id, channel_type, thread_id, content
```

**Diff:**
- v1: single-session messages; chat_jid is the routing key
- v2: per-session inbound queue; platform_id + channel_type + thread_id from routing, not payload
- v1: sender/sender_name as columns
- v2: content is JSON (all fields, including sender, are inside)
- v1: `is_bot_message` flag
- v2: `kind` field (`'chat'`, `'task'`, `'system'`) replaces ad-hoc bot detection
- v1: no seq, no status, no recurrence
- v2: **seq invariant** — even numbers only (host-assigned); see `nextEvenSeq()` at `src/db/session-db.ts:75`
- v1: `reply_to_*` columns preserved in v2
- v1: indexed on timestamp; v2: indexed on series_id (for recurring task grouping)

### **Scheduled Tasks → Messages In + Processing**

**v1 `scheduled_tasks` (PK: id):**
```sql
id, group_folder, chat_jid, prompt, script, schedule_type, schedule_value, 
next_run, last_run, last_result, context_mode, status, created_at
```

**v2 spread across:**
- `messages_in` (host writes kind='task')
- `processing_ack` (container reads/writes status)
- No persistent `task_run_logs`

**Diff:**
- v1: tasks are a separate schema; v2: tasks are messages (kind='task')
- v1: `prompt`, `script`, `context_mode` in task row; v2: in JSON `content`
- v1: `schedule_type` (once, recurring), `schedule_value` (cron); v2: same, in `recurrence` field (cron string)
- v1: `next_run`, `last_run` tracked in table; v2: `process_after`, `status` in messages_in; recurrence logic in host-sweep
- v1: `last_result` stored; v2: no persistence; result is in container logs or delivery flow
- v1: status='active'|'paused'|'completed'; v2: status='pending'|'processing'|'completed'|'failed'|'paused' (per message, unified with chat)

### **Task Run Logs → Removed**

**v1 `task_run_logs` (PK: id auto-increment, FK: task_id):**
```sql
task_id, run_at, duration_ms, status, result, error
```

**v2:** Not in DB.

**Rationale:** v2 doesn't persist execution history in-DB; logs are streamed to host and written to operational logs. Task state is tracked via `processing_ack` status on the message itself, not a separate log table.

### **Router State → Removed**

**v1 `router_state` (PK: key):**
```sql
key (last_timestamp, last_agent_timestamp), value
```

**v2:** Not needed.

**Rationale:** v1 used this to track polling cursors across restarts. v2 uses message IDs and seq numbers; polling logic is implicit in the session queue architecture.

### **Sessions Table**

**v1 `sessions` (PK: group_folder):**
```sql
group_folder, session_id
```

**v2 `sessions` (PK: id):**
```sql
id, agent_group_id, messaging_group_id, thread_id, agent_provider, status, container_status, last_active, created_at
```

**Diff:**
- v1: simple folder → session mapping
- v2: full session tuple: agent group + messaging group + thread, with lookup index on (messaging_group_id, thread_id)
- v1: no status tracking; v2: `status` (active|paused|archived), `container_status` (stopped|starting|running)
- v2: `agent_provider` override per session
- v2: `last_active` timestamp for stale detection

### **Registered Groups → Agent Groups + Messaging Group Agents**

**v1 `registered_groups` (PK: jid):**
```sql
jid, name, folder, trigger_pattern, requires_trigger, is_main, added_at, container_config
```

**v2 split into:**
- `agent_groups` (PK: id): `id, name, folder, agent_provider, created_at` — container config on disk
- `messaging_group_agents` (PK: id): bridges messaging groups to agents with wiring rules

**Diff:**
- v1: one-to-one chat ↔ group; v2: many-to-many messaging group ↔ agent group
- v1: `trigger_pattern` on chat; v2: `trigger_rules` (JSON) on the `messaging_group_agents` wiring
- v1: `container_config` JSON in DB; v2: lives on disk at `groups/<folder>/container.json`
- v1: `requires_trigger`, `is_main` flags; v2: `session_mode` (shared|per-thread|agent-shared) on wiring

### **New v2 Tables (Central)**

**`users`:**
```sql
id, kind, display_name, created_at
```
Platform identities: `"tg:123"`, `"discord:abc"`, `"phone:+1555..."`, `"email:a@x.com"`. No v1 counterpart (permissions were implicit).

**`user_roles`:**
```sql
user_id, role (owner|admin), agent_group_id (NULL=global), granted_by, granted_at
```
v1 had no explicit permissions; v2 enforces owner/admin privilege with audit trail.

**`agent_group_members`:**
```sql
user_id, agent_group_id, added_by, added_at
```
Non-privileged user membership. v1: implied (everyone could message the bot).

**`user_dms`:**
```sql
user_id, channel_type, messaging_group_id, resolved_at
```
Cached DM channel discovery (avoids repeated API calls). No v1 equivalent.

**`pending_questions`:**
```sql
question_id, session_id, message_out_id, platform_id, channel_type, thread_id, title, options_json, created_at
```
Interactive multiple-choice questions. v1: no interactive prompts.

**`agent_destinations`:**
```sql
agent_group_id, local_name, target_type, target_id, created_at
```
Per-agent ACL and name-resolution map for `send_message(to="name")`. Projected into session inbound as `destinations` table (see db-session.md §2.3). v1: no permission model for outbound sends.

**`pending_approvals`:**
```sql
approval_id, session_id, request_id, action, payload, agent_group_id, channel_type, platform_id, platform_message_id, expires_at, status, title, options_json, created_at
```
Approval queue for `install_packages`, `add_mcp_server`, OneCLI credential flows. v1: no approval model.

**`unregistered_senders` (via migration 008):**
```sql
user_id, messaging_group_id, first_seen, last_seen
```
Audit trail of unknown senders (strict unknown_sender_policy). v1: silently dropped.

**Chat SDK tables (via migration 002):**
- `chat_sdk_kv` (key, value, expires_at)
- `chat_sdk_subscriptions` (thread_id, subscribed_at)
- `chat_sdk_locks` (thread_id, token, expires_at)
- `chat_sdk_lists` (key, idx, value, expires_at)

Backing store for Chat SDK state adapter. No v1 equivalent (Chat SDK didn't exist).

### **New v2 Session Tables (Inbound, Host-written)**

**`delivered`:**
```sql
message_out_id, platform_message_id, status, delivered_at
```
Host tracks delivery outcomes without writing to container-owned outbound.db.

**`destinations` (projection from central):**
```sql
name, display_name, type, channel_type, platform_id, agent_group_id
```
Local ACL cache; rewritten on every container wake. Container queries this live to authorize sends.

**`session_routing` (single-row table):**
```sql
id=1, channel_type, platform_id, thread_id
```
Default reply routing for the session. Allows container to default outbound messages without querying central DB.

### **New v2 Session Tables (Outbound, Container-written)**

**`messages_out`:**
```sql
id, seq (ODD), in_reply_to, timestamp, deliver_after, recurrence, kind, platform_id, channel_type, thread_id, content
```
Container-produced: chat replies, edits, reactions, cards, system actions. Seq always odd (container-assigned); see `src/db/session-db.ts:76` for parity logic.

**`processing_ack`:**
```sql
message_id, status (processing|completed|failed), status_changed
```
Container writes status for each message_in it touched. Host polls and syncs back into messages_in (avoids container writing inbound.db).

**`session_state` (KV):**
```sql
key, value, updated_at
```
Container persistent store (Chat SDK session ID, conversation state). Cleared by `/clear`.

---

## Missing from v2

1. **Per-message sender/sender_name columns** — moved into JSON `content`. Container unpacks on read.
2. **`task_run_logs` persistent history** — v2 streams logs to host; no in-DB history.
3. **`last_agent_timestamp` cursor state** — implicit in session message seq.
4. **Message filtering by bot prefix** — handled by container when writing to outbound; inbound doesn't filter.
5. **Direct chat timestamp tracking** — replaced by `sessions.last_active` and message timestamps.
6. **Single-writer assumption for one bot** — v2: one writer per file, across multiple agent groups (containers).

---

## Behavioral Discrepancies

### Sequence Numbering (Load-Bearing Invariant)

**v1:** No seq; messages identified by (id, chat_jid).

**v2:** 
- Host assigns **even** seq (2, 4, 6, …) to `messages_in`; see `nextEvenSeq()` at `src/db/session-db.ts:75–78`.
- Container assigns **odd** seq (1, 3, 5, …) to `messages_out`; see container logic at `container/agent-runner/src/db/messages-out.ts:54`.
- **Invariant:** seq is globally unique within a session across both tables. Parity disambiguates table membership for `edit_message(seq=5)` (odd → messages_out, even → messages_in).
- **If violated:** edits target wrong table; messaging breaks.

### Message Status Lifecycle

**v1:** `messages` are immutable once written; `scheduled_tasks` have status (active|paused|completed).

**v2:** `messages_in` have status (pending|processing|completed|failed|paused). Container writes status into `processing_ack`; host syncs back. Processing is non-blocking (container reads when status='pending').

### Journal Mode (Cross-Mount Visibility)

**v1:** Not configured (better-sqlite3 defaults to `PRAGMA journal_mode = memory` or implicit rollback).

**v2:** **`journal_mode = DELETE` on session DBs** (see `db/session-db.ts:15`), **WAL on central** (see `db/connection.ts:17`).

**Rationale:** v1 is single-process. v2 has host and container accessing the same session DBs across a Docker mount or Apple Container mount. WAL has issues with cross-mount visibility (rolled WAL files don't sync reliably); DELETE forces each write to flush the main file, so readers see the latest state.

### Unknown Sender Handling

**v1:** Silently dropped or stored with no policy tracking.

**v2:** `unknown_sender_policy` on `messaging_groups`: `strict` (drop), `request_approval` (admin card), `public` (allow). Dropped senders tracked in `unregistered_senders` audit table (migration 008).

### Recurring Tasks

**v1:** `scheduled_tasks.recurrence` (cron); `schedule_type` (once|recurring); status tracking in row.

**v2:** `messages_in.recurrence` (cron string), `series_id` (groups occurrences). Host-sweep recalculates next run via cron parser; no persistence. Status per message (pending|paused|completed).

### Chat Metadata Sync

**v1:** `getAllChats()` queries local DB; `last_message_time` updated by each message insert.

**v2:** Metadata lives in `messaging_groups` (central, discovered lazily by adapters). Activity tracked in `sessions.last_active`. No global "last message" timestamp per chat.

### Destinations and Permissions

**v1:** No model; all agents can send to all chats.

**v2:**
- Central: `agent_destinations` (source of truth)
- Session: `destinations` (projection in inbound.db, rewritten on wake)
- Container: queries `destinations` live; sends rejected if name not found
- Invariant: if wiring changes mid-session and `writeDestinations()` isn't called, container sees stale data

### Foreign Key Enforcement

**v1:** No constraints; referential integrity checked in code.

**v2:** All FKs enforced; central DB will reject orphaned references. Session DBs don't need as many FKs (immutable projections).

---

## Pragmas & Configuration

### v1

```javascript
// Implicit defaults — not set in code
```

### v2

**Central DB (src/db/connection.ts:17–18):**
```javascript
_db.pragma('journal_mode = WAL');
_db.pragma('foreign_keys = ON');
```

**Session Inbound (src/db/session-db.ts:23–24):**
```javascript
db.pragma('journal_mode = DELETE');
db.pragma('busy_timeout = 5000');
```

**Session Outbound (src/db/session-db.ts:31–32):**
```javascript
// Opens readonly
db.pragma('busy_timeout = 5000');
```

---

## Migrations

### v1
Adhoc `ALTER TABLE` in `createSchema()` (src/v1/db.ts:82–134):
- context_mode → scheduled_tasks
- script → scheduled_tasks
- is_bot_message → messages
- is_main → registered_groups
- channel, is_group → chats
- reply_to_* → messages

No versioning; all tables are `IF NOT EXISTS` and ALTERs are try-catch silent.

### v2
Numbered migrations in `src/db/migrations/` (1–9, note: 5–6 missing):

1. **001-initial.ts** — all core tables (agent_groups, messaging_groups, users, user_roles, agent_group_members, user_dms, sessions, pending_questions)
2. **002-chat-sdk-state.ts** — chat_sdk_kv, chat_sdk_subscriptions, chat_sdk_locks, chat_sdk_lists
3. **003-pending-approvals.ts** — pending_approvals table with action, payload, status
4. **004-agent-destinations.ts** — agent_destinations table + backfill from existing messaging_group_agents wirings
5. **(missing)**
6. **(missing)**
7. **007-pending-approvals-title-options.ts** — adds title, options_json columns to pending_approvals
8. **008-dropped-messages.ts** — unregistered_senders audit table
9. **009-drop-pending-credentials.ts** — cleanup (if any)

**Runner:** `runMigrations()` (src/db/migrations/index.ts:28–60) tracks version in `schema_version` table; applies pending migrations in transaction.

---

## Index Coverage

### v1

- `idx_timestamp` on `messages(timestamp)` — range queries for new messages
- `idx_next_run` on `scheduled_tasks(next_run)` — sweep query for due tasks
- `idx_status` on `scheduled_tasks(status)` — filter for active tasks
- `idx_task_run_logs` on `task_run_logs(task_id, run_at)` — log lookup

### v2

- `idx_user_roles_scope` on `user_roles(agent_group_id, role)` — permission queries
- `idx_sessions_agent_group` on `sessions(agent_group_id)` — session lookup per agent
- `idx_sessions_lookup` on `sessions(messaging_group_id, thread_id)` — resolve session from channel+thread
- `idx_messages_in_series` on `messages_in(series_id)` — recurring task grouping
- `idx_agent_dest_target` on `agent_destinations(target_type, target_id)` — reverse lookup (find agents that can send to this target)
- `idx_pending_approvals_action_status` on `pending_approvals(action, status)` — sweep query for pending/expired approvals

---

## Prepared Queries & Helpers

### v1 Helpers (src/v1/db.ts)

```
storeChatMetadata(jid, timestamp, name?, channel?, isGroup?)
  — INSERT OR REPLACE into chats (ON CONFLICT upsert)
  
storeMessage(NewMessage)
storeMessageDirect({id, chat_jid, sender, ...})
  — INSERT OR REPLACE into messages
  
getNewMessages(jids[], lastTimestamp, botPrefix, limit=200)
  — SELECT from messages, filter by jid list, timestamp > last, bot filter
  — Returns {messages, newTimestamp}
  
getMessagesSince(chatJid, sinceTimestamp, botPrefix, limit=200)
  — SELECT from messages, filter by chat, timestamp > since, bot filter, ORDER DESC + outer sort
  
getLastBotMessageTimestamp(chatJid, botPrefix)
  — SELECT MAX(timestamp) from messages WHERE (is_bot_message=1 OR content LIKE prefix)
  
createTask(ScheduledTask) / updateTask(id, fields) / getTaskById(id) / deleteTask(id)
  — Standard CRUD
  
getDueTasks()
  — SELECT * WHERE status='active' AND next_run <= now
  
updateTaskAfterRun(id, nextRun, lastResult)
  — UPDATE task set next_run, last_run, last_result, status
  
logTaskRun(TaskRunLog)
  — INSERT into task_run_logs
  
getRouterState(key) / setRouterState(key, value)
  — KV table
  
getSession(groupFolder) / setSession(groupFolder, sessionId) / deleteSession(groupFolder)
  — Simple mapping

getRegisteredGroup(jid) / setRegisteredGroup(jid, group) / getAllRegisteredGroups()
  — CRUD on registered_groups
```

### v2 Helpers

**Central DB (src/db/*.ts):**
- `createAgentGroup`, `getAgentGroup`, `getAgentGroupByFolder`, `updateAgentGroup`, `deleteAgentGroup`
- `createMessagingGroup`, `getMessagingGroup`, `getMessagingGroupByPlatform`, `updateMessagingGroup`, `deleteMessagingGroup`
- `createMessagingGroupAgent`, `getMessagingGroupAgents`, `getMessagingGroupAgentByPair`, `updateMessagingGroupAgent`, `deleteMessagingGroupAgent`
- `grantRole`, `revokeRole`, `getUserRoles`, `isOwner`, `isGlobalAdmin`, `isAdminOfAgentGroup`, `hasAdminPrivilege`
- `createUser`, `upsertUser`, `getUser`, `getAllUsers`, `updateDisplayName`, `deleteUser`
- `addMember`, `removeMember`, `getMembers`, `isMember`
- `upsertUserDm`, `getUserDm`, `getUserDmsForUser`, `deleteUserDm`
- `createSession`, `getSession`, `findSession`, `findSessionByAgentGroup`, `getSessionsByAgentGroup`, `getActiveSessions`, `getRunningSessions`, `updateSession`, `deleteSession`
- `createPendingQuestion`, `getPendingQuestion`, `deletePendingQuestion`
- `createPendingApproval`, `getPendingApproval`, `updatePendingApprovalStatus`, `deletePendingApproval`, `getPendingApprovalsByAction`

**Session DB (src/db/session-db.ts):**
- `ensureSchema(dbPath, 'inbound'|'outbound')` — idempotent schema setup
- `openInboundDb(dbPath)`, `openOutboundDb(dbPath)` — safe open with pragmas
- `nextEvenSeq(db)` — helper for host seq assignment
- `insertMessage(db, {id, kind, timestamp, platformId, channelType, threadId, content, processAfter, recurrence})`
- `insertTask(db, {id, processAfter, recurrence, ...})`
- `cancelTask(db, taskId)`, `pauseTask(db, taskId)`, `resumeTask(db, taskId)`
- `upsertSessionRouting(db, {channel_type, platform_id, thread_id})`
- `replaceDestinations(db, entries: DestinationRow[])`

---

## Key Invariants

### v1
- **Bot message filtering:** is_bot_message flag + content prefix as backstop (for pre-migration rows)
- **Cursor recovery:** getLastBotMessageTimestamp() to resume after stale downtime
- **Single writer:** Process that imports db.ts owns all writes; no IPC
- **Chat metadata immutability:** chats table updated only on metadata sync or first message, never deleted

### v2 (Load-Bearing)

1. **Single writer per file** — host writes central + inbound; container writes outbound only
2. **Seq parity invariant** — even in messages_in, odd in messages_out; parity disambiguates edit target
3. **Journal mode = DELETE on session DBs** — `DELETE` mode ensures cross-mount visibility (no WAL rollback issues)
4. **Foreign keys enforced** — central DB rejects orphans; schema_version tracks migrations
5. **Projection consistency** — `agent_destinations` (central) must be projected to `destinations` (session inbound) on every container wake; if wiring changes mid-session, must call `writeDestinations()` or container sees stale ACL
6. **Seq monotonicity** — no gaps, no reuse. `nextEvenSeq()` and container logic both scan MAX(seq) across both tables before assigning next
7. **Processing_ack as reverse channel** — container never writes to inbound.db; all status goes through outbound.db processing_ack, which host polls
8. **Heartbeat out of band** — `.heartbeat` file mtime is liveness signal, not a DB write; avoids serialization with message processing
9. **Admin at A implies membership in A** — invariant enforced in code (src/db/user-roles.ts, src/access.ts); no FK prevents deletion

---

## Worth Preserving?

**Yes — all v1 features are preserved or evolved:**
- Message history: v1 stores per-chat; v2 per-session. Content and metadata shapes mostly compatible.
- Scheduled tasks: v1 separate table; v2 unified into messages_in with kind='task'. Recurrence logic identical (cron).
- Bot filtering: v1 dual-check (flag + prefix); v2 single flag. Backstop logic removed (assumed migrated by now).
- Reply context: All v1 columns kept; v2 schema inherited.

**What's gone and why:**
- `task_run_logs` — v2 doesn't persist execution history; logging is operational only.
- `router_state` — v1 polling cursors; v2 implicit in message queuing.
- Single-bot assumption — v2 is multi-tenant; this is a feature, not a loss.

**Migration path:** v1 `src/v1/db-migration.test.ts` shows the pattern: create legacy table, init v2 schema, backfill. Migration 004 does this for agent_destinations (backfill from messaging_group_agents wirings).