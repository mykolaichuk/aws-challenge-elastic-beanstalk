#!/usr/bin/env bash
# No `set -e`: we want every step to run even if a prior one already exists.

REGION="eu-west-1"
APP_NAME="cmtr-p2vf32dx-app"
ENV_NAME="cmtr-p2vf32dx-env"
INSTANCE_ROLE="ElasticBeanstalkInstanceProfileRole"
SERVICE_ROLE="ElasticBeanstalkServiceRole"

AWS="aws --no-cli-pager --region $REGION"

echo "===== 1. Instance profile role (EC2) ====="
$AWS iam create-role --role-name "$INSTANCE_ROLE" \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {"Service": "ec2.amazonaws.com"},
      "Action": "sts:AssumeRole"
    }]
  }' >/dev/null 2>&1 && echo "created" || echo "already exists, ok"

$AWS iam attach-role-policy --role-name "$INSTANCE_ROLE" \
  --policy-arn arn:aws:iam::aws:policy/AWSElasticBeanstalkWebTier \
  && echo "WebTier policy attached" || echo "WebTier attach FAILED"

$AWS iam create-instance-profile --instance-profile-name "$INSTANCE_ROLE" >/dev/null 2>&1 \
  && echo "instance profile created" || echo "instance profile already exists, ok"

$AWS iam add-role-to-instance-profile \
  --instance-profile-name "$INSTANCE_ROLE" \
  --role-name "$INSTANCE_ROLE" >/dev/null 2>&1 \
  && echo "role added to instance profile" || echo "role already in instance profile, ok"

echo
echo "===== 2. Service role (Elastic Beanstalk) ====="
$AWS iam create-role --role-name "$SERVICE_ROLE" \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {"Service": "elasticbeanstalk.amazonaws.com"},
      "Action": "sts:AssumeRole"
    }]
  }' >/dev/null 2>&1 && echo "created" || echo "already exists, ok"

$AWS iam attach-role-policy --role-name "$SERVICE_ROLE" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSElasticBeanstalkEnhancedHealth \
  && echo "EnhancedHealth attached" || echo "EnhancedHealth attach FAILED"

$AWS iam attach-role-policy --role-name "$SERVICE_ROLE" \
  --policy-arn arn:aws:iam::aws:policy/AWSElasticBeanstalkManagedUpdatesCustomerRolePolicy \
  && echo "ManagedUpdates attached" || echo "ManagedUpdates attach FAILED"

echo
echo "===== 2b. Verify roles ====="
echo "-- instance profile contents:"
$AWS iam get-instance-profile --instance-profile-name "$INSTANCE_ROLE" \
  --query "InstanceProfile.Roles[].RoleName" --output text
echo "-- instance role policies:"
$AWS iam list-attached-role-policies --role-name "$INSTANCE_ROLE" \
  --query "AttachedPolicies[].PolicyName" --output text
echo "-- service role policies:"
$AWS iam list-attached-role-policies --role-name "$SERVICE_ROLE" \
  --query "AttachedPolicies[].PolicyName" --output text

echo
echo "===== 3. Create application ====="
$AWS elasticbeanstalk create-application --application-name "$APP_NAME" >/dev/null 2>&1 \
  && echo "application created" || echo "application already exists, ok"

echo
echo "===== 4. Pick Python solution stack ====="
STACK=$($AWS elasticbeanstalk list-available-solution-stacks \
  --query "SolutionStacks[?contains(@, 'running Python')] | [0]" --output text)
echo "stack: $STACK"

echo
echo "===== 5. Create environment (takes ~5 min) ====="
$AWS elasticbeanstalk create-environment \
  --application-name "$APP_NAME" \
  --environment-name "$ENV_NAME" \
  --solution-stack-name "$STACK" \
  --option-settings \
    Namespace=aws:autoscaling:launchconfiguration,OptionName=IamInstanceProfile,Value="$INSTANCE_ROLE" \
    Namespace=aws:elasticbeanstalk:environment,OptionName=ServiceRole,Value="$SERVICE_ROLE" \
    Namespace=aws:elasticbeanstalk:environment,OptionName=EnvironmentType,Value=SingleInstance \
  --query "{Env:EnvironmentName,Status:Status}" --output table

echo
echo "===== Done. Poll status with: ====="
echo "aws --no-cli-pager elasticbeanstalk describe-environments --region $REGION --environment-names $ENV_NAME --query 'Environments[0].{Status:Status,Health:Health,CNAME:CNAME}' --output table"
