#!/bin/bash

# Stop the script in case of critical error
set -e

usage() {
    echo "Usage: $0 [-v|--version VERSION] [-l|--list] [-h|--help]"
    echo "  -v, --version VERSION  Version to install: exact (11.0.12) or series (11 or 11.0 = latest 11.x)"
    echo "  -l, --list             List available stable versions and exit"
    echo "  -h, --help             Show this help"
    echo "Without options: interactive menu in a terminal, otherwise latest stable version."
}

TARGET_VERSION=""
LIST_ONLY=0
while [ $# -gt 0 ]; do
    case "$1" in
        -v|--version)
            if [ -z "${2:-}" ]; then echo "Error: $1 requires a value."; usage; exit 1; fi
            TARGET_VERSION="$2"; shift 2 ;;
        -l|--list) LIST_ONLY=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1"; usage; exit 1 ;;
    esac
done

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
echo "[3/9] Searching for GLPI versions on GitHub..."
RELEASES_JSON=$(curl -s "https://api.github.com/repos/glpi-project/glpi/releases?per_page=100")
# Stable versions only (X.Y.Z), newest first
AVAILABLE_VERSIONS=$(echo "$RELEASES_JSON" | grep '"tag_name"' | cut -d '"' -f 4 | sed 's/^v//' \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -Vu | sort -Vr || true)

if [ -z "$AVAILABLE_VERSIONS" ]; then
    echo "Error: Could not retrieve the list of GLPI versions."
    exit 1
fi

if [ "$LIST_ONLY" = "1" ]; then
    echo "Available stable versions:"
    echo "$AVAILABLE_VERSIONS" | sed 's/^/  /'
    exit 0
fi

# Interactive menu (terminal only) when no version is forced
if [ -z "$TARGET_VERSION" ] && [ -t 0 ] && [ -t 1 ]; then
    SERIES=$(echo "$AVAILABLE_VERSIONS" | awk -F. '!seen[$1"."$2]++' | head -6)
    echo "Latest version of each available series:"
    i=1
    while read -r v; do
        echo "  $i) $v"
        i=$((i + 1))
    done <<< "$SERIES"
    read -r -p "Choice (number, or Enter for the newest): " CHOICE
    if [ -n "$CHOICE" ]; then
        TARGET_VERSION=$(echo "$SERIES" | sed -n "${CHOICE}p" 2>/dev/null)
        if [ -z "$TARGET_VERSION" ]; then
            echo "Error: invalid choice."
            exit 1
        fi
    fi
fi

if [ -z "$TARGET_VERSION" ]; then
    LATEST_VERSION_CLEAN=$(echo "$AVAILABLE_VERSIONS" | head -1)
else
    TARGET_VERSION="${TARGET_VERSION#v}"
    # Exact match (11.0.12) or series match (11, 11.0): the newest match is used
    LATEST_VERSION_CLEAN=$(echo "$AVAILABLE_VERSIONS" | grep -E "^${TARGET_VERSION//./\\.}(\.|$)" | head -1 || true)
    if [ -z "$LATEST_VERSION_CLEAN" ]; then
        echo "Error: no stable version matches '$TARGET_VERSION' (see --list)."
        exit 1
    fi
fi

GLPI_URL="https://github.com/glpi-project/glpi/releases/download/${LATEST_VERSION_CLEAN}/glpi-${LATEST_VERSION_CLEAN}.tgz"
if ! curl -sIL -f -o /dev/null "$GLPI_URL"; then
    echo "Error: download archive not found: $GLPI_URL"
    exit 1
fi
echo " -> Update URL found: $GLPI_URL"

# Check current installed version (from the database)
CURRENT_VERSION=$(MYSQL_PWD="$DB_PASS" mysql -h "$DB_HOST" -u "$DB_USER" -s -N -e \
    "SELECT value FROM glpi_configs WHERE name = 'version' LIMIT 1;" "$DB_NAME" 2>/dev/null | tr -d '[:space:]')

# ==========================================
# 4. Enabling maintenance mode (DB connection confirmed)
# ==========================================
# Enable maintenance mode as soon as the DB connection is confirmed
echo "[4/9] Enabling maintenance mode..."
cd "$GLPI_DIR"
sudo -u "$WEB_USER" php bin/console glpi:maintenance:enable --no-interaction 2>/dev/null \
    && echo " -> Maintenance mode enabled." \
    || echo " -> Warning: Could not enable maintenance mode (continuing anyway)."

echo " -> Current installed version: ${CURRENT_VERSION:-unknown}"
echo " -> Target version           : $LATEST_VERSION_CLEAN"

# Refuse downgrades (a migrated database cannot be rolled back)
if [ -n "$CURRENT_VERSION" ] && [ "$CURRENT_VERSION" != "$LATEST_VERSION_CLEAN" ] \
    && [ "$(printf '%s\n%s\n' "$CURRENT_VERSION" "$LATEST_VERSION_CLEAN" | sort -V | head -1)" != "$CURRENT_VERSION" ]; then
    echo "Error: requested version ($LATEST_VERSION_CLEAN) is older than the installed one ($CURRENT_VERSION)."
    sudo -u "$WEB_USER" php bin/console glpi:maintenance:disable --no-interaction 2>/dev/null || true
    exit 1
fi

if [ -n "$CURRENT_VERSION" ] && [ "$CURRENT_VERSION" = "$LATEST_VERSION_CLEAN" ]; then
    echo "GLPI is already up to date (version $CURRENT_VERSION). No update needed."
    sudo -u "$WEB_USER" php bin/console glpi:maintenance:disable --no-interaction 2>/dev/null \
        && echo " -> Maintenance mode disabled." \
        || echo " -> Warning: Could not disable maintenance mode. Please disable it manually."
    exit 0
fi

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