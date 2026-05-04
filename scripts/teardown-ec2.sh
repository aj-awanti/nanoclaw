#!/usr/bin/env bash
# teardown-ec2.sh — Reverse scripts/provision-ec2.sh.
#
# Default behavior:
#   - Terminates EC2 instances tagged Project=nanoclaw, Name=nanoclaw-secondbrain
#   - Deletes the security group
#   - Removes the IAM role from the instance profile, deletes both
#   - Detaches managed policies, deletes inline policies, deletes the role
#   - PRESERVES the S3 backup bucket (your knowledge graph lives here)
#
# Flags:
#   --purge-backups   Also empty and delete the S3 backup bucket (irreversible)
#   -y, --yes         Skip the confirmation prompt
#   --region REGION   Override region (default us-west-2)
#
# Usage:
#   bash scripts/teardown-ec2.sh                       # safe-default cleanup, prompts
#   bash scripts/teardown-ec2.sh --purge-backups       # also wipes S3 backups
#   bash scripts/teardown-ec2.sh -y --purge-backups    # no prompt — be sure

set -euo pipefail

PROFILE="cli-admin"
REGION="us-west-2"
NAME_PREFIX="nanoclaw-secondbrain"
PURGE_BACKUPS=0
ASSUME_YES=0

while [ $# -gt 0 ]; do
  case "$1" in
    --purge-backups) PURGE_BACKUPS=1; shift ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    --region) REGION="$2"; shift 2 ;;
    -h|--help) sed -n '2,21p' "$0"; exit 0 ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

echo "=== NanoClaw Second Brain — Teardown ==="
echo "Region:  $REGION"
echo "Profile: $PROFILE"
echo ""

# Resolve account-id + bucket name (matches provision-ec2.sh)
ACCOUNT_ID=$(aws sts get-caller-identity --profile "$PROFILE" --query Account --output text)
BACKUP_BUCKET="nanoclaw-backup-${ACCOUNT_ID}-${REGION}"

# --- 1. Discover what exists ---
echo "[1/7] Discovering resources..."

# Instances (any state except already-terminated)
INSTANCE_IDS=$(aws ec2 describe-instances \
  --profile "$PROFILE" --region "$REGION" \
  --filters \
    "Name=tag:Project,Values=nanoclaw" \
    "Name=tag:Name,Values=${NAME_PREFIX}" \
    "Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down" \
  --query 'Reservations[].Instances[].InstanceId' \
  --output text)

# Security group
SG_ID=$(aws ec2 describe-security-groups \
  --profile "$PROFILE" --region "$REGION" \
  --filters "Name=group-name,Values=${NAME_PREFIX}-sg" \
  --query 'SecurityGroups[0].GroupId' \
  --output text 2>/dev/null || echo "None")

# IAM
ROLE_EXISTS=0; aws iam get-role --profile "$PROFILE" --role-name "${NAME_PREFIX}-role" >/dev/null 2>&1 && ROLE_EXISTS=1
PROFILE_EXISTS=0; aws iam get-instance-profile --profile "$PROFILE" --instance-profile-name "${NAME_PREFIX}-profile" >/dev/null 2>&1 && PROFILE_EXISTS=1

# CloudWatch alarms + SNS topic
ALARMS=$(aws cloudwatch describe-alarms \
  --profile "$PROFILE" --region "$REGION" \
  --alarm-name-prefix "${NAME_PREFIX}-StatusCheckFailed" \
  --query 'MetricAlarms[].AlarmName' --output text)
TOPIC_ARN=$(aws sns list-topics --profile "$PROFILE" --region "$REGION" \
  --query "Topics[?ends_with(TopicArn, ':${NAME_PREFIX}-alerts')].TopicArn | [0]" \
  --output text)

# S3 bucket
BUCKET_EXISTS=0; aws s3api head-bucket --profile "$PROFILE" --bucket "$BACKUP_BUCKET" 2>/dev/null && BUCKET_EXISTS=1

echo ""
echo "Found:"
if [ -n "$INSTANCE_IDS" ]; then
  echo "  EC2 instances:    $INSTANCE_IDS"
else
  echo "  EC2 instances:    none"
