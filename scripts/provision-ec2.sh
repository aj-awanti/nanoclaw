#!/usr/bin/env bash
# provision-ec2.sh — Provision NanoClaw Second Brain EC2 instance
# Uses: t4g.large, Amazon Linux 2023 (aarch64), Session Manager, Secrets Manager
# Profile: cli-admin
#
# Usage: bash scripts/provision-ec2.sh [REGION]
# Default region: us-west-2

set -euo pipefail

PROFILE="cli-admin"
REGION="${1:-us-west-2}"
INSTANCE_TYPE="t4g.large"
VOLUME_SIZE=40
NAME_PREFIX="nanoclaw-secondbrain"

echo "=== NanoClaw Second Brain — EC2 Provisioning ==="
echo "Region: $REGION | Instance: $INSTANCE_TYPE | Profile: $PROFILE"
echo ""

# Resolve account id once — needed for the deterministic backup bucket name
ACCOUNT_ID=$(aws sts get-caller-identity --profile "$PROFILE" --query Account --output text)
BACKUP_BUCKET="nanoclaw-backup-${ACCOUNT_ID}-${REGION}"
echo "Account: $ACCOUNT_ID | Backup bucket: $BACKUP_BUCKET"
echo ""

# --- 1. Get latest Amazon Linux 2023 ARM64 AMI ---
echo "[1/8] Finding latest Amazon Linux 2023 (aarch64) AMI..."
AMI_ID=$(aws ec2 describe-images \
  --profile "$PROFILE" \
  --region "$REGION" \
  --owners amazon \
  --filters \
    "Name=name,Values=al2023-ami-2023*-arm64" \
    "Name=state,Values=available" \
    "Name=architecture,Values=arm64" \
  --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
  --output text)

echo "  AMI: $AMI_ID"

# --- 2. Create IAM Role + Instance Profile ---
echo "[2/8] Creating IAM role and instance profile..."

TRUST_POLICY=$(cat <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "ec2.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
)

# Create role (ignore if exists)
aws iam create-role \
  --profile "$PROFILE" \
  --role-name "${NAME_PREFIX}-role" \
  --assume-role-policy-document "$TRUST_POLICY" \
  --tags Key=Project,Value=nanoclaw \
  2>/dev/null || echo "  Role already exists, continuing..."

# Attach SSM policy
aws iam attach-role-policy \
  --profile "$PROFILE" \
  --role-name "${NAME_PREFIX}-role" \
  --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" \
  2>/dev/null || true

# Inline policy: Secrets Manager (read) + S3 backup bucket (read/write)
INSTANCE_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "SecretsManagerRead",
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ],
      "Resource": "arn:aws:secretsmanager:*:*:secret:nanoclaw/*"
    },
    {
      "Sid": "BackupBucketObjectRW",
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:DeleteObject"
      ],
      "Resource": "arn:aws:s3:::${BACKUP_BUCKET}/*"
    },
    {
      "Sid": "BackupBucketList",
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket",
        "s3:GetBucketLocation"
      ],
      "Resource": "arn:aws:s3:::${BACKUP_BUCKET}"
    }
  ]
}
EOF
)

aws iam put-role-policy \
  --profile "$PROFILE" \
  --role-name "${NAME_PREFIX}-role" \
  --policy-name "${NAME_PREFIX}-instance-access" \
  --policy-document "$INSTANCE_POLICY"

# Create instance profile (ignore if exists)
aws iam create-instance-profile \
  --profile "$PROFILE" \
  --instance-profile-name "${NAME_PREFIX}-profile" \
  2>/dev/null || echo "  Instance profile already exists, continuing..."

# Add role to profile (ignore if already added)
aws iam add-role-to-instance-profile \
  --profile "$PROFILE" \
  --instance-profile-name "${NAME_PREFIX}-profile" \
  --role-name "${NAME_PREFIX}-role" \
  2>/dev/null || true

echo "  Role: ${NAME_PREFIX}-role"
echo "  Profile: ${NAME_PREFIX}-profile"

# Wait for instance profile to propagate
echo "  Waiting 10s for IAM propagation..."
sleep 10

# --- 3. Create S3 backup bucket ---
echo "[3/8] Creating S3 backup bucket: $BACKUP_BUCKET"

# Create bucket (LocationConstraint required for non-us-east-1)
if aws s3api head-bucket --profile "$PROFILE" --bucket "$BACKUP_BUCKET" 2>/dev/null; then
  echo "  Bucket already exists, continuing..."
