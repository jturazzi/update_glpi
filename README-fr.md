# Script de Sauvegarde et Mise à Jour Automatique de GLPI

Script Bash qui automatise la **sauvegarde** et la **mise à jour** d'une instance GLPI vers la dernière version disponible sur GitHub.

## Scripts disponibles

| Script | Langue |
|---|---|
| `update_glpi_en.sh` | Anglais |
| `update_glpi_fr.sh` | Français |

## Prérequis

Les outils suivants doivent être installés et disponibles dans le `$PATH` :

- `bash`
- `curl` — pour interroger l'API GitHub
- `wget` — pour télécharger l'archive GLPI
- `mysqldump` — pour sauvegarder la base de données
- `php` — pour exécuter la console de mise à jour de la base GLPI
- `tar` — pour archiver/extraire les fichiers
- `sudo` — pour exécuter des commandes en tant qu'utilisateur web

Le script doit être exécuté en **root** (ou via `sudo`) car il effectue des opérations `chown` et `chmod` sur les fichiers GLPI.

## Configuration

Modifiez les variables en haut du script avant de l'exécuter :

| Variable | Valeur par défaut | Description |
|---|---|---|
| `GLPI_DIR` | `/var/www/glpi` | Chemin vers l'installation GLPI |
| `BACKUP_DIR` | `/var/backups/glpi` | Répertoire de stockage des sauvegardes |
| `WEB_USER` | `www-data` | Utilisateur du serveur web (Apache/Nginx) |

Les identifiants de la base de données (hôte, utilisateur, mot de passe, nom de la base) sont lus automatiquement depuis le fichier de configuration GLPI : `$GLPI_DIR/config/config_db.php`.

## Utilisation

```bash
# Rendre le script exécutable (déjà fait si vous avez cloné ce dépôt)
chmod +x update_glpi_fr.sh

# Exécuter en root
sudo ./update_glpi_fr.sh
```

## Ce que fait le script

Le script s'exécute en **8 étapes** :

1. **Préparation de l'environnement** — crée le répertoire de sauvegarde s'il n'existe pas.
2. **Lecture des identifiants BDD** — extrait les informations de connexion depuis `config_db.php`.
3. **Récupération de la dernière version** — interroge l'API GitHub pour obtenir l'URL de téléchargement de la dernière version de GLPI.
4. **Sauvegarde de la base de données** — exporte la base dans `$BACKUP_DIR/glpi_db_<DATE>.sql` via `mysqldump`.
5. **Sauvegarde des fichiers** — archive l'intégralité du répertoire GLPI dans `$BACKUP_DIR/glpi_files_<DATE>.tar.gz`.
6. **Téléchargement & extraction** — télécharge la nouvelle archive GLPI et l'extrait pour remplacer l'installation actuelle.
7. **Restauration des données persistantes** — copie les répertoires `config/`, `files/`, `plugins/` et `marketplace/` de l'ancienne installation vers la nouvelle, puis ajuste les droits et les permissions.
8. **Mise à jour de la base de données** — exécute `php bin/console db:update --no-interaction` en tant qu'utilisateur web pour appliquer les migrations de schéma.

## Sauvegardes générées

Après chaque exécution, les sauvegardes suivantes sont disponibles dans `BACKUP_DIR` :

```
/var/backups/glpi/
├── glpi_db_20260225_143000.sql          # Dump SQL de la base de données
└── glpi_files_20260225_143000.tar.gz    # Archive complète des fichiers GLPI
```

L'ancien répertoire d'installation GLPI est également conservé sur le disque sous la forme :
```
/var/www/glpi_old_20260225_143000/
```

## Notes importantes

- Le script s'arrête immédiatement en cas d'erreur (`set -e`). Si une étape échoue, la sauvegarde précédente reste intacte.
- **Vérification de version** : si GLPI est déjà sur la dernière version, le script se termine proprement sans effectuer aucune modification.
- **Mode maintenance** : activé automatiquement avant toute modification de fichier et désactivé après une mise à jour réussie. En cas d'échec, le mode maintenance reste actif afin que le site demeure inaccessible jusqu'à l'intervention de l'administrateur.
- Les plugins et extensions du marketplace sont automatiquement migrés vers la nouvelle version.
- Après la mise à jour, vérifiez que vos plugins sont compatibles avec la nouvelle version de GLPI.

## Licence

MIT
