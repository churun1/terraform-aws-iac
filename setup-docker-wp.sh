#!/bin/bash
set -e # Exit immediately if a command fails

# 1. Install Host-Side Dependencies
# ADDED: 'git' to clone the repo, 'mysql' to create the database
sudo yum install -y docker jq curl git mariadb105 --allowerasing

# 2. Start Docker service
sudo systemctl start docker
sudo systemctl enable docker
sudo usermod -aG docker ec2-user

# 3. Get Injected Terraform Variables
DB_SECRET_ARN="${db_secret_arn}"
# lb_dns_name is also injected by Terraform

# 4. Fetch the secret value from Secrets Manager
SECRET_JSON=$(aws secretsmanager get-secret-value --secret-id $DB_SECRET_ARN --region ap-south-1 --query SecretString --output text)

# 5. Check if the secret was fetched
if [ -z "$SECRET_JSON" ]; then
  echo "ERROR: Could not retrieve secrets from Secrets Manager. Exiting."
  exit 1
fi

# 6. Parse Secrets
DB_HOST=$(echo $SECRET_JSON | jq -r .DB_HOST)
DB_USER=$(echo $SECRET_JSON | jq -r .DB_USER)
DB_PASS=$(echo $SECRET_JSON | jq -r .DB_PASSWORD)
DB_NAME=$(echo $SECRET_JSON | jq -r .DB_NAME)
WP_ADMIN_USER=$(echo $SECRET_JSON | jq -r .WP_ADMIN_USER)
WP_ADMIN_PASS=$(echo $SECRET_JSON | jq -r .WP_ADMIN_PASS)
WP_ADMIN_EMAIL=$(echo $SECRET_JSON | jq -r .WP_ADMIN_EMAIL)

# --- NEW: Fetch Bitbucket Key ---
BITBUCKET_SSH_KEY=$(echo "$SECRET_JSON" | jq -r .BITBUCKET_SSH_KEY)
# --- END NEW ---

# 7. Create directories
sudo mkdir -p /srv/wordpress/wp-content
sudo chmod -R 777 /srv/wordpress/wp-content
sudo mkdir -p /srv/easy-app

# -----------------------------------------------------
# SECTION A: WORDPRESS SETUP
# -----------------------------------------------------

# 8. Download plugins from S3
echo "Downloading plugins from S3..."
aws s3 cp s3://wordpress-plugins-0/all-in-one-wp-migration.zip /tmp/all-in-one-wp-migration.zip
aws s3 cp s3://wordpress-plugins-0/all-in-one-wp-migration-unlimited-extension.zip /tmp/all-in-one-wp-migration-unlimited-extension.zip

# 9. Unzip plugins
sudo yum install -y unzip
sudo unzip -o /tmp/all-in-one-wp-migration.zip -d /srv/wordpress/wp-content/plugins/
sudo unzip -o /tmp/all-in-one-wp-migration-unlimited-extension.zip -d /srv/wordpress/wp-content/plugins/

# 10. Fix permissions
sudo chown -R 33:tape /srv/wordpress/wp-content

# 11. Download wp-cli
echo "Downloading wp-cli..."
until curl -o /tmp/wp-cli.phar https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar; do
    echo "Retrying wp-cli download..."
    sleep 5
done

# 12. Run WordPress Container
docker run -d \
  --name wordpress \
  -p 80:80 \
  -v /srv/wordpress/wp-content:/var/www/html/wp-content \
  -e WORDPRESS_DB_HOST=$DB_HOST \
  -e WORDPRESS_DB_USER=$DB_USER \
  -e WORDPRESS_DB_PASSWORD=$DB_PASS \
  -e WORDPRESS_DB_NAME=$DB_NAME \
  -e WORDPRESS_DEBUG=1 \
  -e WORDPRESS_DEBUG_LOG=/var/www/html/wp-content/debug.log \
  -e WORDPRESS_DEBUG_DISPLAY=false \
  -e WORDPRESS_MEMORY_LIMIT=512M \
  --restart always \
  wordpress:php8.2

# 13. Copy wp-cli
echo "Waiting for container..."
sleep 10
docker cp /tmp/wp-cli.phar wordpress:/usr/local/bin/wp
docker exec wordpress chmod +x /usr/local/bin/wp

# Wait for Web Server
until curl -s -f http://127.0.0.1/license.txt > /dev/null; do
    echo "Waiting for WordPress..."
    sleep 5
done

# 14. Install WordPress
echo "Installing WordPress..."
docker exec --user www-data wordpress /usr/local/bin/wp core install \
  --url="http://${lb_dns_name}" \
  --title="Temp Install" \
  --admin_user="$WP_ADMIN_USER" \
  --admin_password="$WP_ADMIN_PASS" \
  --admin_email="$WP_ADMIN_EMAIL"

