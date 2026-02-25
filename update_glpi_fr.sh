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

echo "[1/9] Préparation de l'environnement..."
mkdir -p "$BACKUP_DIR"

# ==========================================
# 2. Récupération des identifiants BDD
# ==========================================
CONFIG_FILE="$GLPI_DIR/config/config_db.php"

echo "[2/9] Lecture des identifiants depuis $CONFIG_FILE..."
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
# 3. Récupération de la dernière version GLPI + vérification de version
# ==========================================
echo "[3/9] Recherche de la dernière version de GLPI sur GitHub..."
API_RESPONSE=$(curl -s https://api.github.com/repos/glpi-project/glpi/releases/latest)
GLPI_URL=$(echo "$API_RESPONSE" | grep browser_download_url | grep -i "\.tgz" | cut -d '"' -f 4)
LATEST_VERSION=$(echo "$API_RESPONSE" | grep '"tag_name"' | cut -d '"' -f 4)

if [ -z "$GLPI_URL" ] || [ -z "$LATEST_VERSION" ]; then
    echo "Erreur : Impossible de trouver le lien de téléchargement ou la dernière version."
    exit 1
fi
echo " -> Dernière version disponible : $LATEST_VERSION"
echo " -> URL de mise à jour trouvée : $GLPI_URL"

# Vérification de la version actuellement installée
CURRENT_VERSION=""
if [ -f "$GLPI_DIR/version" ]; then
    CURRENT_VERSION=$(cat "$GLPI_DIR/version" | tr -d '[:space:]')
fi
if [ -z "$CURRENT_VERSION" ] && [ -f "$GLPI_DIR/inc/define.php" ]; then
    CURRENT_VERSION=$(grep "define.*GLPI_VERSION" "$GLPI_DIR/inc/define.php" | sed -E "s/.*'(.*)'.*/\1/" | tr -d '[:space:]')
fi

echo " -> Version actuellement installée : ${CURRENT_VERSION:-inconnue}"

if [ -n "$CURRENT_VERSION" ] && [ "$CURRENT_VERSION" = "$LATEST_VERSION" ]; then
    echo "GLPI est déjà à jour (version $CURRENT_VERSION). Aucune mise à jour nécessaire."
    exit 0
fi

# ==========================================
# 4. Activation du mode maintenance
# ==========================================
echo "[4/9] Activation du mode maintenance..."
cd "$GLPI_DIR"
sudo -u "$WEB_USER" php bin/console glpi:maintenance:enable --no-interaction 2>/dev/null \
    && echo " -> Mode maintenance activé." \
    || echo " -> Avertissement : Impossible d'activer le mode maintenance (on continue quand même)."

# ==========================================
# 5. Sauvegarde de la base de données
# ==========================================
echo "[5/9] Sauvegarde de la base de données..."
MYSQL_PWD="$DB_PASS" mysqldump -h "$DB_HOST" -u "$DB_USER" "$DB_NAME" > "$BACKUP_DIR/glpi_db_$DATE.sql"
echo " -> Base sauvegardée dans $BACKUP_DIR/glpi_db_$DATE.sql"

# ==========================================
# 6. Sauvegarde des fichiers actuels
# ==========================================
echo "[6/9] Sauvegarde des fichiers GLPI actuels..."
tar -czf "$BACKUP_DIR/glpi_files_$DATE.tar.gz" -C $(dirname "$GLPI_DIR") $(basename "$GLPI_DIR")
echo " -> Fichiers sauvegardés dans $BACKUP_DIR/glpi_files_$DATE.tar.gz"

# ==========================================
# 7. Téléchargement et extraction
# ==========================================
echo "[7/9] Téléchargement et extraction de la nouvelle version..."
wget -q -O /tmp/glpi-latest.tgz "$GLPI_URL"

mv "$GLPI_DIR" "${GLPI_DIR}_old_${DATE}"
tar -xzf /tmp/glpi-latest.tgz -C $(dirname "$GLPI_DIR")
rm /tmp/glpi-latest.tgz

# ==========================================
# 8. Copie des données persistantes & Droits
# ==========================================
echo "[8/9] Restauration de la configuration, des fichiers et des plugins..."
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
# 9. Mise à jour de la base de données
# ==========================================
echo "[9/9] Mise à jour de la base de données GLPI via la console..."
cd "$GLPI_DIR"
sudo -u "$WEB_USER" php bin/console db:update --no-interaction

# Désactivation du mode maintenance après la mise à jour réussie
echo " -> Désactivation du mode maintenance..."
sudo -u "$WEB_USER" php bin/console glpi:maintenance:disable --no-interaction 2>/dev/null \
    && echo " -> Mode maintenance désactivé." \
    || echo " -> Avertissement : Impossible de désactiver le mode maintenance. Veuillez le désactiver manuellement."

echo "=================================================="
echo "  Mise à jour terminée avec succès ! "
echo "  Version précédente : ${CURRENT_VERSION:-inconnue} -> Nouvelle version : $LATEST_VERSION"
echo "  Dossier de l'ancienne version : ${GLPI_DIR}_old_${DATE}"
echo "=================================================="