fi
echo "  Security group:   ${SG_ID:-None}"
echo "  IAM role:         $([ $ROLE_EXISTS -eq 1 ] && echo "${NAME_PREFIX}-role" || echo none)"
echo "  Instance profile: $([ $PROFILE_EXISTS -eq 1 ] && echo "${NAME_PREFIX}-profile" || echo none)"
if [ $BUCKET_EXISTS -eq 1 ]; then
  if [ $PURGE_BACKUPS -eq 1 ]; then
    OBJ_COUNT=$(aws s3api list-object-versions --profile "$PROFILE" --bucket "$BACKUP_BUCKET" \
      --query '(Versions[]?Key)|length(@) + (DeleteMarkers[]?Key)|length(@)' --output text 2>/dev/null || echo "?")
    echo "  S3 bucket:        $BACKUP_BUCKET (will be EMPTIED + DELETED, ${OBJ_COUNT} object-versions)"
  else
    echo "  S3 bucket:        $BACKUP_BUCKET (PRESERVED — pass --purge-backups to delete)"
  fi
else
  echo "  S3 bucket:        $BACKUP_BUCKET (does not exist)"
fi
if [ -n "$ALARMS" ] && [ "$ALARMS" != "None" ]; then
  echo "  CloudWatch:       $ALARMS"
else
  echo "  CloudWatch:       none"
fi
echo "  SNS topic:        ${TOPIC_ARN:-none}"
echo ""

# Nothing to do?
if [ -z "$INSTANCE_IDS" ] && [ "$SG_ID" = "None" ] && [ $ROLE_EXISTS -eq 0 ] && \
   [ $PROFILE_EXISTS -eq 0 ] && { [ $BUCKET_EXISTS -eq 0 ] || [ $PURGE_BACKUPS -eq 0 ]; } && \
   [ -z "$ALARMS" ] && [ -z "${TOPIC_ARN:-}" ]; then
  echo "Nothing to do."
  exit 0
fi

# Confirm
if [ $ASSUME_YES -eq 0 ]; then
  read -r -p "Proceed with teardown? (yes/N): " ans
  case "$ans" in
    yes|YES|y|Y) ;;
    *) echo "Aborted."; exit 0 ;;
  esac
fi

# --- 2. Terminate instances ---
echo ""
echo "[2/7] Terminating instances..."
if [ -n "$INSTANCE_IDS" ]; then
  # shellcheck disable=SC2086
  aws ec2 terminate-instances \
    --profile "$PROFILE" --region "$REGION" \
    --instance-ids $INSTANCE_IDS \
    --query 'TerminatingInstances[].{Id:InstanceId,Prev:PreviousState.Name,Curr:CurrentState.Name}' \
    --output table

  echo "  Waiting for termination (security group can't be deleted while ENIs are attached)..."
  # shellcheck disable=SC2086
  aws ec2 wait instance-terminated \
    --profile "$PROFILE" --region "$REGION" \
    --instance-ids $INSTANCE_IDS
  echo "  ✓ Instances terminated"
else
  echo "  (none)"
fi

# --- 3. Delete security group ---
echo ""
echo "[3/7] Deleting security group..."
if [ "$SG_ID" != "None" ] && [ -n "$SG_ID" ]; then
  # Retry up to ~60s; ENIs can linger briefly after instance termination
  for attempt in 1 2 3 4 5 6; do
    if aws ec2 delete-security-group \
        --profile "$PROFILE" --region "$REGION" \
        --group-id "$SG_ID" 2>/tmp/sg-del.err; then
      echo "  ✓ Deleted $SG_ID"
      break
    fi
    if grep -q "DependencyViolation" /tmp/sg-del.err; then
      echo "  ENI still attached, sleeping 10s (attempt $attempt/6)..."
      sleep 10
      continue
    fi
    cat /tmp/sg-del.err >&2
    exit 1
  done
else
  echo "  (none)"
fi

# --- 4. Detach + delete instance profile ---
echo ""
echo "[4/7] Removing instance profile..."
if [ $PROFILE_EXISTS -eq 1 ]; then
  if [ $ROLE_EXISTS -eq 1 ]; then
    aws iam remove-role-from-instance-profile \
      --profile "$PROFILE" \
      --instance-profile-name "${NAME_PREFIX}-profile" \
      --role-name "${NAME_PREFIX}-role" 2>/dev/null || true
  fi
  aws iam delete-instance-profile \
    --profile "$PROFILE" \
    --instance-profile-name "${NAME_PREFIX}-profile"
  echo "  ✓ Instance profile deleted"
