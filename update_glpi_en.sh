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

echo "[1/9] Preparing the environment..."
mkdir -p "$BACKUP_DIR"

# ==========================================
# 2. Retrieving DB Credentials
# ==========================================
CONFIG_FILE="$GLPI_DIR/config/config_db.php"

echo "[2/9] Reading credentials from $CONFIG_FILE..."
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
# 3. Retrieving the latest GLPI version + version check
# ==========================================
echo "[3/9] Searching for the latest GLPI version on GitHub..."
API_RESPONSE=$(curl -s https://api.github.com/repos/glpi-project/glpi/releases/latest)
GLPI_URL=$(echo "$API_RESPONSE" | grep browser_download_url | grep -i "\.tgz" | cut -d '"' -f 4)
LATEST_VERSION=$(echo "$API_RESPONSE" | grep '"tag_name"' | cut -d '"' -f 4)

if [ -z "$GLPI_URL" ] || [ -z "$LATEST_VERSION" ]; then
    echo "Error: Could not find the download link or latest version."
    exit 1
fi
echo " -> Latest version available: $LATEST_VERSION"
echo " -> Update URL found: $GLPI_URL"

# Normalize the GitHub version tag (strip leading 'v' if present)
LATEST_VERSION_CLEAN=$(echo "$LATEST_VERSION" | sed 's/^v//')

# Check current installed version
# Method 1: via the GLPI PHP console (most reliable)
CURRENT_VERSION=""
if [ -f "$GLPI_DIR/bin/console" ]; then
    CURRENT_VERSION=$(sudo -u "$WEB_USER" php "$GLPI_DIR/bin/console" glpi:version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
fi
# Method 2: from the PHP definition file
if [ -z "$CURRENT_VERSION" ] && [ -f "$GLPI_DIR/inc/define.php" ]; then
    CURRENT_VERSION=$(grep "define.*GLPI_VERSION" "$GLPI_DIR/inc/define.php" | grep -oE "'[0-9]+\.[0-9]+\.[0-9]+'" | tr -d "'")
fi
# Method 3: from the version file (if it exists)
if [ -z "$CURRENT_VERSION" ] && [ -f "$GLPI_DIR/version" ]; then
    CURRENT_VERSION=$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' "$GLPI_DIR/version" | head -1)
fi

echo " -> Current installed version: ${CURRENT_VERSION:-unknown}"
echo " -> Latest version available : $LATEST_VERSION_CLEAN"

if [ -n "$CURRENT_VERSION" ] && [ "$CURRENT_VERSION" = "$LATEST_VERSION_CLEAN" ]; then
    echo "GLPI is already up to date (version $CURRENT_VERSION). No update needed."
    exit 0
fi

# ==========================================
# 4. Enabling maintenance mode
# ==========================================
echo "[4/9] Enabling maintenance mode..."
cd "$GLPI_DIR"
sudo -u "$WEB_USER" php bin/console glpi:maintenance:enable --no-interaction 2>/dev/null \
    && echo " -> Maintenance mode enabled." \
    || echo " -> Warning: Could not enable maintenance mode (continuing anyway)."

# ==========================================
# 5. Database backup
# ==========================================
echo "[5/9] Backing up the database..."
MYSQL_PWD="$DB_PASS" mysqldump -h "$DB_HOST" -u "$DB_USER" "$DB_NAME" > "$BACKUP_DIR/glpi_db_$DATE.sql"
echo " -> Database backed up in $BACKUP_DIR/glpi_db_$DATE.sql"

# ==========================================
# 6. Backing up current files
# ==========================================
echo "[6/9] Backing up current GLPI files..."
tar -czf "$BACKUP_DIR/glpi_files_$DATE.tar.gz" -C $(dirname "$GLPI_DIR") $(basename "$GLPI_DIR")
echo " -> Files backed up in $BACKUP_DIR/glpi_files_$DATE.tar.gz"

# ==========================================
# 7. Download and extraction
# ==========================================
echo "[7/9] Downloading and extracting the new version..."
wget -q -O /tmp/glpi-latest.tgz "$GLPI_URL"

mv "$GLPI_DIR" "${GLPI_DIR}_old_${DATE}"
tar -xzf /tmp/glpi-latest.tgz -C $(dirname "$GLPI_DIR")
rm /tmp/glpi-latest.tgz

# ==========================================
# 8. Copying persistent data & Permissions
# ==========================================
echo "[8/9] Restoring configuration, files, and plugins..."
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
# 9. Database update
# ==========================================
echo "[9/9] Updating GLPI database via console..."
cd "$GLPI_DIR"
sudo -u "$WEB_USER" php bin/console db:update --no-interaction

# Disable maintenance mode after successful update
echo " -> Disabling maintenance mode..."
sudo -u "$WEB_USER" php bin/console glpi:maintenance:disable --no-interaction 2>/dev/null \
    && echo " -> Maintenance mode disabled." \
    || echo " -> Warning: Could not disable maintenance mode. Please disable it manually."

echo "=================================================="
echo "  Update completed successfully! "
echo "  Previous version: ${CURRENT_VERSION:-unknown} -> New version: $LATEST_VERSION_CLEAN"
echo "  Old version folder: ${GLPI_DIR}_old_${DATE} "
echo "=================================================="