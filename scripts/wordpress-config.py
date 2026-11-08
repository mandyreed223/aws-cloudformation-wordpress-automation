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