else
  if [ "$REGION" = "us-east-1" ]; then
    aws s3api create-bucket \
      --profile "$PROFILE" \
      --bucket "$BACKUP_BUCKET" \
      --region "$REGION" >/dev/null
  else
    aws s3api create-bucket \
      --profile "$PROFILE" \
      --bucket "$BACKUP_BUCKET" \
      --region "$REGION" \
      --create-bucket-configuration "LocationConstraint=$REGION" >/dev/null
  fi
fi

# Block all public access
aws s3api put-public-access-block \
  --profile "$PROFILE" \
  --bucket "$BACKUP_BUCKET" \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

# Default SSE-S3 encryption
aws s3api put-bucket-encryption \
  --profile "$PROFILE" \
  --bucket "$BACKUP_BUCKET" \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {"SSEAlgorithm":"AES256"},
      "BucketKeyEnabled": true
    }]
  }'

# Versioning
aws s3api put-bucket-versioning \
  --profile "$PROFILE" \
  --bucket "$BACKUP_BUCKET" \
  --versioning-configuration "Status=Enabled"

# Lifecycle: tier out cold backups, expire ancient noncurrent versions
LIFECYCLE_JSON=$(cat <<'EOF'
{
  "Rules": [
    {
      "ID": "tier-cold-backups",
      "Status": "Enabled",
      "Filter": {"Prefix": "daily/"},
      "Transitions": [
        {"Days": 30,  "StorageClass": "STANDARD_IA"},
        {"Days": 90,  "StorageClass": "GLACIER_IR"}
      ],
      "NoncurrentVersionExpiration": {"NoncurrentDays": 365},
      "AbortIncompleteMultipartUpload": {"DaysAfterInitiation": 7}
    }
  ]
}
EOF
)

aws s3api put-bucket-lifecycle-configuration \
  --profile "$PROFILE" \
  --bucket "$BACKUP_BUCKET" \
  --lifecycle-configuration "$LIFECYCLE_JSON"

aws s3api put-bucket-tagging \
  --profile "$PROFILE" \
  --bucket "$BACKUP_BUCKET" \
  --tagging "TagSet=[{Key=Project,Value=nanoclaw}]"

echo "  ✓ Bucket ready: versioning on, public access blocked, SSE-S3, lifecycle configured"

# --- 4. Create Security Group (no inbound, all outbound) ---
echo "[4/8] Creating security group..."

# Get default VPC
VPC_ID=$(aws ec2 describe-vpcs \
  --profile "$PROFILE" \
  --region "$REGION" \
  --filters "Name=isDefault,Values=true" \
  --query 'Vpcs[0].VpcId' \
  --output text)

# Create SG (ignore if exists)
SG_ID=$(aws ec2 create-security-group \
  --profile "$PROFILE" \
  --region "$REGION" \
  --group-name "${NAME_PREFIX}-sg" \
  --description "NanoClaw Second Brain - SSM only, no inbound" \
  --vpc-id "$VPC_ID" \
  --query 'GroupId' \
  --output text 2>/dev/null) || \
SG_ID=$(aws ec2 describe-security-groups \
  --profile "$PROFILE" \
  --region "$REGION" \
  --filters "Name=group-name,Values=${NAME_PREFIX}-sg" \
  --query 'SecurityGroups[0].GroupId' \
  --output text)

# Revoke default SSH rule if present (security groups allow all outbound by default)
aws ec2 revoke-security-group-ingress \
  --profile "$PROFILE" \
  --region "$REGION" \
  --group-id "$SG_ID" \
  --protocol tcp --port 22 --cidr 0.0.0.0/0 \
  2>/dev/null || true

echo "  Security Group: $SG_ID (no inbound rules)"

# --- 5. Launch Instance (retry to absorb IAM propagation delay) ---
echo "[5/8] Launching t4g.large instance..."

BLOCK_DEV="[{\"DeviceName\":\"/dev/xvda\",\"Ebs\":{\"VolumeSize\":${VOLUME_SIZE},\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true,\"Encrypted\":true}}]"

INSTANCE_ID=""
for attempt in 1 2 3 4 5 6; do
  if INSTANCE_ID=$(aws ec2 run-instances \
      --profile "$PROFILE" \
      --region "$REGION" \
      --image-id "$AMI_ID" \
      --instance-type "$INSTANCE_TYPE" \
      --iam-instance-profile Name="${NAME_PREFIX}-profile" \
      --security-group-ids "$SG_ID" \
      --block-device-mappings "$BLOCK_DEV" \
      --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${NAME_PREFIX}},{Key=Project,Value=nanoclaw}]" \
      --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
      --query 'Instances[0].InstanceId' \
      --output text 2>/tmp/run-instances.err); then
    break
  fi
  if grep -q "InvalidParameterValue.*[Ii]nstance [Pp]rofile" /tmp/run-instances.err; then
    echo "  IAM not yet propagated (attempt $attempt/6) — sleeping 10s..."
    sleep 10
    continue
  fi
  cat /tmp/run-instances.err >&2
  exit 1
