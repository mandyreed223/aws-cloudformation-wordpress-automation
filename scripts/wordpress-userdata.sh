#!/bin/bash
set -euo pipefail
umask 077
export AWS_DEFAULT_REGION='${AWS::Region}'
export DB_HOST='${WordPressDatabase.Endpoint.Address}'
export DB_NAME='wordpress'
export DB_SECRET_ARN='${WordPressDatabase.MasterUserSecret.SecretArn}'

# Install packages needed to serve WordPress and mount EFS.
dnf install -y httpd php php-mysqlnd php-fpm php-mbstring php-xml php-gd php-intl php-zip \
mariadb105 amazon-efs-utils awscli jq python3 util-linux
systemctl enable httpd php-fpm
mkdir -p /var/www/html

# Wait for EFS mount target/DNS propagation; never install on local disk.
for attempt in $(seq 1 30); do
  if mount -t efs -o tls '${WordPressEFS}:/' /var/www/html; then
    break
  fi
  echo "EFS mount pending, attempt $attempt/30"
  sleep 10
done
mountpoint -q /var/www/html || { echo 'EFS mount failed'; exit 1; }
echo '${WordPressEFS}:/ /var/www/html efs _netdev,tls 0 0' >> /etc/fstab

# Fetch secret without echoing it or passing password on command line.
DB_SECRET=$(aws secretsmanager get-secret-value \
  --secret-id "$DB_SECRET_ARN" --query SecretString --output text)
export DB_USER DB_PASSWORD
DB_USER=$(printf '%s' "$DB_SECRET" | jq -er '.username')
DB_PASSWORD=$(printf '%s' "$DB_SECRET" | jq -er '.password')
unset DB_SECRET

# Wait for the database to accept connections.
DB_READY=false
for attempt in $(seq 1 30); do
  if MYSQL_PWD="$DB_PASSWORD" mariadb --host="$DB_HOST" --user="$DB_USER" \
      --ssl --database="$DB_NAME" --execute='SELECT 1;' >/dev/null 2>&1; then
    DB_READY=true
    break
  fi
  echo "RDS not ready, attempt $attempt/30"
  sleep 10
done
[ "$DB_READY" = true ] || { echo 'RDS connection failed'; exit 1; }

# Shared NFSv4 lock prevents two instances from initializing together.
exec 9>/var/www/html/.wordpress-install.lock
flock -x 9
if [ ! -f /var/www/html/.wordpress-ready ]; then
  echo 'Initializing shared WordPress installation'
  mkdir -p /tmp/wordpress-download
  curl --fail --silent --show-error --location --retry 3 \
    https://wordpress.org/latest.tar.gz -o /tmp/wordpress.tar.gz
  tar -xzf /tmp/wordpress.tar.gz -C /tmp/wordpress-download
  cp -a /tmp/wordpress-download/wordpress/. /var/www/html/

  # Generate salts into a temporary file, then use them in wp-config.
  curl --fail --silent --show-error --location --retry 3 \
    https://api.wordpress.org/secret-key/1.1/salt/ \
    -o /root/.wordpress-salts.tmp
  mv -f /root/.wordpress-salts.tmp /root/.wordpress-salts

  # Python safely escapes PHP single-quoted values and writes atomically.
  python3 - <<'PY'
import os
import re
from pathlib import Path

root = Path('/var/www/html')
sample = (root / 'wp-config-sample.php').read_text()
def php_quote(value):
    return "'" + value.replace('\\', '\\\\').replace("'", "\\'") + "'"
replacements = {
    'DB_NAME': os.environ['DB_NAME'],
    'DB_USER': os.environ['DB_USER'],
    'DB_PASSWORD': os.environ['DB_PASSWORD'],
    'DB_HOST': os.environ['DB_HOST'],
}
for key, value in replacements.items():
    pattern = r"define\(\s*'" + key + r"'\s*,\s*'[^']*'\s*\);"
    new_line = "define( '" + key + "', " + php_quote(value) + " );"
    sample, count = re.subn(pattern, lambda _: new_line, sample, count=1)
    if count != 1:
        raise RuntimeError('Missing WordPress config setting: ' + key)
salts = Path('/root/.wordpress-salts').read_text()
sample, count = re.subn(
    r"(?m)^define\(\s*'AUTH_KEY'.*?^define\(\s*'NONCE_SALT'[^\n]*\n",
    lambda _: salts.rstrip() + '\n', sample, count=1, flags=re.S | re.M)
if count != 1:
    raise RuntimeError('Could not replace WordPress auth salts')
# Configure HTTPS detection before WordPress bootstrap executes.
forwarded = "if (isset($_SERVER['HTTP_X_FORWARDED_PROTO']) && $_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https') { $_SERVER['HTTPS'] = 'on'; }\n"
sample = sample.replace("<?php", "<?php\n" + forwarded, 1)
        # Require TLS for WordPress database connections.
db_tls = (
    "define('MYSQL_CLIENT_FLAGS', MYSQLI_CLIENT_SSL);\n"
)
marker = "/* That's all, stop editing!"

if marker not in sample:
    raise RuntimeError('WordPress configuration marker not found')

sample = sample.replace(marker, db_tls + "\n" + marker, 1)
config_tmp = root / '.wp-config.php.tmp'
config_tmp.write_text(sample)
os.chmod(config_tmp, 0o600)
config_tmp.replace(root / 'wp-config.php')
PY

  # Only mark ready after files and configuration are complete.
  chown -R apache:apache /var/www/html
  find /var/www/html -type d -exec chmod 755 {} +
  find /var/www/html -type f -exec chmod 644 {} +
  chmod 640 /var/www/html/wp-config.php
  rm -f /root/.wordpress-salts
  chmod 600 /var/www/html/.wordpress-install.lock
  touch /var/www/html/.wordpress-ready
fi
flock -u 9
exec 9>&-
unset DB_PASSWORD DB_USER

# Create an instance-specific health endpoint outside shared EFS storage.
mkdir -p /var/www/health
printf 'healthy\n' > /var/www/health/health.html
chmod 644 /var/www/health/health.html

# Apache serves /health.html from local EC2 storage, not EFS.
cat > /etc/httpd/conf.d/wordpress-health.conf <<'HEALTH'
Alias /health.html /var/www/health/health.html

<Directory "/var/www/health">
    Require all granted
</Directory>
HEALTH

# Block HTTP access to sensitive WordPress files.
cat > /etc/httpd/conf.d/wordpress-security.conf <<'SECURITY'
<Directory "/var/www/html">
    <FilesMatch "^(wp-config\.php(\..*)?|\.wp-config\.php(\..*)?|\.wordpress-.*)$">
        Require all denied
    </FilesMatch>
</Directory>
SECURITY

# Start services only after initialization succeeds.
systemctl start php-fpm
systemctl restart httpd

echo 'WordPress initialization completed'
