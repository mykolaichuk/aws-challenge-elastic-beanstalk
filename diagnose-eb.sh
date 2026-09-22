#!/usr/bin/env bash

REGION="eu-west-1"
ENV_NAME="cmtr-p2vf32dx-env"
STACK="awseb-e-3fea4zgkbm-stack"

AWS="aws --no-cli-pager --region $REGION"

echo "===== 1. Beanstalk events (most recent last) ====="
$AWS elasticbeanstalk describe-events \
  --environment-name "$ENV_NAME" \
  --max-items 40 \
  --query "reverse(Events[].{Time:EventDate,Sev:Severity,Msg:Message})" \
  --output text

echo
echo "===== 2. CloudFormation failures (the real reason) ====="
$AWS cloudformation describe-stack-events --stack-name "$STACK" \
  --query "StackEvents[?ResourceStatus=='CREATE_FAILED'].{Resource:LogicalResourceId,Reason:ResourceStatusReason}" \
  --output text

echo
echo "===== 3. Is there a usable VPC? ====="
echo "-- default VPC:"
$AWS ec2 describe-vpcs --filters "Name=isDefault,Values=true" \
  --query "Vpcs[].VpcId" --output text
echo "-- all VPCs:"
$AWS ec2 describe-vpcs --query "Vpcs[].{Id:VpcId,Default:IsDefault,Cidr:CidrBlock}" --output table

echo
echo "===== 4. Instance profile sanity ====="
$AWS iam get-instance-profile --instance-profile-name ElasticBeanstalkInstanceProfileRole \
  --query "InstanceProfile.Roles[].RoleName" --output text
