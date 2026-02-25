#!/bin/bash

# Arrêter le script en cas d'erreur critique
set -e

echo "=================================================="
echo "  Sauvegarde et MAJ Automatique vers GLPI "
echo "=================================================="

# ==========================================
# 1. Variables de base
# ==========================================
GLPI_DIR="/var/www/glpi"
BACKUP_DIR="/var/backups/glpi"
DATE=$(date +%Y%m%d_%H%M%S)
WEB_USER="www-data"

echo "[1/8] Préparation de l'environnement..."
mkdir -p "$BACKUP_DIR"

# ==========================================
# 2. Récupération des identifiants BDD
# ==========================================
CONFIG_FILE="$GLPI_DIR/config/config_db.php"

echo "[2/8] Lecture des identifiants depuis $CONFIG_FILE..."
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Erreur : Le fichier de configuration $CONFIG_FILE est introuvable."
    exit 1
fi

DB_HOST=$(grep -E 'public \$dbhost|var \$dbhost' "$CONFIG_FILE" | sed -E "s/.*\\\$dbhost[[:space:]]*=[[:space:]]*['\"](.*)['\"];.*/\1/" | tr -d '\r\n')
DB_USER=$(grep -E 'public \$dbuser|var \$dbuser' "$CONFIG_FILE" | sed -E "s/.*\\\$dbuser[[:space:]]*=[[:space:]]*['\"](.*)['\"];.*/\1/" | tr -d '\r\n')
DB_PASS=$(grep -E 'public \$dbpassword|var \$dbpassword' "$CONFIG_FILE" | sed -E "s/.*\\\$dbpassword[[:space:]]*=[[:space:]]*['\"](.*)['\"];.*/\1/" | tr -d '\r\n')
DB_NAME=$(grep -E 'public \$dbdefault|var \$dbdefault' "$CONFIG_FILE" | sed -E "s/.*\\\$dbdefault[[:space:]]*=[[:space:]]*['\"](.*)['\"];.*/\1/" | tr -d '\r\n')

if [ -z "$DB_USER" ] || [ -z "$DB_NAME" ] || [ -z "$DB_PASS" ]; then
    echo "Erreur : Impossible de récupérer correctement les identifiants de la base de données."
    exit 1
fi

echo " -> Succès : Base '$DB_NAME', Hôte '$DB_HOST'."

# ==========================================
# 3. Récupération de la dernière version GLPI
# ==========================================
echo "[3/8] Recherche de la dernière version de GLPI sur GitHub..."
GLPI_URL=$(curl -s https://api.github.com/repos/glpi-project/glpi/releases/latest | grep browser_download_url | grep -i "\.tgz" | cut -d '"' -f 4)

if [ -z "$GLPI_URL" ]; then
    echo "Erreur : Impossible de trouver le lien de téléchargement."
    exit 1
fi
echo " -> URL de mise à jour trouvée : $GLPI_URL"

# ==========================================
# 4. Sauvegarde de la base de données
# ==========================================
echo "[4/8] Sauvegarde de la base de données..."
MYSQL_PWD="$DB_PASS" mysqldump -h "$DB_HOST" -u "$DB_USER" "$DB_NAME" > "$BACKUP_DIR/glpi_db_$DATE.sql"
echo " -> Base sauvegardée dans $BACKUP_DIR/glpi_db_$DATE.sql"

# ==========================================
# 5. Sauvegarde des fichiers actuels
# ==========================================
echo "[5/8] Sauvegarde des fichiers GLPI actuels..."
tar -czf "$BACKUP_DIR/glpi_files_$DATE.tar.gz" -C $(dirname "$GLPI_DIR") $(basename "$GLPI_DIR")
echo " -> Fichiers sauvegardés dans $BACKUP_DIR/glpi_files_$DATE.tar.gz"

# ==========================================
# 6. Téléchargement et extraction
# ==========================================
echo "[6/8] Téléchargement et extraction de la nouvelle version..."
wget -q -O /tmp/glpi-latest.tgz "$GLPI_URL"

mv "$GLPI_DIR" "${GLPI_DIR}_old_${DATE}"
tar -xzf /tmp/glpi-latest.tgz -C $(dirname "$GLPI_DIR")
rm /tmp/glpi-latest.tgz

# ==========================================
# 7. Copie des données persistantes & Droits
# ==========================================
echo "[7/8] Restauration de la configuration, des fichiers et des plugins..."
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
# 8. Mise à jour de la base de données
# ==========================================
echo "[8/8] Mise à jour de la base de données GLPI via la console..."
cd "$GLPI_DIR"
sudo -u "$WEB_USER" php bin/console db:update --no-interaction

echo "=================================================="
echo "  Mise à jour terminée avec succès ! "
echo "  Dossier de l'ancienne version : ${GLPI_DIR}_old_${DATE}"
echo "=================================================="