# 15. Activate Plugins
docker exec --user www-data wordpress /usr/local/bin/wp plugin activate all-in-one-wp-migration
docker exec --user www-data wordpress /usr/local/bin/wp plugin activate all-in-one-wp-migration-unlimited-extension

# 16. Run Import
echo "Downloading backup..."
aws s3 cp s3://saicharan-wp-backup-storage-121125/dev-at-oneconsciousness-org-20251110-223952-8jwj2b7z9leq.wpress /var/tmp/backup.wpress
echo "Creating directory..."
docker exec wordpress mkdir -p /var/www/html/wp-content/ai1wm-backups
docker exec wordpress chown www-data:www-data /var/www/html/wp-content/ai1wm-backups
echo "Copying backup..."
docker cp /var/tmp/backup.wpress wordpress:/var/www/html/wp-content/ai1wm-backups/backup.wpress
echo "Restoring..."
docker exec wordpress /usr/local/bin/wp ai1wm restore backup.wpress --allow-root --yes

# 17. Post-Migration Fixes
echo "Applying fixes..."
# Memory
docker exec wordpress bash -c "echo 'memory_limit = 512M' > /usr/local/etc/php/conf.d/zz-my-memory-limit.ini"
docker restart wordpress
sleep 10
# Notices
docker exec --user www-data wordpress /usr/local/bin/wp config set WP_DEBUG_DISPLAY false --raw
# URLs
docker exec --user www-data wordpress /usr/local/bin/wp search-replace 'dev-at.oneconsciousness.org' "${lb_dns_name}" --all-tables
# Permissions
docker exec --user root wordpress chown -R www-data:www-data /var/www/html/wp-content
# CSS
docker exec --user www-data wordpress /usr/local/bin/wp elementor flush_css
docker exec --user www-data wordpress /usr/local/bin/wp cache flush


# -----------------------------------------------------
# SECTION B: EASY BACKEND SETUP
# -----------------------------------------------------
echo "Starting EASY Backend Setup..."

# 1. Setup SSH for Bitbucket
mkdir -p ~/.ssh
# --- FIX: DECODE BASE64 KEY ---
echo "$BITBUCKET_SSH_KEY" | base64 -di > ~/.ssh/id_ed25519
# ------------------------------
chmod 600 ~/.ssh/id_ed25519
ssh-keyscan bitbucket.org >> ~/.ssh/known_hosts

# 2. Clone the Repository
echo "Cloning EASY repo..."
# We clone into a temporary folder
rm -rf /srv/easy-repo
git clone git@bitbucket.org:im-dev/easy.git /srv/easy-repo

# 3. Prepare the App Directory
# We need a folder structure that matches the URL /easy/public
# So we create /srv/easy-app/easy and move the code there
mkdir -p /srv/easy-app/easy
cp -r /srv/easy-repo/* /srv/easy-app/easy/
# Set permissions (33 is www-data)
sudo chown -R 33:33 /srv/easy-app

# 4. Create the Database
echo "Creating 'easy' database..."
# We use the mysql client on the host to connect to RDS and create the DB
mysql -h $DB_HOST -u $DB_USER -p"$DB_PASS" -e "CREATE DATABASE IF NOT EXISTS easy;"

# 5. Configure the App (Inject Credentials)
echo "Configuring settings.yml..."
SETTINGS_FILE="/srv/easy-app/easy/app/config/settings.yml"

# Use sed to replace the placeholder values with real RDS credentials
sed -i "s/db_host:.*/db_host: $DB_HOST/" $SETTINGS_FILE
sed -i "s/db_name:.*/db_name: easy/" $SETTINGS_FILE
sed -i "s/db_user:.*/db_user: $DB_USER/" $SETTINGS_FILE
# Escape the password for sed (passwords can have special chars)
ESCAPED_PASS=$(printf '%s\n' "$DB_PASS" | sed -e 's/[\/&]/\\&/g')
sed -i "s/db_pass:.*/db_pass: $ESCAPED_PASS/" $SETTINGS_FILE

# 6. Run the EASY Container
echo "Launching EASY container on Port 8080..."
docker run -d \
  --name easy-app \
  -p 8080:80 \
  -v /srv/easy-app:/var/www/html \
  --restart always \
  php:8.0-apache

# 7. Install App Dependencies (Composer)
echo "Installing Composer dependencies..."
# We install composer inside the container and run install
docker exec easy-app apt-get update
docker exec easy-app apt-get install -y git zip unzip
docker exec easy-app curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
# Run composer install in the /easy folder
docker exec -w /var/www/html/easy easy-app composer install --no-dev --optimize-autoloader

echo "EASY Backend Setup Complete!"
echo "Setup 100% complete! Site is restored and fixed."
