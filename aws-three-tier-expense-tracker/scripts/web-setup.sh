#!/bin/bash
# Web tier setup. Run on the temporary web BUILD instance (Amazon Linux 2023,
# public subnet, LabInstanceProfile attached) through Session Manager:
#   sudo bash web-setup.sh <your-s3-bucket-name> <internal-alb-dns-name>
# It installs Nginx, copies the front end from S3 and points /api at the internal ALB.
set -euo pipefail

BUCKET="${1:?Usage: sudo bash web-setup.sh <s3-bucket-name> <internal-alb-dns>}"
ALB_DNS="${2:?Usage: sudo bash web-setup.sh <s3-bucket-name> <internal-alb-dns>}"
WEB_DIR=/usr/share/nginx/html/expense

echo "==> Installing Nginx"
dnf install -y nginx

echo "==> Copying front end from s3://$BUCKET/web-tier"
mkdir -p "$WEB_DIR" /tmp/web-tier
aws s3 cp "s3://$BUCKET/web-tier" /tmp/web-tier --recursive
cp /tmp/web-tier/index.html /tmp/web-tier/style.css /tmp/web-tier/app.js "$WEB_DIR/"

echo "==> Configuring Nginx to forward /api to $ALB_DNS"
sed "s/INTERNAL_ALB_DNS/$ALB_DNS/" /tmp/web-tier/nginx.conf > /etc/nginx/nginx.conf
nginx -t

systemctl enable nginx
systemctl restart nginx
sleep 2

echo "==> Testing"
curl -s localhost/health
curl -s localhost/api/health; echo
echo
echo "If /api/health returns {\"status\":\"ok\",...}, the web tier is ready to be saved as an AMI."
