#!/bin/bash
set -e
sudo yum update -y
sudo yum install docker -y
sudo systemctl start docker
sudo systemctl enable docker
sudo usermod -aG docker ec2-user
sudo yum install jq -y

# This placeholder is replaced by templatefile() in main.tf
DB_SECRET_ARN="${db_secret_arn_placeholder}"

# Hardcode region to prevent aws cli errors
SECRET_JSON=$(aws secretsmanager get-secret-value --secret-id $DB_SECRET_ARN --region ap-south-1 --query SecretString --output text)

DB_HOST=$(echo $SECRET_JSON | jq -r .DB_HOST)
DB_USER=$(echo $SECRET_JSON | jq -r .DB_USER)
DB_PASS=$(echo $SECRET_JSON | jq -r .DB_PASSWORD)
DB_NAME=$(echo $SECRET_JSON | jq -r .DB_NAME)

docker run -d \
  --name wordpress \
  -p 80:80 \
  -e WORDPRESS_DB_HOST=$DB_HOST \
  -e WORDPRESS_DB_USER=$DB_USER \
  -e WORDPRESS_DB_PASSWORD=$DB_PASS \
  -e WORDPRESS_DB_NAME=$DB_NAME \
  -e WORDPRESS_DEBUG=1 \
  -e WORDPRESS_DEBUG_LOG=/var/www/html/wp-content/debug.log \
  -e WORDPESS_DEBUG_DISPLAY=false \
  --restart always \
  wordpress:latest
