#!/bin/bash
# Automated deployment of the three-tier expense tracker with the AWS CLI.
# Usage: bash deploy.sh all | net | db | app | web | mon | status | pause | resume | teardown
# Run from a folder that also contains app-tier/ and web-tier/.
# IDs are saved in state.env so phases can be re-run or resumed.
set -eo pipefail
export AWS_DEFAULT_REGION=us-east-1
cd "$(dirname "$0")"
touch state.env; source state.env
save(){ sed -i "/^$1=/d" state.env; echo "$1=\"$2\"" >> state.env; eval "$1=\"$2\""; }
log(){ echo "[$(date +%H:%M:%S)] $*"; }
tag(){ echo "ResourceType=$1,Tags=[{Key=Name,Value=$2},{Key=Project,Value=expense}]"; }
trap 'log "ERROR on line $LINENO (exit $?)"' ERR

net(){
  [ -n "$VPC" ] && { log "Network exists ($VPC)"; return; }
  log "Creating VPC"
  save VPC "$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 --tag-specifications "$(tag vpc expense-vpc)" --query Vpc.VpcId --output text)"
  aws ec2 modify-vpc-attribute --vpc-id $VPC --enable-dns-hostnames
  save IGW "$(aws ec2 create-internet-gateway --tag-specifications "$(tag internet-gateway expense-igw)" --query InternetGateway.InternetGatewayId --output text)"
  aws ec2 attach-internet-gateway --vpc-id $VPC --internet-gateway-id $IGW
  mk(){ save $1 "$(aws ec2 create-subnet --vpc-id $VPC --cidr-block $2 --availability-zone us-east-1$3 --tag-specifications "$(tag subnet $4)" --query Subnet.SubnetId --output text)"; }
  mk WEB_A 10.0.1.0/24 a web-public-a;  mk WEB_B 10.0.2.0/24 b web-public-b
  mk APP_A 10.0.11.0/24 a app-private-a; mk APP_B 10.0.12.0/24 b app-private-b
  mk DB_A 10.0.21.0/24 a db-private-a;   mk DB_B 10.0.22.0/24 b db-private-b
  log "Route tables"
  save RT_PUB "$(aws ec2 create-route-table --vpc-id $VPC --tag-specifications "$(tag route-table public-rt)" --query RouteTable.RouteTableId --output text)"
  aws ec2 create-route --route-table-id $RT_PUB --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW >/dev/null
  save RT_PRIV "$(aws ec2 create-route-table --vpc-id $VPC --tag-specifications "$(tag route-table private-rt)" --query RouteTable.RouteTableId --output text)"
  for s in $WEB_A $WEB_B; do
    aws ec2 associate-route-table --route-table-id $RT_PUB --subnet-id $s >/dev/null
    aws ec2 modify-subnet-attribute --subnet-id $s --map-public-ip-on-launch
  done
  for s in $APP_A $APP_B $DB_A $DB_B; do aws ec2 associate-route-table --route-table-id $RT_PRIV --subnet-id $s >/dev/null; done
  log "Security groups (each tier only accepts the tier in front of it)"
  sg(){ save $1 "$(aws ec2 create-security-group --vpc-id $VPC --group-name $2 --description "$3" --tag-specifications "$(tag security-group $2)" --query GroupId --output text)"; }
  sg SG_WEB_ALB web-alb-sg "Public ALB: HTTP from internet"
  sg SG_WEB web-sg "Web tier: HTTP from public ALB"
  sg SG_APP_ALB app-alb-sg "Internal ALB: HTTP from web tier"
  sg SG_APP app-sg "App tier: 4000 from internal ALB"
  sg SG_DB db-sg "Database: MySQL from app tier"
  aws ec2 authorize-security-group-ingress --group-id $SG_WEB_ALB --protocol tcp --port 80 --cidr 0.0.0.0/0 >/dev/null
  aws ec2 authorize-security-group-ingress --group-id $SG_WEB --protocol tcp --port 80 --source-group $SG_WEB_ALB >/dev/null
  aws ec2 authorize-security-group-ingress --group-id $SG_APP_ALB --protocol tcp --port 80 --source-group $SG_WEB >/dev/null
  aws ec2 authorize-security-group-ingress --group-id $SG_APP --protocol tcp --port 4000 --source-group $SG_APP_ALB >/dev/null
  aws ec2 authorize-security-group-ingress --group-id $SG_DB --protocol tcp --port 3306 --source-group $SG_APP >/dev/null
  log "S3 bucket with the code"
  save BUCKET "expense-code-$(aws sts get-caller-identity --query Account --output text)-$RANDOM"
  aws s3 mb s3://$BUCKET >/dev/null
  aws s3 cp app-tier s3://$BUCKET/app-tier --recursive --quiet
  aws s3 cp web-tier s3://$BUCKET/web-tier --recursive --quiet
  log "Network done"
}

