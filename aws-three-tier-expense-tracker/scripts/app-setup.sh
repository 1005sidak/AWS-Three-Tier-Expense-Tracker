#!/bin/bash
# App tier setup. Run on the temporary app BUILD instance (Amazon Linux 2023,
# public subnet, LabInstanceProfile attached) through Session Manager:
#   sudo bash app-setup.sh <your-s3-bucket-name>
# It installs Node.js, copies the API from S3, asks for the RDS details,
# and installs the API as a systemd service that starts on every boot.
set -euo pipefail

BUCKET="${1:?Usage: sudo bash app-setup.sh <s3-bucket-name>}"
APP_DIR=/opt/expense/app-tier

echo "==> Installing Node.js"
dnf install -y nodejs nodejs-npm || dnf install -y nodejs npm

echo "==> Copying API code from s3://$BUCKET/app-tier"
mkdir -p "$APP_DIR"
aws s3 cp "s3://$BUCKET/app-tier" "$APP_DIR" --recursive --exclude "node_modules/*"

echo "==> Installing dependencies"
cd "$APP_DIR"
npm install --omit=dev

echo "==> Database settings (from the RDS console)"
read -rp "RDS endpoint (e.g. expense-db.xxxx.us-east-1.rds.amazonaws.com): " DB_HOST
read -rp "Master username [admin]: " DB_USER
DB_USER=${DB_USER:-admin}
read -rsp "Master password: " DB_PASSWORD; echo
read -rp "Initial database name [expensedb]: " DB_NAME
DB_NAME=${DB_NAME:-expensedb}

cat > "$APP_DIR/.env" <<EOF
PORT=4000
DB_HOST=$DB_HOST
DB_PORT=3306
DB_USER=$DB_USER
DB_PASSWORD=$DB_PASSWORD
DB_NAME=$DB_NAME
EOF
chmod 600 "$APP_DIR/.env"

echo "==> Creating systemd service"
cat > /etc/systemd/system/expense-api.service <<EOF
[Unit]
Description=Expense Tracker API (app tier)
After=network-online.target
Wants=network-online.target

[Service]
WorkingDirectory=$APP_DIR
EnvironmentFile=$APP_DIR/.env
ExecStart=/usr/bin/node $APP_DIR/index.js
Restart=always
RestartSec=3
User=nobody

[Install]
WantedBy=multi-user.target
EOF
chown -R nobody: "$APP_DIR"

systemctl daemon-reload
systemctl enable --now expense-api
sleep 3

echo "==> Testing"
curl -s localhost:4000/health; echo
curl -s localhost:4000/health/db; echo
echo
echo "If /health/db shows \"reachable\", the app tier is ready to be saved as an AMI."
