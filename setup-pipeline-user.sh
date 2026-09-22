#!/usr/bin/env bash

REGION="eu-west-1"
DEPLOY_USER="github-actions-deployer"

AWS="aws --no-cli-pager --region $REGION"

echo "===== A. Ensure pipeline user exists ====="
$AWS iam create-user --user-name "$DEPLOY_USER" >/dev/null 2>&1 \
  && echo "user created" || echo "user already exists, ok"

$AWS iam attach-user-policy --user-name "$DEPLOY_USER" \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess-AWSElasticBeanstalk \
  && echo "EB admin policy attached" || echo "policy attach FAILED"

echo
echo "===== B. Delete any existing access keys (max 2 per user) ====="
for KEY in $($AWS iam list-access-keys --user-name "$DEPLOY_USER" \
               --query "AccessKeyMetadata[].AccessKeyId" --output text); do
  $AWS iam delete-access-key --user-name "$DEPLOY_USER" --access-key-id "$KEY" \
    && echo "deleted old key $KEY"
done

echo
echo "===== C. Create fresh access key ====="
CREDS=$($AWS iam create-access-key --user-name "$DEPLOY_USER" \
  --query "AccessKey.[AccessKeyId,SecretAccessKey]" --output text)

AKID=$(echo "$CREDS" | cut -f1)
SECRET=$(echo "$CREDS" | cut -f2)

echo
echo "Copy these EXACTLY into GitHub secrets (no leading/trailing spaces):"
echo
echo "AWS_ACCESS_KEY_ID"
echo "$AKID"
echo
echo "AWS_SECRET_ACCESS_KEY"
echo "$SECRET"
echo
echo "(key id length: ${#AKID}, secret length: ${#SECRET}  <- secret should be 40)"

echo
echo "===== D. Verify the key actually works (waits for IAM propagation) ====="
sleep 15
env -u AWS_SESSION_TOKEN -u AWS_PROFILE \
  AWS_ACCESS_KEY_ID="$AKID" \
  AWS_SECRET_ACCESS_KEY="$SECRET" \
  aws --no-cli-pager sts get-caller-identity --region "$REGION" \
  && echo "KEY WORKS" || echo "KEY FAILED - wait 10s and retry, IAM propagation can lag"
