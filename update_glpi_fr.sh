#!/bin/bash

# Arrêter le script en cas d'erreur critique
set -e

usage() {
    echo "Usage : $0 [-v|--version VERSION] [-l|--list] [-h|--help]"
    echo "  -v, --version VERSION  Version à installer : exacte (11.0.12) ou série (11 ou 11.0 = dernière 11.x)"
    echo "  -l, --list             Affiche les versions stables disponibles et quitte"
    echo "  -h, --help             Affiche cette aide"
    echo "Sans option : menu interactif en terminal, sinon dernière version stable."
}

TARGET_VERSION=""
LIST_ONLY=0
while [ $# -gt 0 ]; do
    case "$1" in
        -v|--version)
            if [ -z "${2:-}" ]; then echo "Erreur : $1 nécessite une valeur."; usage; exit 1; fi
            TARGET_VERSION="$2"; shift 2 ;;
        -l|--list) LIST_ONLY=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Option inconnue : $1"; usage; exit 1 ;;
    esac
done

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
echo "[3/9] Recherche des versions de GLPI sur GitHub..."
RELEASES_JSON=$(curl -s "https://api.github.com/repos/glpi-project/glpi/releases?per_page=100")
# Versions stables uniquement (X.Y.Z), de la plus récente à la plus ancienne
AVAILABLE_VERSIONS=$(echo "$RELEASES_JSON" | grep '"tag_name"' | cut -d '"' -f 4 | sed 's/^v//' \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -Vu | sort -Vr || true)

if [ -z "$AVAILABLE_VERSIONS" ]; then
    echo "Erreur : Impossible de récupérer la liste des versions GLPI."
    exit 1
fi

if [ "$LIST_ONLY" = "1" ]; then
    echo "Versions stables disponibles :"
    echo "$AVAILABLE_VERSIONS" | sed 's/^/  /'
    exit 0
fi

# Menu interactif (terminal uniquement) si aucune version n'est imposée
if [ -z "$TARGET_VERSION" ] && [ -t 0 ] && [ -t 1 ]; then
    SERIES=$(echo "$AVAILABLE_VERSIONS" | awk -F. '!seen[$1"."$2]++' | head -6)
    echo "Dernière version de chaque série disponible :"
    i=1
    while read -r v; do
        echo "  $i) $v"
        i=$((i + 1))
    done <<< "$SERIES"
    read -r -p "Choix (numéro, ou Entrée pour la plus récente) : " CHOICE
    if [ -n "$CHOICE" ]; then
        TARGET_VERSION=$(echo "$SERIES" | sed -n "${CHOICE}p" 2>/dev/null)
        if [ -z "$TARGET_VERSION" ]; then
            echo "Erreur : choix invalide."
            exit 1
        fi
    fi
fi

if [ -z "$TARGET_VERSION" ]; then
    LATEST_VERSION_CLEAN=$(echo "$AVAILABLE_VERSIONS" | head -1)
else
    TARGET_VERSION="${TARGET_VERSION#v}"
    # Correspondance exacte (11.0.12) ou par série (11, 11.0) : la plus récente est retenue
    LATEST_VERSION_CLEAN=$(echo "$AVAILABLE_VERSIONS" | grep -E "^${TARGET_VERSION//./\\.}(\.|$)" | head -1 || true)
    if [ -z "$LATEST_VERSION_CLEAN" ]; then
        echo "Erreur : aucune version stable ne correspond à '$TARGET_VERSION' (voir --list)."
        exit 1
    fi
fi

GLPI_URL="https://github.com/glpi-project/glpi/releases/download/${LATEST_VERSION_CLEAN}/glpi-${LATEST_VERSION_CLEAN}.tgz"
if ! curl -sIL -f -o /dev/null "$GLPI_URL"; then
    echo "Erreur : archive de téléchargement introuvable : $GLPI_URL"
    exit 1
fi
echo " -> URL de mise à jour trouvée : $GLPI_URL"

# Vérification de la version actuellement installée (depuis la base de données)
CURRENT_VERSION=$(MYSQL_PWD="$DB_PASS" mysql -h "$DB_HOST" -u "$DB_USER" -s -N -e \
    "SELECT value FROM glpi_configs WHERE name = 'version' LIMIT 1;" "$DB_NAME" 2>/dev/null | tr -d '[:space:]')

# ==========================================
# 4. Activation du mode maintenance (connexion BDD confirmée)
# ==========================================
# Activation du mode maintenance dès que la connexion BDD est confirmée
echo "[4/9] Activation du mode maintenance..."
cd "$GLPI_DIR"
sudo -u "$WEB_USER" php bin/console glpi:maintenance:enable --no-interaction 2>/dev/null \
    && echo " -> Mode maintenance activé." \
    || echo " -> Avertissement : Impossible d'activer le mode maintenance (on continue quand même)."

echo " -> Version actuellement installée : ${CURRENT_VERSION:-inconnue}"
echo " -> Version cible                  : $LATEST_VERSION_CLEAN"

# Refus du retour arrière (une base migrée ne peut pas être rétrogradée)
if [ -n "$CURRENT_VERSION" ] && [ "$CURRENT_VERSION" != "$LATEST_VERSION_CLEAN" ] \
    && [ "$(printf '%s\n%s\n' "$CURRENT_VERSION" "$LATEST_VERSION_CLEAN" | sort -V | head -1)" != "$CURRENT_VERSION" ]; then
    echo "Erreur : la version demandée ($LATEST_VERSION_CLEAN) est inférieure à la version installée ($CURRENT_VERSION)."
    sudo -u "$WEB_USER" php bin/console glpi:maintenance:disable --no-interaction 2>/dev/null || true
    exit 1
fi

if [ -n "$CURRENT_VERSION" ] && [ "$CURRENT_VERSION" = "$LATEST_VERSION_CLEAN" ]; then
    echo "GLPI est déjà à jour (version $CURRENT_VERSION). Aucune mise à jour nécessaire."
    sudo -u "$WEB_USER" php bin/console glpi:maintenance:disable --no-interaction 2>/dev/null \
        && echo " -> Mode maintenance désactivé." \
        || echo " -> Avertissement : Impossible de désactiver le mode maintenance. Veuillez le désactiver manuellement."
    exit 0
fi

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
echo "  Version précédente : ${CURRENT_VERSION:-inconnue} -> Nouvelle version : $LATEST_VERSION_CLEAN"
echo "  Dossier de l'ancienne version : ${GLPI_DIR}_old_${DATE}"
echo "=================================================="