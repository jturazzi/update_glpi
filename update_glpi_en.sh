#!/bin/bash

# Stop the script in case of critical error
set -e

echo "=================================================="
echo "  Automatic Backup and Update to GLPI "
echo "=================================================="

# ==========================================
# 1. Basic Variables
# ==========================================
GLPI_DIR="/var/www/glpi"
BACKUP_DIR="/var/backups/glpi"
DATE=$(date +%Y%m%d_%H%M%S)
WEB_USER="www-data"

echo "[1/8] Preparing the environment..."
mkdir -p "$BACKUP_DIR"

# ==========================================
# 2. Retrieving DB Credentials
# ==========================================
CONFIG_FILE="$GLPI_DIR/config/config_db.php"

echo "[2/8] Reading credentials from $CONFIG_FILE..."
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: The configuration file $CONFIG_FILE cannot be found."
    exit 1
fi

DB_HOST=$(grep -E 'public \$dbhost|var \$dbhost' "$CONFIG_FILE" | sed -E "s/.*\\\$dbhost[[:space:]]*=[[:space:]]*['\"](.*)['\"];.*/\1/" | tr -d '\r\n')
DB_USER=$(grep -E 'public \$dbuser|var \$dbuser' "$CONFIG_FILE" | sed -E "s/.*\\\$dbuser[[:space:]]*=[[:space:]]*['\"](.*)['\"];.*/\1/" | tr -d '\r\n')
DB_PASS=$(grep -E 'public \$dbpassword|var \$dbpassword' "$CONFIG_FILE" | sed -E "s/.*\\\$dbpassword[[:space:]]*=[[:space:]]*['\"](.*)['\"];.*/\1/" | tr -d '\r\n')
DB_NAME=$(grep -E 'public \$dbdefault|var \$dbdefault' "$CONFIG_FILE" | sed -E "s/.*\\\$dbdefault[[:space:]]*=[[:space:]]*['\"](.*)['\"];.*/\1/" | tr -d '\r\n')

if [ -z "$DB_USER" ] || [ -z "$DB_NAME" ] || [ -z "$DB_PASS" ]; then
    echo "Error: Unable to properly retrieve database credentials."
    exit 1
fi

echo " -> Success: Database '$DB_NAME', Host '$DB_HOST'."

# ==========================================
# 3. Retrieving the latest GLPI version
# ==========================================
echo "[3/8] Searching for the latest GLPI version on GitHub..."
GLPI_URL=$(curl -s https://api.github.com/repos/glpi-project/glpi/releases/latest | grep browser_download_url | grep -i "\.tgz" | cut -d '"' -f 4)

if [ -z "$GLPI_URL" ]; then
    echo "Error: Could not find the download link."
    exit 1
fi
echo " -> Update URL found: $GLPI_URL"

# ==========================================
# 4. Database backup
# ==========================================
echo "[4/8] Backing up the database..."
MYSQL_PWD="$DB_PASS" mysqldump -h "$DB_HOST" -u "$DB_USER" "$DB_NAME" > "$BACKUP_DIR/glpi_db_$DATE.sql"
echo " -> Database backed up in $BACKUP_DIR/glpi_db_$DATE.sql"

# ==========================================
# 5. Backing up current files
# ==========================================
echo "[5/8] Backing up current GLPI files..."
tar -czf "$BACKUP_DIR/glpi_files_$DATE.tar.gz" -C $(dirname "$GLPI_DIR") $(basename "$GLPI_DIR")
echo " -> Files backed up in $BACKUP_DIR/glpi_files_$DATE.tar.gz"

# ==========================================
# 6. Download and extraction
# ==========================================
echo "[6/8] Downloading and extracting the new version..."
wget -q -O /tmp/glpi-latest.tgz "$GLPI_URL"

mv "$GLPI_DIR" "${GLPI_DIR}_old_${DATE}"
tar -xzf /tmp/glpi-latest.tgz -C $(dirname "$GLPI_DIR")
rm /tmp/glpi-latest.tgz

# ==========================================
# 7. Copying persistent data & Permissions
# ==========================================
echo "[7/8] Restoring configuration, files, and plugins..."
cp -a "${GLPI_DIR}_old_${DATE}/config/." "$GLPI_DIR/config/"
cp -a "${GLPI_DIR}_old_${DATE}/files/." "$GLPI_DIR/files/"

if [ -d "${GLPI_DIR}_old_${DATE}/plugins" ]; then
    cp -a "${GLPI_DIR}_old_${DATE}/plugins/." "$GLPI_DIR/plugins/"
fi
if [ -d "${GLPI_DIR}_old_${DATE}/marketplace" ]; then
    cp -a "${GLPI_DIR}_old_${DATE}/marketplace/." "$GLPI_DIR/marketplace/"
fi

chown -R "$WEB_USER":"$WEB_USER" "$GLPI_DIR"
find "$GLPI_DIR" -type d -exec chmod 755 {} \;
find "$GLPI_DIR" -type f -exec chmod 644 {} \;

# ==========================================
# 8. Database update
# ==========================================
echo "[8/8] Updating GLPI database via console..."
cd "$GLPI_DIR"
sudo -u "$WEB_USER" php bin/console db:update --no-interaction

echo "=================================================="
echo "  Update completed successfully! "
echo "  Old version folder: ${GLPI_DIR}_old_${DATE} "
echo "=================================================="