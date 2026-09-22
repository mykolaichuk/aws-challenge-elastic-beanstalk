#!/usr/bin/env bash

REGION="eu-west-1"
APP_NAME="cmtr-p2vf32dx-app"
ENV_NAME="cmtr-p2vf32dx-env"
INSTANCE_ROLE="ElasticBeanstalkInstanceProfileRole"
SERVICE_ROLE="ElasticBeanstalkServiceRole"
VPC_ID="vpc-0efc4bd014734ae1e"

AWS="aws --no-cli-pager --region $REGION"

echo "===== 1. Find internet gateway for the VPC ====="
IGW=$($AWS ec2 describe-internet-gateways \
  --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
  --query "InternetGateways[0].InternetGatewayId" --output text)
echo "IGW: $IGW"
if [ "$IGW" = "None" ] || [ -z "$IGW" ]; then
  echo "ERROR: no internet gateway attached to $VPC_ID - the app could not be reachable."
  exit 1
fi

echo
echo "===== 2. Identify PUBLIC subnets (route to the IGW) ====="
MAIN_RT=$($AWS ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=association.main,Values=true" \
  --query "RouteTables[0].RouteTableId" --output text)

PUBLIC_SUBNETS=""
for SUBNET in $($AWS ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" \
                  --query "Subnets[].SubnetId" --output text); do
  RT=$($AWS ec2 describe-route-tables \
        --filters "Name=association.subnet-id,Values=$SUBNET" \
        --query "RouteTables[0].RouteTableId" --output text)
  [ "$RT" = "None" ] && RT="$MAIN_RT"

  HAS_IGW=$($AWS ec2 describe-route-tables --route-table-ids "$RT" \
    --query "RouteTables[0].Routes[?starts_with(GatewayId, 'igw-')] | length(@)" --output text)

  AZ=$($AWS ec2 describe-subnets --subnet-ids "$SUBNET" \
    --query "Subnets[0].AvailabilityZone" --output text)

  if [ "$HAS_IGW" != "0" ]; then
    echo "  $SUBNET ($AZ, rt=$RT) -> PUBLIC"
    PUBLIC_SUBNETS="${PUBLIC_SUBNETS:+$PUBLIC_SUBNETS,}$SUBNET"
  else
    echo "  $SUBNET ($AZ, rt=$RT) -> private"
  fi
done

echo "Public subnets: $PUBLIC_SUBNETS"
if [ -z "$PUBLIC_SUBNETS" ]; then
  echo "ERROR: no public subnets found; the environment would not be reachable."
  exit 1
fi

echo
echo "===== 3. Terminate the failed environment ====="
$AWS elasticbeanstalk terminate-environment --environment-name "$ENV_NAME" \
  --query "{Env:EnvironmentName,Status:Status}" --output table 2>/dev/null \
  && echo "termination requested" || echo "nothing to terminate (or already gone)"

echo "waiting for termination (up to ~10 min)..."
$AWS elasticbeanstalk wait environment-terminated --environment-names "$ENV_NAME" 2>/dev/null
echo "terminated."

echo
echo "===== 4. Pick Python solution stack ====="
STACK=$($AWS elasticbeanstalk list-available-solution-stacks \
  --query "SolutionStacks[?contains(@, 'running Python')] | [0]" --output text)
echo "stack: $STACK"

echo
echo "===== 5. Recreate environment inside the VPC ====="
OPTS_FILE=$(mktemp)
cat > "$OPTS_FILE" <<JSON
[
  {"Namespace":"aws:autoscaling:launchconfiguration","OptionName":"IamInstanceProfile","Value":"$INSTANCE_ROLE"},
  {"Namespace":"aws:autoscaling:launchconfiguration","OptionName":"InstanceType","Value":"t3.micro"},
  {"Namespace":"aws:elasticbeanstalk:environment","OptionName":"ServiceRole","Value":"$SERVICE_ROLE"},
  {"Namespace":"aws:elasticbeanstalk:environment","OptionName":"EnvironmentType","Value":"SingleInstance"},
  {"Namespace":"aws:ec2:vpc","OptionName":"VPCId","Value":"$VPC_ID"},
  {"Namespace":"aws:ec2:vpc","OptionName":"Subnets","Value":"$PUBLIC_SUBNETS"},
  {"Namespace":"aws:ec2:vpc","OptionName":"AssociatePublicIpAddress","Value":"true"}
]
JSON
echo "option settings:"
cat "$OPTS_FILE"

$AWS elasticbeanstalk create-environment \
  --application-name "$APP_NAME" \
  --environment-name "$ENV_NAME" \
  --solution-stack-name "$STACK" \
  --option-settings "file://$OPTS_FILE" \
  --query "{Env:EnvironmentName,Status:Status}" --output table

echo
echo "===== 6. Waiting for environment to come up (~5 min) ====="
for i in $(seq 1 60); do
  read -r STATUS HEALTH CNAME <<<"$($AWS elasticbeanstalk describe-environments \
    --environment-names "$ENV_NAME" \
    --query "Environments[0].[Status,Health,CNAME]" --output text)"
  echo "  [$i] Status=$STATUS Health=$HEALTH"
  [ "$STATUS" = "Ready" ] && break
  sleep 15
done

echo
echo "Status: $STATUS   Health: $HEALTH"
echo "CNAME:  $CNAME"

echo
echo "===== 7. Any errors during launch? ====="
$AWS elasticbeanstalk describe-events --environment-name "$ENV_NAME" \
  --severity ERROR --max-items 10 \
  --query "Events[].Message" --output text

echo
echo "If Health is Green/Grey and Status is Ready, re-run the GitHub workflow."
