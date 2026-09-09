# Web App Install Linux

Install Nginx, PHP-FPM, PHP MySQL support, and a MySQL-compatible server with one command sequence.

## Install

```bash
wget -O install-web-nginx-mysql.sh https://raw.githubusercontent.com/kevindb23/web-app-install-linux/main/install-web-nginx-mysql.sh
chmod +x install-web-nginx-mysql.sh
sudo ./install-web-nginx-mysql.sh
```

The installer supports Debian/Ubuntu, RHEL/Fedora/CentOS, Arch Linux, Alpine, and openSUSE systems with `apt`, `dnf`/`yum`, `pacman`, `apk`, or `zypper`.

It will:

- Install and enable Nginx, PHP-FPM, PHP MySQL support, and MySQL or MariaDB.
- Configure `/var/www/html` as the default Nginx site.
- Remove the standard default Nginx page and write `/var/www/html/index.php` containing `Welcome to custom page`.
- Create the `billing` database.
- Allow the database administrator account to connect from any host and grant it access to all databases.

## Database credentials

```text
Database: billing
Username: superadmin
Password: superadmin
Host:     %
Grants:   ALL PRIVILEGES ON *.*
```

WARNING: This deliberately exposes the database service for remote access from any IP and uses an all-database administrator account with a simple password. Restrict port 3306 with your firewall and change the password immediately after installation.

The installer does not change firewall rules because firewall tooling and the correct network boundary vary by server. Verify your firewall and cloud security-group rules before using this on the public internet.
