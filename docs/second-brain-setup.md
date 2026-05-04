# Second Brain Setup Guide

End-to-end guide for deploying NanoClaw as a **compounding-memory personal assistant** on EC2 with Telegram, Ollama embeddings, and the Karpathy Wiki knowledge base.

---

## Architecture

```
You (Telegram) → EC2 (NanoClaw host) → Docker container (Claude agent)
                                       ↓
                              Ollama (nomic-embed-text)
                                       ↓
                         Knowledge Graph + Wiki Pages
```

**Three-layer memory system:**
1. **Raw Sources** — articles, transcripts, notes fed to the agent
2. **Knowledge Graph** — structured facts with semantic retrieval (SQLite + Ollama embeddings)
3. **Wiki Pages** — synthesized narratives organized by entities, concepts, timelines

---

## Prerequisites

- AWS account with `cli-admin` profile configured locally
- Secrets already in AWS Secrets Manager (region must match the deploy region):
  - `nanoclaw/anthropic-credential` — Anthropic credential. Either an API key
    (`sk-ant-api-...`) or a Claude Code OAuth token (`sk-ant-oat-...`). The
    bootstrap script auto-detects which env var to use. Store as a plain
    string or as a JSON object with one string value (the helper handles both).
  - `nanoclaw/telegram-bot-token` — Telegram bot token from @BotFather
- Your fork pushed and reachable: `https://github.com/aj-awanti/nanoclaw` (must be public, the bootstrap clones over HTTPS without auth)

---

## Step 1: Create Telegram Bot

1. Open Telegram and search for **@BotFather**
2. Send `/newbot`
3. Choose a name (e.g., "My Second Brain")
4. Choose a username (e.g., `my_secondbrain_bot`)
5. Copy the bot token
6. Store it in AWS Secrets Manager as `nanoclaw/telegram-bot-token`

**Optional settings via @BotFather:**
```
/setdescription — "Personal knowledge assistant"
/setabouttext — "I remember everything you tell me"
/setuserpic — upload an avatar
```

---

## Step 2: Provision EC2 Instance

From your local machine:

```bash
bash scripts/provision-ec2.sh us-west-2
```

This creates:
- IAM role with SSM + Secrets Manager access
- Security group with no inbound rules
- t4g.large instance (Graviton, 8GB RAM, 40GB gp3)

Note the **Instance ID** from the output.

---

## Step 3: Bootstrap the Instance

Connect via Session Manager:

```bash
aws ssm start-session --profile cli-admin --region us-west-2 --target <INSTANCE_ID>
```

Once inside, download and run the bootstrap script:

```bash
# Option A: If you have the script on S3 or can paste it
curl -o ec2-bootstrap.sh https://raw.githubusercontent.com/aj-awanti/nanoclaw/main/scripts/ec2-bootstrap.sh
sudo bash ec2-bootstrap.sh

# Option B: Copy-paste the entire ec2-bootstrap.sh content into the terminal
```

The bootstrap installs everything: Node 20, pnpm, Docker, Ollama (bound on `0.0.0.0:11434` so the agent container can reach it), Claude Code CLI, clones your fork, configures `.env`, builds the container, pulls `nomic-embed-text`, and registers the systemd service (not started yet).

---

## Step 4: Install Skills via Claude Code

Skill installs modify the container/group skeleton, so they must run **before** `nanoclaw.sh` wires the first agent. From the SSM session:

```bash
sudo -iu nanoclaw
cd nanoclaw-v2
source ~/.nvm/nvm.sh
claude   # opens Claude Code in the project root
```

Inside Claude Code, run these in order:

```
/use-native-credential-proxy   # we use AWS Secrets Manager, not OneCLI
/add-telegram                  # Telegram channel adapter
/add-ollama-tool               # MCP tool for Ollama inference + embeddings
/add-karpathy-llm-wiki         # SQLite knowledge graph + wiki synthesis
```

What each one gives you:
- **`use-native-credential-proxy`** — reads creds from `.env` and injects them into container API requests; no OneCLI gateway needed
- **`add-telegram`** — installs the Telegram channel adapter from the `channels` branch and wires it into `src/channels/`
- **`add-ollama-tool`** — gives the agent Ollama as an MCP server so it can call local models for embeddings and inference
- **`add-karpathy-llm-wiki`** — installs the wiki knowledge base: extraction → SQLite-backed knowledge graph with semantic retrieval via Ollama → recall (auto-injected on every invocation) → synthesis into entities/concepts/timelines