db(){
  [ -z "$DB_PASS" ] && save DB_PASS "Exp$(openssl rand -hex 6)"
  if ! aws rds describe-db-instances --db-instance-identifier expense-db >/dev/null 2>&1; then
    log "Creating RDS MySQL (about 10 minutes)"
    aws rds create-db-subnet-group --db-subnet-group-name expense-db-subnets --db-subnet-group-description "DB tier private subnets" --subnet-ids $DB_A $DB_B >/dev/null
    aws rds create-db-instance --db-instance-identifier expense-db --engine mysql --db-instance-class db.t3.micro \
      --allocated-storage 20 --storage-type gp2 --master-username admin --master-user-password "$DB_PASS" \
      --db-name expensedb --vpc-security-group-ids $SG_DB --db-subnet-group-name expense-db-subnets \
      --no-publicly-accessible --no-multi-az --backup-retention-period 0 --tags Key=Project,Value=expense >/dev/null
  fi
  aws rds wait db-instance-available --db-instance-identifier expense-db
  save DB_HOST "$(aws rds describe-db-instances --db-instance-identifier expense-db --query 'DBInstances[0].Endpoint.Address' --output text)"
  log "Database ready: $DB_HOST"
}

ami_al2023(){ aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 --query Parameter.Value --output text; }

# Free S3 gateway endpoint: lets private app servers reach S3 (code bundle + Amazon Linux package repos) without a NAT gateway.
endpoint(){
  [ -n "$VPCE" ] && return
  save VPCE "$(aws ec2 create-vpc-endpoint --vpc-id $VPC --service-name com.amazonaws.us-east-1.s3 --route-table-ids $RT_PRIV --query VpcEndpoint.VpcEndpointId --output text)"
  log "S3 gateway endpoint $VPCE added to the private route table"
}

# One-time temporary instance in a public subnet: runs npm install, uploads app-tier + node_modules to S3, then terminates itself.
bundle(){
  aws s3 ls s3://$BUCKET/bundle/app-tier.tgz >/dev/null 2>&1 && { log "App bundle already in S3"; return; }
  cat > /tmp/ud-bundle.sh <<UD
#!/bin/bash
export HOME=/root; mkdir -p /b && cd /b
curl -fsSL https://nodejs.org/dist/v20.18.1/node-v20.18.1-linux-x64.tar.xz | tar xJ && mv node-v20.18.1-linux-x64 node
aws s3 cp s3://$BUCKET/app-tier /b/app-tier --recursive --region us-east-1
export PATH=/b/node/bin:\$PATH
cd /b/app-tier && npm install --omit=dev && cd /b && tar czf app-tier.tgz app-tier node
aws s3 cp app-tier.tgz s3://$BUCKET/bundle/app-tier.tgz --region us-east-1
shutdown -h now
UD
  aws ec2 run-instances --image-id "$(ami_al2023)" --instance-type t3.micro --subnet-id $WEB_A --security-group-ids $SG_APP \
    --iam-instance-profile Name=LabInstanceProfile --associate-public-ip-address --instance-initiated-shutdown-behavior terminate \
    --user-data file:///tmp/ud-bundle.sh --tag-specifications "$(tag instance bundle-builder)" >/dev/null
  log "Temporary builder is packaging Node.js and the API with its libraries (about 3 minutes)"
  for i in $(seq 1 60); do aws s3 ls s3://$BUCKET/bundle/app-tier.tgz >/dev/null 2>&1 && break; sleep 10; done
  log "App bundle ready in S3"
}

