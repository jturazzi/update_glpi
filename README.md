# GLPI Automatic Backup & Update Script

Bash script that automates the **backup** and **update** of a GLPI instance to the latest version available on GitHub.

## Available scripts

| Script | Language |
|---|---|
| `update_glpi_en.sh` | English |
| `update_glpi_fr.sh` | French |

## Prerequisites

The following tools must be installed and available in `$PATH`:

- `bash`
- `curl` — to query the GitHub API
- `wget` — to download the GLPI archive
- `mysqldump` — to back up the database
- `php` — to run the GLPI database update console
- `tar` — to archive/extract files
- `sudo` — to run commands as the web user

The script must be run as **root** (or via `sudo`) since it performs `chown` and `chmod` operations on GLPI files.

## Configuration

Edit the variables at the top of the script before running it:

| Variable | Default value | Description |
|---|---|---|
| `GLPI_DIR` | `/var/www/glpi` | Path to the GLPI installation |
| `BACKUP_DIR` | `/var/backups/glpi` | Directory where backups are stored |
| `WEB_USER` | `www-data` | Web server user (Apache/Nginx) |

The database credentials (host, user, password, database name) are read automatically from the GLPI configuration file: `$GLPI_DIR/config/config_db.php`.

## Usage

```bash
# Make the script executable (already done if you cloned this repo)
chmod +x update_glpi_en.sh

# Run as root
sudo ./update_glpi_en.sh
```

## What the script does

The script runs **8 steps**:

1. **Environment preparation** — creates the backup directory if it does not exist.
2. **Reading DB credentials** — extracts connection information from `config_db.php`.
3. **Fetching the latest version** — queries the GitHub API to get the download URL of the latest GLPI release.
4. **Database backup** — dumps the database to `$BACKUP_DIR/glpi_db_<DATE>.sql` via `mysqldump`.
5. **File backup** — archives the entire GLPI directory to `$BACKUP_DIR/glpi_files_<DATE>.tar.gz`.
6. **Download & extraction** — downloads the new GLPI archive and extracts it to replace the current installation.
7. **Restoring persistent data** — copies the `config/`, `files/`, `plugins/`, and `marketplace/` directories from the old installation to the new one, then adjusts ownership and permissions.
8. **Database update** — runs `php bin/console db:update --no-interaction` as the web user to apply schema migrations.

## Backups generated

After each run, the following backups are available in `BACKUP_DIR`:

```
/var/backups/glpi/
├── glpi_db_20260225_143000.sql          # SQL database dump
└── glpi_files_20260225_143000.tar.gz    # Full archive of GLPI files
```

The old GLPI installation directory is also preserved on disk as:
```
/var/www/glpi_old_20260225_143000/
```

## Important notes

- The script stops immediately on any error (`set -e`). If a step fails, the previous backup remains intact.
- Plugins and marketplace extensions are automatically migrated to the new version.
- After the update, verify that your plugins are compatible with the new GLPI version.

## License

MIT