Quit Claude Code (`/exit`) when these complete.

---

## Step 5: Wire the First Agent

Still as the `nanoclaw` user, from the project root:

```bash
bash nanoclaw.sh
```

The interactive setup will:
1. Detect the existing `.env` with credentials
2. Wire Telegram messaging groups to an agent group
3. Build and test the container
4. Trigger a welcome DM to confirm the loop works

---

## Step 6: Wire Voice Transcription

```bash
bash /opt/nanoclaw/bin/wire-voice.sh
```

This auto-discovers the agent group you just created, attaches `/opt/whisper` as a read-only mount, and seeds the agent's `CLAUDE.local.md` with voice-handling instructions. See the [Voice Notes section](#voice-notes-whispercpp) below for accuracy tuning.

---

## Step 7: Start the Service

```bash
sudo systemctl start nanoclaw
sudo journalctl -u nanoclaw -f
```

Send a message to your Telegram bot to confirm it routes end-to-end. Send a voice note to confirm whisper transcription works.

### Knowledge Store Configuration

After the wiki skill is installed and an agent is running, configure:
- **Global store** — shared knowledge readable by all agent groups
- **Local store** — per-group memory, writable only by that group's agent

---

## Usage

### Feeding Knowledge

Send content to your Telegram bot to build the knowledge base:

```
@bot ingest this article: [paste or forward article]
@bot remember: The quarterly review is on March 15th
@bot extract facts from this transcript: [paste transcript]
```

### Querying Knowledge

The agent automatically recalls relevant facts on every message. You can also explicitly query:

```
@bot what do you know about [topic]?
@bot summarize everything about [person/project]
@bot show me the timeline for [event]
```

### Wiki Synthesis

Trigger wiki page generation:

```
@bot synthesize a wiki page about [entity]
@bot update the wiki for [concept]
@bot create a timeline page for [project]
```

### Scheduled Tasks

Set up recurring knowledge work:

```
@bot every morning at 8am, summarize any new articles I've sent
@bot every Friday, compile a weekly knowledge digest
```

---

## Voice Notes (whisper.cpp)

The bootstrap installs a self-contained voice pipeline at `/opt/whisper`:

| Path | Purpose |
|------|---------|
| `/opt/whisper/build/bin/whisper-cli` | whisper.cpp CLI |
| `/opt/whisper/models/ggml-small.en.bin` | English-only model, ~466MB, ~6% WER |
| `/opt/whisper/ffmpeg` | Static ARM64 ffmpeg (used inside the container) |
| `/opt/whisper/transcribe` | Single-call wrapper: audio → text |
| `/opt/whisper/vocab.txt` | Names/jargon to bias the decoder (you edit) |

The wrapper handles silence-trim, loudness-normalize, vocab-prompt, and PCM conversion. The agent invokes it as one command — no piping.

**Wiring (after `bash nanoclaw.sh` creates your first agent):**

```bash
sudo -iu nanoclaw
bash /opt/nanoclaw/bin/wire-voice.sh
sudo systemctl restart nanoclaw
```

That helper:
1. Adds `/opt/whisper` to the agent group's `container.json` (read-only mount)
2. Appends voice-handling instructions to the group's `CLAUDE.local.md`

The mount allowlist at `/opt/nanoclaw/.config/nanoclaw/mount-allowlist.json` is pre-seeded by bootstrap to allow `/opt` (read-only).

**Improving accuracy with `vocab.txt`:**

Edit `/opt/whisper/vocab.txt` and add proper nouns, project names, and jargon — one per line. The wrapper passes them as an initial prompt that strongly biases the decoder. No restart needed; takes effect on next transcription.

**Choosing a different model:**

```bash
# Larger, multilingual model (3.1GB, ~3% WER, ~5x slower)
bash /opt/whisper/models/download-ggml-model.sh large-v3

# Then update the wrapper to point at it:
sudo sed -i 's|ggml-small.en.bin|ggml-large-v3.bin|' /opt/whisper/transcribe
sudo sed -i 's| -l en | |' /opt/whisper/transcribe   # let it auto-detect language
```

Available models: `tiny.en`, `base.en`, `small.en` (default), `medium.en`, `large-v3`. English-only models are faster and slightly more accurate on English than the multilingual variants of the same size.

---

## Backups