# Target group + load balancer + launch template (Amazon Linux + boot script) + auto scaling group for one tier.
tier(){ # $1=tier $2=port $3=scheme $4=subnetA $5=subnetB $6=alb-sg $7=instance-sg $8=cpu-target $9=userdata-file
  local T=${1^^}
  save TG_$T "$(aws elbv2 create-target-group --name $1-tg --protocol HTTP --port $2 --vpc-id $VPC --health-check-path /health \
    --health-check-interval-seconds 15 --healthy-threshold-count 2 --query 'TargetGroups[0].TargetGroupArn' --output text)"
  local tg; eval tg=\$TG_$T
  save ALB_$T "$(aws elbv2 create-load-balancer --name $1-alb --scheme $3 --type application --subnets $4 $5 --security-groups $6 \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text)"
  local alb; eval alb=\$ALB_$T
  save DNS_$T "$(aws elbv2 describe-load-balancers --load-balancer-arns $alb --query 'LoadBalancers[0].DNSName' --output text)"
  aws elbv2 create-listener --load-balancer-arn $alb --protocol HTTP --port 80 --default-actions Type=forward,TargetGroupArn=$tg >/dev/null
  aws ec2 delete-launch-template --launch-template-name $1-tier-lt >/dev/null 2>&1 || true
  aws ec2 create-launch-template --launch-template-name $1-tier-lt --launch-template-data \
    "{\"ImageId\":\"$(ami_al2023)\",\"InstanceType\":\"t3.micro\",\"SecurityGroupIds\":[\"$7\"],\"IamInstanceProfile\":{\"Name\":\"LabInstanceProfile\"},\"UserData\":\"$(base64 -w0 $9)\",\"TagSpecifications\":[{\"ResourceType\":\"instance\",\"Tags\":[{\"Key\":\"Name\",\"Value\":\"$1-asg\"},{\"Key\":\"Project\",\"Value\":\"expense\"}]}]}" >/dev/null
  aws autoscaling create-auto-scaling-group --auto-scaling-group-name $1-asg \
    --launch-template "LaunchTemplateName=$1-tier-lt,Version=\$Latest" --min-size 2 --max-size 3 --desired-capacity 2 \
    --vpc-zone-identifier "$4,$5" --target-group-arns $tg --health-check-type ELB --health-check-grace-period 300
  aws autoscaling enable-metrics-collection --auto-scaling-group-name $1-asg --granularity 1Minute
  aws autoscaling put-scaling-policy --auto-scaling-group-name $1-asg --policy-name $1-cpu-target --policy-type TargetTrackingScaling \
    --target-tracking-configuration "{\"PredefinedMetricSpecification\":{\"PredefinedMetricType\":\"ASGAverageCPUUtilization\"},\"TargetValue\":$8}" >/dev/null
  log "Waiting for $1 instances to boot, install and pass health checks (about 5 minutes)"
  for i in $(seq 1 60); do
    n=$(aws elbv2 describe-target-health --target-group-arn $tg --query "length(TargetHealthDescriptions[?TargetHealth.State=='healthy'])" --output text)
    [ "$n" -ge 2 ] && break; sleep 15
  done
  log "$1 tier: $n healthy instance(s)"
}

asg_exists(){ [ "$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names $1 --query 'length(AutoScalingGroups)' --output text)" = "1" ]; }

