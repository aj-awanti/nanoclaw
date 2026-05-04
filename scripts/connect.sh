#!/usr/bin/env bash
# connect.sh — Open an SSM session to the NanoClaw second-brain instance.
# Auto-discovers the instance by tag so you don't have to remember the ID.
#
# Usage:
#   bash scripts/connect.sh                 # us-west-2, default tags
#   bash scripts/connect.sh --region us-east-1
#   bash scripts/connect.sh --user nanoclaw # drops you in as nanoclaw user
#
# Requires: aws cli + session-manager-plugin
#   brew install --cask session-manager-plugin

set -euo pipefail

PROFILE="cli-admin"
REGION="us-west-2"
NAME_PREFIX="nanoclaw-secondbrain"
AS_USER=""

while [ $# -gt 0 ]; do
  case "$1" in
    --region) REGION="$2"; shift 2 ;;
    --user) AS_USER="$2"; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

# Verify session-manager-plugin is present
if ! command -v session-manager-plugin >/dev/null 2>&1; then
  echo "session-manager-plugin not found." >&2
  echo "Install: brew install --cask session-manager-plugin" >&2
  exit 1
fi

INSTANCE_ID=$(aws ec2 describe-instances \
  --profile "$PROFILE" --region "$REGION" \
  --filters \
    "Name=tag:Project,Values=nanoclaw" \
    "Name=tag:Name,Values=${NAME_PREFIX}" \
    "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text)

if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" = "None" ]; then
  echo "No running ${NAME_PREFIX} instance found in $REGION." >&2
  exit 1
fi

echo "Connecting to $INSTANCE_ID in $REGION..."
if [ -n "$AS_USER" ]; then
  # Drop into the SSM session and immediately switch user
  exec aws ssm start-session \
    --profile "$PROFILE" --region "$REGION" \
    --target "$INSTANCE_ID" \
    --document-name AWS-StartInteractiveCommand \
    --parameters "command=[\"sudo -iu $AS_USER\"]"
else
  exec aws ssm start-session \
    --profile "$PROFILE" --region "$REGION" \
    --target "$INSTANCE_ID"
fi
