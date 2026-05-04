#!/usr/bin/env bash
# ec2-bootstrap.sh — Bootstrap NanoClaw Second Brain on EC2 (Amazon Linux 2023, aarch64)
# Run this inside an SSM session on the provisioned instance.
#
# What it does:
#   1. Fetches secrets from AWS Secrets Manager
#   2. Installs Node.js 20, pnpm, Docker, Ollama
#   3. Clones your NanoClaw fork + sets upstream
#   4. Configures .env with credentials
#   5. Builds container image
#   6. Pulls Ollama embedding model
#   7. Sets up systemd service
#
# Usage: bash ec2-bootstrap.sh

set -euo pipefail

# IMDSv2 token-based metadata lookup (ec2-metadata is AL2-only; AL2023 requires curl)
IMDS_TOKEN=$(curl -sS -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
REGION=$(curl -sS -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/region)

FORK_REPO="https://github.com/aj-awanti/nanoclaw.git"
UPSTREAM_REPO="https://github.com/qwibitai/nanoclaw.git"
INSTALL_DIR="/opt/nanoclaw"
NANOCLAW_USER="nanoclaw"

echo "=== NanoClaw Second Brain — EC2 Bootstrap ==="
echo "Region: $REGION"
echo "Fork:   $FORK_REPO"
echo ""

# --- 1. Fetch secrets from AWS Secrets Manager ---
echo "[1/8] Fetching secrets from AWS Secrets Manager..."

dnf install -y -q jq

# Helper: fetch secret. If SecretString is JSON, extract the value at key $2 (or first leaf).
# Otherwise return the raw string.
fetch_secret() {
  local sid="$1"
  local raw
  raw=$(aws secretsmanager get-secret-value \
    --region "$REGION" \
    --secret-id "$sid" \
    --query 'SecretString' \
    --output text)
  if echo "$raw" | jq -e . >/dev/null 2>&1; then
    # JSON object — return first scalar value
    echo "$raw" | jq -r 'if type=="object" then (to_entries|map(select(.value|type=="string"))|.[0].value) else . end'
  else
    printf '%s' "$raw"
  fi
}

ANTHROPIC_CREDENTIAL=$(fetch_secret "nanoclaw/anthropic-credential")
TELEGRAM_BOT_TOKEN=$(fetch_secret "nanoclaw/telegram-bot-token")

if [ -z "$ANTHROPIC_CREDENTIAL" ] || [ -z "$TELEGRAM_BOT_TOKEN" ]; then
  echo "  ✗ One or more secrets came back empty. Check Secrets Manager." >&2
  exit 1
fi

echo "  ✓ Secrets retrieved"

# --- 2. Install system dependencies ---
echo "[2/8] Installing system dependencies..."

# Update system
dnf update -y -q

# Install git, development tools
dnf install -y -q git gcc-c++ make

# Install Docker
dnf install -y -q docker
systemctl enable docker
systemctl start docker

# Create nanoclaw user and add to docker group
useradd -r -m -d /opt/nanoclaw -s /bin/bash "$NANOCLAW_USER" 2>/dev/null || true
usermod -aG docker "$NANOCLAW_USER"

echo "  ✓ System deps installed, Docker running"

# --- 2a. Enable automatic security patches via dnf-automatic ---
echo "[2a/8] Enabling dnf-automatic for security patches..."

dnf install -y -q dnf-automatic

# Apply security updates only (not feature updates), keep reboots manual
sed -i \
  -e 's/^upgrade_type = .*/upgrade_type = security/' \
  -e 's/^apply_updates = .*/apply_updates = yes/' \
  /etc/dnf/automatic.conf

systemctl enable --now dnf-automatic.timer
echo "  ✓ Security patches will apply on the dnf-automatic.timer schedule (daily)"

# --- 2b. Install whisper.cpp + ffmpeg for voice-note transcription ---
# Built once on the host; the agent container reaches it via a /manage-mounts
# entry (added post-setup). Keeps the container image lean and avoids needing
# build tools at image-build time.
echo "[2b/8] Installing whisper.cpp + ffmpeg..."

# ffmpeg is NOT in AL2023's default repos. We ship a static ARM64 ffmpeg
# inside /opt/whisper instead, which gets mounted into the container.
dnf install -y -q cmake xz

if [ ! -x /opt/whisper/build/bin/whisper-cli ] && [ ! -x /opt/whisper/main ]; then
  git clone --depth 1 https://github.com/ggerganov/whisper.cpp /opt/whisper
  cd /opt/whisper
  if [ -f CMakeLists.txt ]; then
    cmake -B build -DGGML_NATIVE=ON >/dev/null
    cmake --build build -j"$(nproc)" --config Release >/dev/null
  else
    make -j"$(nproc)" >/dev/null
  fi
  bash ./models/download-ggml-model.sh small.en
  cd -
fi

# Static ARM64 ffmpeg for use INSIDE the agent container.
# (The container has no ffmpeg of its own; mounting /opt/whisper gives it one.)
if [ ! -x /opt/whisper/ffmpeg ]; then
  TMPDIR=$(mktemp -d)
  curl -fsSL -o "$TMPDIR/ffmpeg.tar.xz" \
    https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-arm64-static.tar.xz
  tar -xJf "$TMPDIR/ffmpeg.tar.xz" -C "$TMPDIR"
  cp "$TMPDIR"/ffmpeg-*-arm64-static/ffmpeg /opt/whisper/ffmpeg
  chmod 755 /opt/whisper/ffmpeg
  rm -rf "$TMPDIR"
fi

# Wrapper: agent calls this with one audio file, gets back transcribed text.
cat > /opt/whisper/transcribe <<'TRANSCRIBEEOF'
#!/usr/bin/env bash
# transcribe — voice-note → text via whisper.cpp.
# Usage: transcribe <audio_file>
# Output: plain transcription on stdout, no timestamps.

set -euo pipefail

if [ $# -ne 1 ] || [ ! -f "$1" ]; then
  echo "Usage: $0 <audio_file>" >&2
  exit 1
fi

INPUT="$1"
WD="$(cd "$(dirname "$0")" && pwd)"
TMPWAV=$(mktemp --suffix=.wav)
trap 'rm -f "$TMPWAV"' EXIT

# Build vocab prompt — bias decoder toward names/jargon you say often.
PROMPT_ARGS=()
if [ -f "$WD/vocab.txt" ]; then
  VOCAB=$(grep -vE '^\s*(#|$)' "$WD/vocab.txt" | tr '\n' ' ' | sed 's/[[:space:]]\+$//')
  if [ -n "$VOCAB" ]; then
    PROMPT_ARGS=(--prompt "$VOCAB")
  fi
fi

# 1. Preprocess: trim leading silence + loudness-normalize + 16kHz mono PCM
"$WD/ffmpeg" -y -i "$INPUT" \
  -af "silenceremove=start_periods=1:start_silence=0.5:start_threshold=-50dB,loudnorm=I=-16:TP=-1.5:LRA=11" \
  -ar 16000 -ac 1 -f wav "$TMPWAV" 2>/dev/null

# 2. Transcribe with conservative no-speech threshold + forced English
"$WD/build/bin/whisper-cli" \
  -m "$WD/models/ggml-small.en.bin" \
  -f "$TMPWAV" \
  -l en \
  -nt \
  --no-speech-thold 0.6 \
  "${PROMPT_ARGS[@]}" 2>/dev/null
TRANSCRIBEEOF

chmod 755 /opt/whisper/transcribe

# Vocabulary file — bias the decoder toward names/jargon you use often.
# Edit any time; the transcribe wrapper reads it on every invocation.
if [ ! -f /opt/whisper/vocab.txt ]; then
  cat > /opt/whisper/vocab.txt <<'VOCABEOF'
# One name/term per line. Lines starting with # are ignored.
# Whisper uses these as an "initial prompt" to bias decoding toward your
# specific terminology — proper nouns, project names, technical jargon.
#
# Example:
#   Awanti
#   AgentCore
#   NanoClaw
#   Karpathy
#   us-west-2
VOCABEOF
fi

# Make everything in /opt/whisper world-readable so containers can use it
chmod -R a+rX /opt/whisper

echo "  ✓ whisper.cpp built, small.en model (~466MB) downloaded"
echo "  ✓ static ARM64 ffmpeg placed at /opt/whisper/ffmpeg (for container use)"
echo "  ✓ wrapper at /opt/whisper/transcribe — reads /opt/whisper/vocab.txt"

# --- 3. Install Node.js 20 via nvm ---
echo "[3/8] Installing Node.js 20 + pnpm..."

# Install as nanoclaw user
sudo -u "$NANOCLAW_USER" bash <<'NODEEOF'
set -euo pipefail
export HOME=/opt/nanoclaw

# Install nvm
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash

# Load nvm
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"

# Install Node 20
nvm install 20
nvm use 20
nvm alias default 20

# Install pnpm + Claude Code (needed on the instance to run install skills like
# /add-telegram, /add-ollama-tool, /add-karpathy-llm-wiki, /init-onecli)
npm install -g pnpm@10 @anthropic-ai/claude-code

echo "  Node:        $(node --version)"
echo "  pnpm:        $(pnpm --version)"
echo "  claude-code: $(claude --version 2>/dev/null || echo installed)"
NODEEOF

echo "  ✓ Node.js 20 + pnpm installed"

# --- 4. Install Ollama ---
echo "[4/8] Installing Ollama..."

curl -fsSL https://ollama.com/install.sh | sh

# Bind Ollama to 0.0.0.0:11434 so the agent container can reach it via
# host.docker.internal (the default 127.0.0.1 bind is only the host loopback).
# Listening on 0.0.0.0 is safe here: the EC2 security group has no inbound
# rules, so 11434 is not reachable from the public internet.
mkdir -p /etc/systemd/system/ollama.service.d
cat > /etc/systemd/system/ollama.service.d/override.conf <<'OLLAMAEOF'
[Service]
Environment="OLLAMA_HOST=0.0.0.0:11434"
OLLAMAEOF

systemctl daemon-reload
systemctl enable ollama
systemctl restart ollama

# Wait for Ollama to be ready
sleep 3
echo "  ✓ Ollama installed and running on 0.0.0.0:11434"

# --- 5. Clone NanoClaw fork ---
echo "[5/8] Cloning NanoClaw fork..."

sudo -u "$NANOCLAW_USER" bash <<GITEOF
set -euo pipefail
cd /opt/nanoclaw

# Clone fork (idempotent — pull if it already exists)
if [ -d nanoclaw-v2/.git ]; then
  cd nanoclaw-v2
  git fetch origin
  git checkout main
  git pull --ff-only origin main
else
  git clone "$FORK_REPO" nanoclaw-v2
  cd nanoclaw-v2
fi

# Add upstream (idempotent)
if ! git remote get-url upstream >/dev/null 2>&1; then
  git remote add upstream "$UPSTREAM_REPO"
fi
git fetch upstream

echo "  Origin:   $FORK_REPO"
echo "  Upstream: $UPSTREAM_REPO"
GITEOF

echo "  ✓ Repository cloned"

# --- 6. Configure .env ---
echo "[6/8] Writing .env configuration..."

# Detect OAuth token (sk-ant-oat-...) vs raw API key (sk-ant-api-...)
# OAuth tokens belong in CLAUDE_CODE_OAUTH_TOKEN; API keys in ANTHROPIC_API_KEY.
if [[ "$ANTHROPIC_CREDENTIAL" == sk-ant-oat-* ]]; then
  ANTHROPIC_ENV_VAR="CLAUDE_CODE_OAUTH_TOKEN"
else
  ANTHROPIC_ENV_VAR="ANTHROPIC_API_KEY"
fi

cat > /opt/nanoclaw/nanoclaw-v2/.env <<ENVEOF
# NanoClaw Second Brain — Auto-generated by ec2-bootstrap.sh
# Credentials fetched from AWS Secrets Manager

# Anthropic credential (auto-detected: OAuth token vs API key)
${ANTHROPIC_ENV_VAR}=${ANTHROPIC_CREDENTIAL}

# Telegram
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}

# Ollama — agent container reaches the host daemon via host.docker.internal.
# The host-side Node process can use 127.0.0.1.
OLLAMA_HOST=http://host.docker.internal:11434

# Instance metadata
NANOCLAW_REGION=${REGION}
ENVEOF

chown "$NANOCLAW_USER:$NANOCLAW_USER" /opt/nanoclaw/nanoclaw-v2/.env
chmod 600 /opt/nanoclaw/nanoclaw-v2/.env

echo "  ✓ .env written (mode 600)"

# --- 7. Install deps + build container ---
echo "[7/8] Installing dependencies and building container..."

sudo -u "$NANOCLAW_USER" bash <<'BUILDEOF'
set -euo pipefail
export HOME=/opt/nanoclaw
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"

cd /opt/nanoclaw/nanoclaw-v2

# Install host dependencies
pnpm install --frozen-lockfile

# Build host
pnpm run build

# Build agent container image
./container/build.sh
BUILDEOF

echo "  ✓ Dependencies installed, container built"

# --- 8. Pull Ollama embedding model ---
echo "[8/8] Pulling nomic-embed-text model for embeddings..."

# Ollama CLI panics on `$HOME is not defined` when run in SSM/run-command's
# bare root environment. Set HOME explicitly. The daemon (running as the
# `ollama` user) handles actual model storage; HOME is only a CLI sanity check.
HOME="${HOME:-/root}" ollama pull nomic-embed-text

echo "  ✓ nomic-embed-text ready"

# --- Create systemd service ---
echo ""
echo "Creating systemd service..."

cat > /etc/systemd/system/nanoclaw.service <<'SVCEOF'
[Unit]
Description=NanoClaw Second Brain
After=network-online.target docker.service ollama.service
Wants=network-online.target docker.service ollama.service

[Service]
Type=simple
User=nanoclaw
Group=nanoclaw
WorkingDirectory=/opt/nanoclaw/nanoclaw-v2
Environment=HOME=/opt/nanoclaw
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=DOCKER_HOST=unix:///var/run/docker.sock
# Agent container reaches Ollama on the host via host.docker.internal
Environment=OLLAMA_HOST=http://host.docker.internal:11434
ExecStart=/bin/bash -lc 'source $HOME/.nvm/nvm.sh && exec node dist/index.js'
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable nanoclaw

echo "  ✓ systemd service created (nanoclaw.service)"

# --- Backup automation: daily SQLite-safe snapshot to S3 ---
echo ""
echo "Setting up daily S3 backups..."

# Need sqlite3 binary for atomic .backup
dnf install -y -q sqlite

# Resolve account id + bucket name (matches provision-ec2.sh derivation)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BACKUP_BUCKET="nanoclaw-backup-${ACCOUNT_ID}-${REGION}"

mkdir -p /opt/nanoclaw/bin /opt/nanoclaw/backups
chown -R "$NANOCLAW_USER:$NANOCLAW_USER" /opt/nanoclaw/backups

cat > /opt/nanoclaw/bin/backup.sh <<BACKUPEOF
#!/usr/bin/env bash
# Daily NanoClaw backup — SQLite-safe snapshot, tar+gzip, upload to S3.
# Runs as the nanoclaw user via systemd timer. Logs to journal.

set -euo pipefail

BUCKET="${BACKUP_BUCKET}"
NANOCLAW_DIR=/opt/nanoclaw/nanoclaw-v2
LOCAL_RETAIN_DAYS=14
TS=\$(date -u +%Y%m%d-%H%M%S)
WORK=\$(mktemp -d)
trap "rm -rf \$WORK" EXIT

echo "[backup] starting \$TS"

# 1. Atomic SQLite snapshots (handles WAL/checkpointing correctly)
mkdir -p "\$WORK/data"
shopt -s globstar nullglob
for db in "\$NANOCLAW_DIR"/data/**/*.db; do
  rel="\${db#\$NANOCLAW_DIR/}"
  mkdir -p "\$WORK/\$(dirname "\$rel")"
  sqlite3 "\$db" ".backup '\$WORK/\$rel'"
done

# 2. Verbatim copies for non-DB state
[ -d "\$NANOCLAW_DIR/groups" ] && rsync -a --delete \\
  --exclude='*.db' --exclude='*.db-shm' --exclude='*.db-wal' \\
  "\$NANOCLAW_DIR/groups/" "\$WORK/groups/"
[ -f "\$NANOCLAW_DIR/.env" ] && cp "\$NANOCLAW_DIR/.env" "\$WORK/env.bak"

# 3. Archive
ARCHIVE=/opt/nanoclaw/backups/nanoclaw-\$TS.tar.gz
tar -czf "\$ARCHIVE" -C "\$WORK" .
SIZE=\$(du -h "\$ARCHIVE" | cut -f1)
echo "[backup] archive \$SIZE: \$ARCHIVE"

# 4. Upload to S3 (bucket has versioning + lifecycle)
aws s3 cp "\$ARCHIVE" "s3://\$BUCKET/daily/\$TS.tar.gz" --only-show-errors
echo "[backup] uploaded s3://\$BUCKET/daily/\$TS.tar.gz"

# 5. Trim local archives
find /opt/nanoclaw/backups -name 'nanoclaw-*.tar.gz' -mtime +\$LOCAL_RETAIN_DAYS -delete

echo "[backup] done"
BACKUPEOF

chmod 750 /opt/nanoclaw/bin/backup.sh
chown "$NANOCLAW_USER:$NANOCLAW_USER" /opt/nanoclaw/bin/backup.sh

# systemd service + timer (oneshot, daily 04:00 UTC, with random splay)
cat > /etc/systemd/system/nanoclaw-backup.service <<'BAKSVCEOF'
[Unit]
Description=NanoClaw daily backup to S3
After=network-online.target nanoclaw.service
Wants=network-online.target

[Service]
Type=oneshot
User=nanoclaw
Group=nanoclaw
ExecStart=/opt/nanoclaw/bin/backup.sh
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
BAKSVCEOF

cat > /etc/systemd/system/nanoclaw-backup.timer <<'BAKTIMEOF'
[Unit]
Description=Run NanoClaw backup daily at 04:00 UTC
Requires=nanoclaw-backup.service

[Timer]
OnCalendar=*-*-* 04:00:00 UTC
RandomizedDelaySec=15min
Persistent=true
Unit=nanoclaw-backup.service

[Install]
WantedBy=timers.target
BAKTIMEOF

systemctl daemon-reload
systemctl enable nanoclaw-backup.timer

echo "  ✓ Daily backup configured (s3://$BACKUP_BUCKET/daily/, 14d local retention)"

# --- Mount allowlist + voice-wiring helper ---
echo ""
echo "Pre-creating mount allowlist + voice-wiring helper..."

sudo -u "$NANOCLAW_USER" mkdir -p /opt/nanoclaw/.config/nanoclaw

# Pre-create the allowlist with /opt as a read-only allowed root.
# Without this file, the host blocks ALL additional mounts (safe default).
# We allow /opt rather than /opt/whisper specifically so future tools
# (e.g., a static binary you drop in /opt/foo) can be mounted without editing.
cat > /opt/nanoclaw/.config/nanoclaw/mount-allowlist.json <<'ALLOWEOF'
{
  "allowedRoots": [
    {
      "path": "/opt",
      "allowReadWrite": false,
      "description": "System tools mounted read-only into agent containers (whisper.cpp, etc.)"
    }
  ],
  "blockedPatterns": []
}
ALLOWEOF

chown "$NANOCLAW_USER:$NANOCLAW_USER" /opt/nanoclaw/.config/nanoclaw/mount-allowlist.json
chmod 600 /opt/nanoclaw/.config/nanoclaw/mount-allowlist.json

# Helper: run AFTER `bash nanoclaw.sh` to attach whisper to the new agent group.
cat > /opt/nanoclaw/bin/wire-voice.sh <<'WIREEOF'
#!/usr/bin/env bash
# wire-voice.sh — Attach the host /opt/whisper mount to a NanoClaw agent group
# and seed its CLAUDE.local.md with voice-handling instructions.
#
# Run AFTER `bash nanoclaw.sh` has created at least one group.
# Usage: wire-voice.sh [GROUP_FOLDER]
#   If GROUP_FOLDER is omitted, picks the only group; otherwise prompts.

set -euo pipefail

NANOCLAW_DIR=/opt/nanoclaw/nanoclaw-v2
GROUPS_DIR="$NANOCLAW_DIR/groups"

if [ ! -d "$GROUPS_DIR" ]; then
  echo "No groups directory at $GROUPS_DIR — run 'bash nanoclaw.sh' first." >&2
  exit 1
fi

GROUP="${1:-}"
if [ -z "$GROUP" ]; then
  COUNT=$(find "$GROUPS_DIR" -maxdepth 1 -mindepth 1 -type d ! -name 'global' | wc -l)
  if [ "$COUNT" -eq 0 ]; then
    echo "No agent groups found in $GROUPS_DIR — run 'bash nanoclaw.sh' first." >&2
    exit 1
  elif [ "$COUNT" -eq 1 ]; then
    GROUP=$(basename "$(find "$GROUPS_DIR" -maxdepth 1 -mindepth 1 -type d ! -name 'global')")
    echo "Wiring voice into the only group found: $GROUP"
  else
    echo "Multiple groups found. Pass one as argument:" >&2
    find "$GROUPS_DIR" -maxdepth 1 -mindepth 1 -type d ! -name 'global' -exec basename {} \; >&2
    exit 1
  fi
fi

GROUP_DIR="$GROUPS_DIR/$GROUP"
if [ ! -d "$GROUP_DIR" ]; then
  echo "Group not found: $GROUP_DIR" >&2
  exit 1
fi

# 1. Add /opt/whisper mount to container.json
CONTAINER_JSON="$GROUP_DIR/container.json"
if [ ! -f "$CONTAINER_JSON" ]; then
  echo '{}' > "$CONTAINER_JSON"
fi

# Use jq to merge the mount entry idempotently
TMP=$(mktemp)
jq '
  .additionalMounts = (.additionalMounts // []) |
  if any(.additionalMounts[]; .hostPath == "/opt/whisper")
  then .
  else .additionalMounts += [{
    "hostPath": "/opt/whisper",
    "containerPath": "whisper",
    "readonly": true
  }] end
' "$CONTAINER_JSON" > "$TMP"
mv "$TMP" "$CONTAINER_JSON"

# 2. Append voice instructions to CLAUDE.local.md (idempotent)
LOCAL_MD="$GROUP_DIR/CLAUDE.local.md"
touch "$LOCAL_MD"

if ! grep -q "## Voice transcription" "$LOCAL_MD"; then
  cat >> "$LOCAL_MD" <<'VOICEMDEOF'

## Voice transcription

When the user sends a voice note (`.ogg`, `.mp3`, `.m4a`, `.wav`, etc.):

1. Save the audio to a temp file (e.g., `/tmp/note.ogg`).
2. Run: `/workspace/extra/whisper/transcribe /tmp/note.ogg`
3. Read the printed transcription from stdout.
4. Treat the transcription as if the user had typed it. Process normally
   (recall, knowledge-graph extraction, response).

Notes:
- The wrapper is read-only at `/workspace/extra/whisper/transcribe`.
- It uses the `small.en` model — accurate for English. Errors on names
  or jargon usually mean a missing entry in
  `/workspace/extra/whisper/vocab.txt` (read-only here; you can ask the
  human to edit `/opt/whisper/vocab.txt` on the host to add terms).
- Don't try to invoke ffmpeg or whisper-cli directly; the wrapper
  handles silence-trim, loudness-normalize, vocab-prompt, and PCM
  conversion in one call.
VOICEMDEOF
fi

# 3. Fix ownership in case the script ran as root
chown -R nanoclaw:nanoclaw "$GROUP_DIR"

echo "  ✓ Mount added to $GROUP/container.json"
echo "  ✓ Voice instructions appended to $GROUP/CLAUDE.local.md"
echo ""
echo "Restart the host so the running container picks up the new mount:"
echo "  sudo systemctl restart nanoclaw"
WIREEOF

chmod 755 /opt/nanoclaw/bin/wire-voice.sh
chown "$NANOCLAW_USER:$NANOCLAW_USER" /opt/nanoclaw/bin/wire-voice.sh

# wire-voice.sh needs jq — already installed in step 1 (secrets fetch)
echo "  ✓ Mount allowlist seeded; wire-voice.sh placed at /opt/nanoclaw/bin/"

echo ""
echo "=== BOOTSTRAP COMPLETE ==="
echo ""
echo "Next steps (run from your laptop or via SSM session):"
echo ""
echo "1. Connect (use scripts/connect.sh from your laptop, or):"
echo "   aws ssm start-session --profile cli-admin --region $REGION --target <instance-id>"
echo ""
echo "2. Switch to the nanoclaw user:"
echo "   sudo -iu nanoclaw"
echo "   cd nanoclaw-v2"
echo ""
echo "3. Install skills via Claude Code (BEFORE creating the first agent):"
echo "   source ~/.nvm/nvm.sh && claude"
echo "   # Then in Claude Code, run in order:"
echo "   #   /init-onecli      # install OneCLI gateway + migrate .env to vault"
echo "   #   /add-telegram"
echo "   #   /add-ollama-tool"
echo "   #   /add-karpathy-llm-wiki"
echo "   # (Do NOT run /use-native-credential-proxy — its upstream branch is v1, breaks v2.)"
echo ""
echo "4. Wire the first agent (interactive):"
echo "   bash nanoclaw.sh"
echo ""
echo "5. Wire voice transcription into that agent:"
echo "   bash /opt/nanoclaw/bin/wire-voice.sh"
echo ""
echo "6. Start the service:"
echo "   sudo systemctl start nanoclaw"
echo "   sudo journalctl -u nanoclaw -f"
echo ""
echo "7. (Optional) Edit the voice vocab file with names/jargon you say often:"
echo "   sudo nano /opt/whisper/vocab.txt"
echo ""
echo "8. To merge upstream updates later:"
echo "   git fetch upstream && git merge upstream/main"