app(){
  asg_exists app-asg && { log "App tier exists"; return; }
  endpoint; bundle
  cat > /tmp/ud-app.sh <<UD
#!/bin/bash
mkdir -p /opt/expense && cd /opt/expense
aws s3 cp s3://$BUCKET/bundle/app-tier.tgz . --region us-east-1 && tar xzf app-tier.tgz
printf 'PORT=4000\nDB_HOST=$DB_HOST\nDB_PORT=3306\nDB_USER=admin\nDB_PASSWORD=$DB_PASS\nDB_NAME=expensedb\n' > app-tier/.env
chmod 600 app-tier/.env; chown -R nobody: /opt/expense
cat > /etc/systemd/system/expense-api.service <<'U'
[Unit]
Description=Expense Tracker API (app tier)
After=network-online.target
[Service]
WorkingDirectory=/opt/expense/app-tier
EnvironmentFile=/opt/expense/app-tier/.env
ExecStart=/opt/expense/node/bin/node index.js
Restart=always
User=nobody
[Install]
WantedBy=multi-user.target
U
systemctl daemon-reload; systemctl enable --now expense-api
UD
  tier app 4000 internal $APP_A $APP_B $SG_APP_ALB $SG_APP 30 /tmp/ud-app.sh
}

web(){
  asg_exists web-asg && { log "Web tier exists"; return; }
  cat > /tmp/ud-web.sh <<UD
#!/bin/bash
dnf install -y nginx
mkdir -p /usr/share/nginx/html/expense /tmp/w
aws s3 cp s3://$BUCKET/web-tier /tmp/w --recursive --region us-east-1
cp /tmp/w/index.html /tmp/w/style.css /tmp/w/app.js /usr/share/nginx/html/expense/
sed "s/INTERNAL_ALB_DNS/$DNS_APP/" /tmp/w/nginx.conf > /etc/nginx/nginx.conf
systemctl enable nginx; systemctl restart nginx
UD
  tier web 80 internet-facing $WEB_A $WEB_B $SG_WEB_ALB $SG_WEB 50 /tmp/ud-web.sh
  log "APP IS LIVE:  http://$DNS_WEB"
}

# Remove images left over from the earlier image-based approach (the sandbox does not allow launching them).
cleanup_amis(){
  for v in AMI_APP AMI_WEB; do
    eval a=\$$v; [ -z "$a" ] && continue
    s=$(aws ec2 describe-images --image-ids $a --query 'Images[0].BlockDeviceMappings[0].Ebs.SnapshotId' --output text 2>/dev/null)
    aws ec2 deregister-image --image-id $a 2>/dev/null; [ -n "$s" ] && aws ec2 delete-snapshot --snapshot-id $s 2>/dev/null
    sed -i "/^$v=/d" state.env
  done; true
}