else
  echo "  (none)"
fi

# --- 5. Detach policies + delete role ---
echo ""
echo "[5/7] Deleting IAM role..."
if [ $ROLE_EXISTS -eq 1 ]; then
  # Detach managed policies
  for arn in $(aws iam list-attached-role-policies \
      --profile "$PROFILE" \
      --role-name "${NAME_PREFIX}-role" \
      --query 'AttachedPolicies[].PolicyArn' --output text); do
    aws iam detach-role-policy \
      --profile "$PROFILE" \
      --role-name "${NAME_PREFIX}-role" \
      --policy-arn "$arn"
    echo "  detached managed: $arn"
  done

  # Delete inline policies
  for name in $(aws iam list-role-policies \
      --profile "$PROFILE" \
      --role-name "${NAME_PREFIX}-role" \
      --query 'PolicyNames' --output text); do
    aws iam delete-role-policy \
      --profile "$PROFILE" \
      --role-name "${NAME_PREFIX}-role" \
      --policy-name "$name"
    echo "  deleted inline:   $name"
  done

  aws iam delete-role \
    --profile "$PROFILE" \
    --role-name "${NAME_PREFIX}-role"
  echo "  ✓ Role deleted"
else
  echo "  (none)"
fi

# --- 6. (Optional) Empty + delete S3 backup bucket ---
echo ""
echo "[6/7] S3 backup bucket..."
if [ $BUCKET_EXISTS -eq 1 ] && [ $PURGE_BACKUPS -eq 1 ]; then
  echo "  Emptying $BACKUP_BUCKET (versioned — deleting all versions + delete-markers)..."

  # Loop until both Versions and DeleteMarkers are empty
  while :; do
    PAYLOAD=$(aws s3api list-object-versions \
      --profile "$PROFILE" --bucket "$BACKUP_BUCKET" \
      --max-items 1000 \
      --output json \
      --query '{Objects: ([].concat(Versions[?Key], DeleteMarkers[?Key])[]).{Key:Key, VersionId:VersionId}, Quiet: `true`}' \
      2>/dev/null || true)

    # If nothing left, break
    COUNT=$(echo "$PAYLOAD" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d.get('Objects') or []))" 2>/dev/null || echo 0)
    if [ "$COUNT" = "0" ] || [ -z "$PAYLOAD" ]; then
      break
    fi

    aws s3api delete-objects \
      --profile "$PROFILE" --bucket "$BACKUP_BUCKET" \
      --delete "$PAYLOAD" \
      --output text >/dev/null
    echo "  deleted $COUNT object-versions"
  done

  aws s3api delete-bucket \
    --profile "$PROFILE" --region "$REGION" \
    --bucket "$BACKUP_BUCKET"
  echo "  ✓ Bucket deleted"
elif [ $BUCKET_EXISTS -eq 1 ]; then
  echo "  PRESERVED — pass --purge-backups to delete s3://$BACKUP_BUCKET"
else
  echo "  (does not exist)"
fi

# --- 7. CloudWatch alarms + SNS ---
echo ""
echo "[7/7] Removing CloudWatch alarms + SNS..."
if [ -n "$ALARMS" ] && [ "$ALARMS" != "None" ]; then
  # shellcheck disable=SC2086
  aws cloudwatch delete-alarms \
    --profile "$PROFILE" --region "$REGION" \
    --alarm-names $ALARMS
  echo "  ✓ Deleted alarms: $ALARMS"
fi
if [ -n "${TOPIC_ARN:-}" ] && [ "$TOPIC_ARN" != "None" ]; then
  aws sns delete-topic \
    --profile "$PROFILE" --region "$REGION" \
    --topic-arn "$TOPIC_ARN"
  echo "  ✓ Deleted SNS topic: $TOPIC_ARN"
fi
if [ -z "$ALARMS" ] && [ -z "${TOPIC_ARN:-}" ]; then
  echo "  (none)"
fi

echo ""
echo "=== TEARDOWN COMPLETE ==="
