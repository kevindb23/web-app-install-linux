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

## Uninstall the web configuration

The following removes the custom site, database account, and database while leaving the Nginx, PHP, and MySQL packages installed:

```bash
sudo mysql -uroot <<'SQL'
DROP DATABASE IF EXISTS `billing`;
DROP USER IF EXISTS 'superadmin'@'%';
FLUSH PRIVILEGES;
SQL

sudo rm -f /etc/nginx/conf.d/custom-php.conf
sudo rm -f /etc/mysql/mysql.conf.d/99-custom-remote.cnf
sudo rm -f /etc/my.cnf.d/99-custom-remote.cnf
sudo rm -f /var/www/html/index.php
sudo rm -rf /var/backups/install-web-nginx-mysql

# Remove backup files created by older installer versions, if present.
sudo find /etc/nginx/sites-enabled /etc/nginx/conf.d -maxdepth 1 -type f -name '*.backup.*' -delete 2>/dev/null || true
sudo nginx -t && sudo systemctl restart nginx
```

If the installer removed the distribution’s default Nginx site, restore the newest backup before restarting Nginx:

```bash
backup="$(find /var/backups/install-web-nginx-mysql/nginx/sites-enabled -type f -name 'default.backup.*' 2>/dev/null | sort | tail -n 1)"
if [ -n "$backup" ]; then sudo cp -a "$backup" /etc/nginx/sites-enabled/default; fi
sudo nginx -t && sudo systemctl restart nginx
```

## Full purge on Debian/Ubuntu

WARNING: This removes the web stack, configuration, logs, the MySQL data directory, and the site files. Back up anything you need first.

```bash
sudo systemctl disable --now nginx php8.1-fpm mysql 2>/dev/null || true
sudo apt-get purge -y nginx nginx-common nginx-core php-cli php-fpm php-mysql mysql-server mysql-client mysql-common
sudo apt-get autoremove --purge -y
sudo rm -rf /etc/nginx /etc/php /etc/mysql /var/lib/mysql /var/log/mysql /var/www/html
sudo rm -rf /var/backups/install-web-nginx-mysql
```

On RHEL/Fedora/CentOS use `dnf remove` or `yum remove` with the installed Nginx, PHP/PHP-FPM, and MariaDB/MySQL package names. On Arch use `pacman -Rns`; on Alpine use `apk del`; and on openSUSE use `zypper remove`. Remove `/etc/nginx`, the relevant PHP/database configuration directories, `/var/lib/mysql`, and `/var/www/html` only after confirming they contain no unrelated applications.