A daily systemd timer (`nanoclaw-backup.timer`) runs at **04:00 UTC** and uploads a SQLite-safe snapshot to S3.

**What's backed up:**
- `data/v2.db` (central DB) and all `data/v2-sessions/<sid>/*.db` — taken via `sqlite3 .backup` so WAL/checkpointing is consistent
- `groups/` — agent CLAUDE.md, skills, per-group state (excluding their own DBs, which are picked up above)
- `.env` (saved as `env.bak` in the archive)

**Bucket:** `s3://nanoclaw-backup-<account-id>-<region>/daily/`. Versioning is on; lifecycle transitions to STANDARD_IA at 30 days, GLACIER_IR at 90 days; noncurrent versions expire after 365 days.

### Verify the timer

```bash
sudo systemctl list-timers nanoclaw-backup.timer
sudo systemctl status nanoclaw-backup.service
```

### Trigger a test backup now

```bash
sudo systemctl start nanoclaw-backup.service
sudo journalctl -u nanoclaw-backup.service -n 50
aws s3 ls s3://nanoclaw-backup-<account-id>-<region>/daily/ --profile cli-admin
```

### Restore

```bash
# 1. Stop the host so nothing writes to the DBs
sudo systemctl stop nanoclaw

# 2. Pick a snapshot
aws s3 ls s3://<bucket>/daily/

# 3. Pull and unpack into a temp dir
aws s3 cp s3://<bucket>/daily/<TS>.tar.gz /tmp/restore.tar.gz
mkdir /tmp/restore && tar -xzf /tmp/restore.tar.gz -C /tmp/restore

# 4. Replace state (after sanity-checking)
sudo -u nanoclaw rsync -a /tmp/restore/data/    /opt/nanoclaw/nanoclaw-v2/data/
sudo -u nanoclaw rsync -a /tmp/restore/groups/  /opt/nanoclaw/nanoclaw-v2/groups/

# 5. Restart
sudo systemctl start nanoclaw
```

Local retention is 14 days at `/opt/nanoclaw/backups/`.

---

## Merging Upstream Updates

Your fork tracks upstream NanoClaw:

```bash
cd /opt/nanoclaw/nanoclaw-v2
git fetch upstream
git merge upstream/main
pnpm install --frozen-lockfile
pnpm run build
./container/build.sh
sudo systemctl restart nanoclaw
```

Or use the NanoClaw skill (in Claude Code):
```
/update-nanoclaw
```

---

## Adding More Agents

Each agent group is isolated with its own container, memory, and knowledge store:

```bash
# In Claude Code:
/init-first-agent    # Creates a new agent group
/manage-channels     # Wire channels to agent groups
```

Examples:
- **Research agent** — dedicated to ingesting and synthesizing research papers
- **Work agent** — tracks projects, meetings, decisions
- **Personal agent** — daily life, reminders, personal knowledge

Each agent has its own `groups/<name>/CLAUDE.md` with personality and instructions.

---

## Monitoring

```bash
# Service status
sudo systemctl status nanoclaw

# Live logs
sudo journalctl -u nanoclaw -f

# Ollama status
systemctl status ollama
ollama list   # shows loaded models
```

---

## Tearing It All Down

When you're done (or need to redo provisioning from scratch):

```bash
# Default: terminates EC2, deletes SG/IAM, PRESERVES S3 backup bucket
bash scripts/teardown-ec2.sh

# Also wipe the S3 backup bucket (irreversible — your knowledge graph)
bash scripts/teardown-ec2.sh --purge-backups

# Skip confirmation prompt (use with care)
bash scripts/teardown-ec2.sh -y --purge-backups
```

The script discovers what exists, prints a summary, prompts for confirmation, then unwinds in dependency order: instances → security group → instance profile → role policies → role → (optionally) S3 bucket.

It's safe to re-run: missing resources are skipped, not errors.

---

## Cost Estimate

| Component | Monthly Cost |
|-----------|-------------|
| t4g.large (on-demand) | ~$55 |
| 40GB gp3 EBS | ~$3 |
| Data transfer (outbound) | ~$1-5 |
| Anthropic API (usage-dependent) | ~$10-50 |
| **Total** | **~$70-115/mo** |

**Cost optimization:**
- Use a Savings Plan or Reserved Instance for ~40% savings
- Stop instance when not needed (`aws ec2 stop-instances`)
- Task pre-check scripts avoid unnecessary API calls