mon(){
  local a=${ALB_WEB#*loadbalancer/} tw=${TG_WEB##*:} ta=${TG_APP##*:}
  aws cloudwatch put-dashboard --dashboard-name expense-dashboard --dashboard-body "{\"widgets\":[
{\"type\":\"metric\",\"x\":0,\"y\":0,\"width\":12,\"height\":6,\"properties\":{\"title\":\"CPU by tier (%)\",\"region\":\"us-east-1\",\"stat\":\"Average\",\"period\":60,\"metrics\":[[\"AWS/EC2\",\"CPUUtilization\",\"AutoScalingGroupName\",\"app-asg\"],[\"...\",\"web-asg\"]]}},
{\"type\":\"metric\",\"x\":12,\"y\":0,\"width\":12,\"height\":6,\"properties\":{\"title\":\"Instances in service\",\"region\":\"us-east-1\",\"stat\":\"Average\",\"period\":60,\"metrics\":[[\"AWS/AutoScaling\",\"GroupInServiceInstances\",\"AutoScalingGroupName\",\"app-asg\"],[\"...\",\"web-asg\"]]}},
{\"type\":\"metric\",\"x\":0,\"y\":6,\"width\":12,\"height\":6,\"properties\":{\"title\":\"Requests (public ALB)\",\"region\":\"us-east-1\",\"stat\":\"Sum\",\"period\":60,\"metrics\":[[\"AWS/ApplicationELB\",\"RequestCount\",\"LoadBalancer\",\"$a\"]]}},
{\"type\":\"metric\",\"x\":12,\"y\":6,\"width\":12,\"height\":6,\"properties\":{\"title\":\"Healthy hosts\",\"region\":\"us-east-1\",\"stat\":\"Minimum\",\"period\":60,\"metrics\":[[\"AWS/ApplicationELB\",\"HealthyHostCount\",\"TargetGroup\",\"$tw\",\"LoadBalancer\",\"$a\"]]}}]}" >/dev/null
  log "CloudWatch dashboard expense-dashboard created"
}

status(){
  echo "Website: http://$DNS_WEB"
  aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names app-asg web-asg \
    --query 'AutoScalingGroups[].[AutoScalingGroupName,DesiredCapacity,length(Instances)]' --output text 2>/dev/null || true
  aws rds describe-db-instances --db-instance-identifier expense-db --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || true
}

pause(){
  for g in web-asg app-asg; do aws autoscaling update-auto-scaling-group --auto-scaling-group-name $g --min-size 0 --desired-capacity 0 || true; done
  aws rds stop-db-instance --db-instance-identifier expense-db >/dev/null || true
  log "Paused: no EC2 running, database stopping. Load balancers still cost a little per hour."
}

resume(){
  aws rds start-db-instance --db-instance-identifier expense-db >/dev/null 2>&1 || true
  aws rds wait db-instance-available --db-instance-identifier expense-db
  for g in app-asg web-asg; do aws autoscaling update-auto-scaling-group --auto-scaling-group-name $g --min-size 2 --desired-capacity 2; done
  log "Resumed. Give it about 4 minutes, then open http://$DNS_WEB"
}

teardown(){
  set +e
  for g in web-asg app-asg; do aws autoscaling delete-auto-scaling-group --auto-scaling-group-name $g --force-delete; done
  for a in $ALB_WEB $ALB_APP; do aws elbv2 delete-load-balancer --load-balancer-arn $a; done
  aws rds delete-db-instance --db-instance-identifier expense-db --skip-final-snapshot >/dev/null
  sleep 90
  for t in $TG_WEB $TG_APP; do aws elbv2 delete-target-group --target-group-arn $t; done
  for l in web-tier-lt app-tier-lt; do aws ec2 delete-launch-template --launch-template-name $l >/dev/null; done
  cleanup_amis
  [ -n "$VPCE" ] && aws ec2 delete-vpc-endpoints --vpc-endpoint-ids $VPCE >/dev/null
  aws s3 rb s3://$BUCKET --force
  aws cloudwatch delete-dashboards --dashboard-names expense-dashboard
  aws rds wait db-instance-deleted --db-instance-identifier expense-db
  aws rds delete-db-subnet-group --db-subnet-group-name expense-db-subnets
  sleep 60
  for g in $SG_DB $SG_APP $SG_APP_ALB $SG_WEB $SG_WEB_ALB; do aws ec2 delete-security-group --group-id $g; done
  for s in $WEB_A $WEB_B $APP_A $APP_B $DB_A $DB_B; do aws ec2 delete-subnet --subnet-id $s; done
  aws ec2 delete-route-table --route-table-id $RT_PUB; aws ec2 delete-route-table --route-table-id $RT_PRIV
  aws ec2 detach-internet-gateway --internet-gateway-id $IGW --vpc-id $VPC; aws ec2 delete-internet-gateway --internet-gateway-id $IGW
  aws ec2 delete-vpc --vpc-id $VPC && : > state.env
  log "Everything deleted"
}

case "$1" in
  all) net; db; cleanup_amis; app; web; mon; status ;;
  net|db|app|web|mon|status|pause|resume|teardown) $1 ;;
  *) echo "Usage: bash deploy.sh all|net|db|app|web|mon|status|pause|resume|teardown" ;;
esac