done

if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" = "None" ]; then
  echo "  Failed to launch instance after retries." >&2
  exit 1
fi

echo "  Instance: $INSTANCE_ID (root volume encrypted)"

# --- 6. Wait for instance to be running ---
echo "[6/8] Waiting for instance to reach running state..."
aws ec2 wait instance-running \
  --profile "$PROFILE" \
  --region "$REGION" \
  --instance-ids "$INSTANCE_ID"

echo "  Instance is running."

# --- 7. Wait for SSM to register ---
echo "[7/8] Waiting for Session Manager registration (up to 2 min)..."
for i in {1..24}; do
  SSM_STATUS=$(aws ssm describe-instance-information \
    --profile "$PROFILE" \
    --region "$REGION" \
    --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
    --query 'InstanceInformationList[0].PingStatus' \
    --output text 2>/dev/null || echo "None")
  if [ "$SSM_STATUS" = "Online" ]; then
    break
  fi
  sleep 5
done

if [ "$SSM_STATUS" = "Online" ]; then
  echo "  SSM agent is online!"
else
  echo "  SSM not yet online — may need another minute. Check with:"
  echo "  aws ssm describe-instance-information --profile $PROFILE --region $REGION --filters Key=InstanceIds,Values=$INSTANCE_ID"
fi

# --- 8. CloudWatch alarm: notify if instance fails its health checks ---
echo "[8/8] Setting up CloudWatch status-check alarm..."

ALERT_EMAIL="${NANOCLAW_ALERT_EMAIL:-}"
if [ -z "$ALERT_EMAIL" ]; then
  read -r -p "  Email address for instance health alerts (blank to skip): " ALERT_EMAIL
fi

if [ -n "$ALERT_EMAIL" ]; then
  TOPIC_NAME="${NAME_PREFIX}-alerts"

  TOPIC_ARN=$(aws sns create-topic \
    --profile "$PROFILE" --region "$REGION" \
    --name "$TOPIC_NAME" \
    --tags "Key=Project,Value=nanoclaw" \
    --query 'TopicArn' --output text)

  # Subscribe email (idempotent — adds the sub if it doesn't exist)
  EXISTING_SUB=$(aws sns list-subscriptions-by-topic \
    --profile "$PROFILE" --region "$REGION" \
    --topic-arn "$TOPIC_ARN" \
    --query "Subscriptions[?Endpoint=='$ALERT_EMAIL'].SubscriptionArn" \
    --output text)

  if [ -z "$EXISTING_SUB" ] || [ "$EXISTING_SUB" = "None" ]; then
    aws sns subscribe \
      --profile "$PROFILE" --region "$REGION" \
      --topic-arn "$TOPIC_ARN" \
      --protocol email \
      --notification-endpoint "$ALERT_EMAIL" >/dev/null
    echo "  Confirmation email sent to $ALERT_EMAIL — click the link to activate."
  else
    echo "  Email subscription already exists."
  fi

  # Composite alarm: trigger on either system or instance status check failures
  for CHECK in StatusCheckFailed_System StatusCheckFailed_Instance; do
    aws cloudwatch put-metric-alarm \
      --profile "$PROFILE" --region "$REGION" \
      --alarm-name "${NAME_PREFIX}-${CHECK}" \
      --alarm-description "EC2 $CHECK on ${NAME_PREFIX}" \
      --namespace AWS/EC2 \
      --metric-name "$CHECK" \
      --statistic Maximum \
      --period 60 \
      --evaluation-periods 2 \
      --threshold 1 \
      --comparison-operator GreaterThanOrEqualToThreshold \
      --dimensions "Name=InstanceId,Value=$INSTANCE_ID" \
      --treat-missing-data breaching \
      --alarm-actions "$TOPIC_ARN"
  done
  echo "  ✓ Alarms armed: ${NAME_PREFIX}-StatusCheckFailed_{System,Instance}"
else
  echo "  Skipped (no email provided)."
fi

echo ""
echo "=== DONE ==="
echo ""
echo "Instance ID:   $INSTANCE_ID"
echo "Region:        $REGION"
echo "Backup bucket: s3://$BACKUP_BUCKET"
echo ""
echo "Connect via Session Manager:"
echo "  aws ssm start-session --profile $PROFILE --region $REGION --target $INSTANCE_ID"
echo ""
echo "Next step: Run the bootstrap script on the instance:"
echo "  # Copy ec2-bootstrap.sh to the instance, then run it"
echo "  # Or paste its contents directly in the SSM session"
