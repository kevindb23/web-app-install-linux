# PHP, MySQL, and Nginx Installer Design

## Goal

Add `install-web-nginx-mysql.sh`, a root-run installer for common Linux families that installs Nginx, PHP with PHP-FPM and MySQL connectivity, and a MySQL-compatible server; configures a PHP site at `/var/www/html`; and documents a `wget`-based installation command.

## Scope and assumptions

- Supported package-manager families are Debian/Ubuntu (`apt-get`), RHEL/Fedora/CentOS (`dnf` or `yum`), Arch (`pacman`), Alpine (`apk`), and openSUSE (`zypper`).
- The script uses the distribution’s available MySQL-compatible server package. Where a distribution supplies MariaDB instead of Oracle MySQL, the installer treats it as the compatible server implementation and says so in its output/documentation.
- The script is intended for a fresh or existing web server and may update existing Nginx/PHP/MySQL configuration files. It must not remove unrelated application files from `/var/www/html`; it removes only known default index files before writing the requested `index.php`.
- The default site is HTTP-only and listens on port 80 for all addresses.

## Installation flow

1. Verify the script is running as root and that it is on a supported Linux distribution/package manager.
2. Refresh package metadata and install Nginx, PHP, PHP-FPM, the PHP MySQL driver, a database server, and the database client. Package names are selected per package-manager family.
3. Detect the installed PHP-FPM service and socket or TCP endpoint. Configure Nginx to serve `/var/www/html`, pass `.php` requests to that endpoint, and use `index.php` as the first index document.
4. Remove the standard default Nginx index files if present, write `/var/www/html/index.php` containing `Welcome to custom page`, and set web-readable ownership/permissions without changing unrelated files.
5. Enable and start Nginx, PHP-FPM, and the database service using the service manager available on the host. Validate the Nginx configuration before restarting/reloading it.
6. Configure the database server to bind on all IPv4 interfaces where supported, create the `billing` database, and create/update `superadmin` at host `%` with password `superadmin` and `ALL PRIVILEGES ON *.*`. Flush/reload privilege state as needed by the server implementation.
7. Print the installed service status, web root, database name/user, and a prominent warning that the database port and all-database administrator credentials are exposed to any reachable IP.

## Package and service abstraction

The script will keep package installation and service setup in small shell functions so distro-specific differences stay localized:

- `detect_platform`: selects package manager, package names, service commands, and PHP-FPM endpoint conventions.
- `install_packages`: refreshes metadata and installs the selected package set non-interactively where the package manager supports it.
- `configure_php_fpm` and `configure_nginx`: write a dedicated site configuration, remove/disable conflicting default site configuration where necessary, validate it, and reload Nginx.
- `configure_mysql`: locate a usable database client, make the bind-address change in the appropriate server configuration, wait for readiness, and execute idempotent SQL.
- `enable_and_start_services`: use `systemctl` when available and compatible, otherwise use the distribution’s service command; fail with an actionable message if a required service cannot be started.

Unsupported or ambiguous environments must stop before destructive configuration changes and explain the missing prerequisite.

## Database behavior

The SQL must be safely quoted for the fixed credential values (`superadmin` / `superadmin`), use `CREATE DATABASE IF NOT EXISTS billing`, and use an update-or-create flow for `superadmin` at `%` so rerunning the installer updates the requested password and privileges. The grant is `ALL PRIVILEGES ON *.*` without `WITH GRANT OPTION`; this gives the account access to all databases without allowing it to delegate privileges to other accounts.

The installer must not print the password in normal progress messages beyond the documented credential block, and README guidance must recommend changing it immediately after installation. The script should make a best-effort firewall note rather than silently opening a host firewall, because firewall tooling and the user’s intended network boundary vary across distributions.

## Files

- `install-web-nginx-mysql.sh`: executable, portable POSIX-oriented shell installer with distro detection, configuration, SQL setup, and validation.
- `README.md`: usage via `wget`, supported distributions, installed components, resulting page, database credentials, and security warning.
- `docs/superpowers/specs/2026-09-09-install-web-nginx-mysql-design.md`: this approved design record.

## Error handling and idempotency

- Use strict shell behavior and explicit command checks, while allowing expected “already exists” conditions in SQL/configuration paths.
- Exit before changes when not root, when the package manager is unsupported, or when required commands cannot be installed.
- Back up any existing Nginx site configuration that the script replaces, with a timestamped backup in `/etc/nginx` where permissions allow.
- Avoid deleting arbitrary web content. On failure after partial installation, report which phase failed and the commands the operator should inspect.

## Verification

Static verification will check shell syntax, executable permissions, required package-manager branches, the Nginx/PHP configuration directives, the exact requested page text, SQL grants, and README `wget` instructions. A disposable test harness will stub package/service/system commands and assert the script’s control flow without changing the host’s real `/etc`, `/var/www/html`, or database. If a real target environment is available, follow-up checks should include `nginx -t`, a local HTTP request to `/`, PHP execution, and a remote MySQL connection test from an authorized client.
