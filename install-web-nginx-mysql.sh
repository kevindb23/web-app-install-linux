#!/usr/bin/env bash
set -Eeuo pipefail

WEB_ROOT="/var/www/html"
DB_NAME="billing"
DB_USER="superadmin"
DB_PASSWORD="superadmin"
DRY_RUN="${INSTALLER_DRY_RUN:-0}"

PACKAGE_MANAGER=""
DB_CONFIG_DIR="/etc/mysql/mysql.conf.d"
DB_SERVICE_CANDIDATES=(mysql mariadb mysqld)
PHP_SERVICE_CANDIDATES=(php-fpm php8.3-fpm php8.2-fpm php8.1-fpm php8.0-fpm)
PHP_PACKAGES=()
DB_PACKAGES=()
NGINX_PACKAGES=(nginx)
PACKAGE_NAMES=()
PHP_FPM_ENDPOINT="127.0.0.1:9000"
DB_SERVICE=""
PHP_FPM_SERVICE=""

log() { printf '[install] %s\n' "$*"; }
warn() { printf '[warning] %s\n' "$*" >&2; }
die() { printf '[error] %s\n' "$*" >&2; exit 1; }

on_error() {
  local exit_code=$?
  printf '[error] installation stopped at line %s (exit %s)\n' "${BASH_LINENO[0]:-unknown}" "$exit_code" >&2
  exit "$exit_code"
}
trap on_error ERR

run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '[dry-run]'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

require_root() {
  [[ "$DRY_RUN" == "1" ]] && return 0
  [[ "${EUID}" -eq 0 ]] || die "run this installer as root or with sudo"
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

backup_file() {
  local file="$1"
  [[ -e "$file" ]] || return 0
  local backup="${file}.backup.$(date +%Y%m%d%H%M%S).$$"
  run cp -a "$file" "$backup"
  log "backed up $file to $backup"
}

find_alpine_php_prefix() {
  local candidate=""
  candidate="$(apk search -q 'php[0-9]*-fpm' 2>/dev/null | sed -n 's/^\(php[0-9]*\)-fpm.*$/\1/p' | sort -V | tail -n 1 || true)"
  printf '%s' "${candidate:-php83}"
}

detect_platform() {
  local distro_id="" distro_like=""
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    distro_id="${ID:-}"
    distro_like="${ID_LIKE:-}"
  fi

  if command_exists apt-get; then
    PACKAGE_MANAGER="apt-get"
    PHP_PACKAGES=(php-cli php-fpm php-mysql)
    DB_PACKAGES=(mysql-server mysql-client)
    DB_CONFIG_DIR="/etc/mysql/mysql.conf.d"
  elif command_exists dnf; then
    PACKAGE_MANAGER="dnf"
    PHP_PACKAGES=(php-cli php-fpm php-mysqlnd)
    case "$distro_id" in
      fedora|rhel|centos|rocky|almalinux|ol) DB_PACKAGES=(mariadb-server mariadb) ;;
      *) DB_PACKAGES=(mysql-server mysql) ;;
    esac
    DB_CONFIG_DIR="/etc/my.cnf.d"
  elif command_exists yum; then
    PACKAGE_MANAGER="yum"
    PHP_PACKAGES=(php-cli php-fpm php-mysqlnd)
    DB_PACKAGES=(mariadb-server mariadb)
    DB_CONFIG_DIR="/etc/my.cnf.d"
  elif command_exists pacman; then
    PACKAGE_MANAGER="pacman"
    PHP_PACKAGES=(php php-fpm)
    DB_PACKAGES=(mariadb mariadb-clients)
    DB_CONFIG_DIR="/etc/my.cnf.d"
  elif command_exists apk; then
    local php_prefix
    php_prefix="$(find_alpine_php_prefix)"
    PACKAGE_MANAGER="apk"
    PHP_PACKAGES=("$php_prefix" "${php_prefix}-fpm" "${php_prefix}-mysqli")
    DB_PACKAGES=(mariadb mariadb-client)
    DB_CONFIG_DIR="/etc/my.cnf.d"
    PHP_SERVICE_CANDIDATES=("php-fpm${php_prefix#php}" php-fpm83 php-fpm82 php-fpm)
  elif command_exists zypper; then
    PACKAGE_MANAGER="zypper"
    PHP_PACKAGES=(php8 php8-fpm php8-mysql)
    DB_PACKAGES=(mariadb mariadb-client)
    DB_CONFIG_DIR="/etc/my.cnf.d"
  else
    die "unsupported Linux distribution or package manager (detected ID=$distro_id ID_LIKE=$distro_like)"
  fi

  PACKAGE_NAMES=("${NGINX_PACKAGES[@]}" "${PHP_PACKAGES[@]}" "${DB_PACKAGES[@]}")
  log "using package manager: $PACKAGE_MANAGER"
  log "selected packages: ${PACKAGE_NAMES[*]}"
}

install_packages() {
  log "installing Nginx, PHP-FPM, PHP MySQL support, and a MySQL-compatible server"
  case "$PACKAGE_MANAGER" in
    apt-get)
      run apt-get update
      run apt-get install -y "${PACKAGE_NAMES[@]}"
      ;;
    dnf) run dnf install -y "${PACKAGE_NAMES[@]}" ;;
    yum) run yum install -y "${PACKAGE_NAMES[@]}" ;;
    pacman) run pacman -Syu --noconfirm "${PACKAGE_NAMES[@]}" ;;
    apk) run apk add --no-cache "${PACKAGE_NAMES[@]}" ;;
    zypper) run zypper --non-interactive install "${PACKAGE_NAMES[@]}" ;;
    *) die "no package installation adapter for $PACKAGE_MANAGER" ;;
  esac
}

systemd_available() {
  command_exists systemctl && [[ -d /run/systemd/system ]]
}

service_exists_systemd() {
  local load_state=""
  systemd_available || return 1
  load_state="$(systemctl show "$1" --property=LoadState --value 2>/dev/null || true)"
  [[ "$load_state" == "loaded" || "$load_state" == "generated" ]]
}

service_exists_openrc() {
  command_exists rc-service && [[ -x "/etc/init.d/$1" ]]
}

select_service() {
  local candidate
  local discovered=""
  local -n candidates_ref=$1
  for candidate in "${candidates_ref[@]}"; do
    if service_exists_systemd "$candidate"; then
      printf '%s' "$candidate"
      return 0
    fi
    if service_exists_openrc "$candidate"; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  if [[ "$1" == "PHP_SERVICE_CANDIDATES" ]] && systemd_available; then
    discovered="$(systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '$1 ~ /^php[0-9.]+-fpm\.service$/ {sub(/\.service$/, "", $1); print $1}' | sort -V | tail -n 1 || true)"
    [[ -n "$discovered" ]] && { printf '%s' "$discovered"; return 0; }
  fi
  die "could not find an installed service matching: ${candidates_ref[*]}"
}

service_action() {
  local action="$1" service="$2"
  if systemd_available; then
    run systemctl "$action" "$service"
  elif command_exists rc-service; then
    if [[ "$action" == "enable" ]]; then
      run rc-update add "$service" default
    else
      run rc-service "$service" "$action"
    fi
  elif command_exists service; then
    [[ "$action" != "enable" ]] || return 0
    run service "$service" "$action"
  else
    die "cannot manage service $service: no service manager found"
  fi
}

enable_and_start_service() {
  local service="$1"
  log "enabling and starting $service"
  if systemd_available; then
    run systemctl enable --now "$service"
  else
    service_action enable "$service"
    service_action start "$service"
  fi
}

restart_service() {
  local service="$1"
  if systemd_available; then
    run systemctl restart "$service"
  elif command_exists rc-service || command_exists service; then
    service_action restart "$service"
  fi
}

discover_services() {
  DB_SERVICE="$(select_service DB_SERVICE_CANDIDATES)"
  PHP_FPM_SERVICE="$(select_service PHP_SERVICE_CANDIDATES)"
  log "database service: $DB_SERVICE"
  log "PHP-FPM service: $PHP_FPM_SERVICE"
}

initialize_mariadb_if_needed() {
  [[ -d /var/lib/mysql ]] || return 0
  [[ -d /var/lib/mysql/mysql ]] && return 0
  if command_exists mariadb-install-db; then
    log "initializing the empty MariaDB data directory"
    run mariadb-install-db --user=mysql --datadir=/var/lib/mysql
  elif command_exists mysql_install_db; then
    log "initializing the empty MySQL data directory"
    run mysql_install_db --user=mysql --datadir=/var/lib/mysql
  fi
}

configure_mysql() {
  local config_file="${DB_CONFIG_DIR}/99-custom-remote.cnf"
  log "configuring database access on all IPv4 interfaces"
  run mkdir -p "$DB_CONFIG_DIR"
  if [[ -f "$config_file" ]] && ! grep -Fq '# Managed by install-web-nginx-mysql.sh' "$config_file"; then
    backup_file "$config_file"
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '[dry-run] write %s\n' "$config_file"
  else
    install -m 0644 /dev/null "$config_file"
    cat > "$config_file" <<'EOF'
[mysqld]
# Managed by install-web-nginx-mysql.sh
bind-address = 0.0.0.0
EOF
  fi
  initialize_mariadb_if_needed
  enable_and_start_service "$DB_SERVICE"
  restart_service "$DB_SERVICE"
}

find_database_client() {
  if command_exists mysql; then printf '%s' "mysql";
  elif command_exists mariadb; then printf '%s' "mariadb";
  else die "no MySQL/MariaDB client was found after package installation";
  fi
}

find_database_admin_client() {
  if command_exists mysqladmin; then printf '%s' "mysqladmin";
  elif command_exists mariadb-admin; then printf '%s' "mariadb-admin";
  else die "no mysqladmin or mariadb-admin command was found after package installation";
  fi
}

wait_for_database() {
  local admin_client="$1" attempt
  for attempt in $(seq 1 30); do
    if "$admin_client" --protocol=socket -uroot ping >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  die "database service did not become ready within 30 seconds"
}

create_database_and_user() {
  local client="$1"
  log "creating database $DB_NAME and remote administrator $DB_USER"
  "$client" --protocol=socket -uroot <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`;
CREATE USER IF NOT EXISTS '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASSWORD}';
ALTER USER '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON *.* TO '${DB_USER}'@'%';
FLUSH PRIVILEGES;
SQL
}

discover_php_fpm_endpoint() {
  local socket
  shopt -s nullglob
  for socket in /run/php/php*-fpm.sock /run/php-fpm/*.sock /var/run/php/php*-fpm.sock /var/run/php-fpm/*.sock; do
    if [[ -S "$socket" ]]; then
      PHP_FPM_ENDPOINT="unix:${socket}"
      return 0
    fi
  done
  PHP_FPM_ENDPOINT="127.0.0.1:9000"
}

configure_php_fpm() {
  discover_php_fpm_endpoint
  log "using PHP-FPM endpoint: $PHP_FPM_ENDPOINT"
}

remove_known_default_pages() {
  local file
  for file in "$WEB_ROOT/index.nginx-debian.html" "$WEB_ROOT/index.nginx.html"; do
    [[ -e "$file" ]] || continue
    run rm -f "$file"
  done
  if [[ -f "$WEB_ROOT/index.html" ]] && grep -Eiq 'welcome to nginx|apache2 ubuntu default page' "$WEB_ROOT/index.html"; then
    run rm -f "$WEB_ROOT/index.html"
  fi
}

write_custom_index() {
  log "writing $WEB_ROOT/index.php"
  run mkdir -p "$WEB_ROOT"
  remove_known_default_pages
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '[dry-run] write %s/index.php\n' "$WEB_ROOT"
  else
    [[ ! -f "$WEB_ROOT/index.php" ]] || backup_file "$WEB_ROOT/index.php"
    cat > "$WEB_ROOT/index.php" <<'PHP'
<?php
echo "Welcome to custom page";
PHP
    chmod 0644 "$WEB_ROOT/index.php"
  fi
}

backup_default_nginx_sites() {
  local site
  for site in /etc/nginx/sites-enabled/default /etc/nginx/conf.d/default.conf; do
    [[ -e "$site" ]] || continue
    if [[ "$site" == "/etc/nginx/sites-enabled/default" ]] || grep -Eiq 'welcome to nginx|root[[:space:]]+/usr/share/nginx/html' "$site"; then
      backup_file "$site"
      run rm -f "$site"
    else
      warn "leaving non-default Nginx site in place: $site"
    fi
  done
}

configure_nginx() {
  local nginx_config="/etc/nginx/conf.d/custom-php.conf"
  log "configuring Nginx for $WEB_ROOT"
  run mkdir -p /etc/nginx/conf.d
  backup_default_nginx_sites
  [[ ! -f "$nginx_config" ]] || backup_file "$nginx_config"
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '[dry-run] write %s\n' "$nginx_config"
  else
    cat > "$nginx_config" <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    root ${WEB_ROOT};
    index index.php index.html;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_pass ${PHP_FPM_ENDPOINT};
    }
}
EOF
  fi
  write_custom_index
  if [[ "$DRY_RUN" == "1" ]]; then printf '[dry-run] nginx -t\n'; else nginx -t; fi
  enable_and_start_service nginx
  restart_service nginx
}

print_summary() {
  log "installation complete"
  log "web root: $WEB_ROOT"
  log "page: http://<server-ip>/"
  log "database: $DB_NAME"
  log "database user: $DB_USER@%"
  warn "MySQL/MariaDB is configured for remote access from any IP. Restrict port 3306 with a firewall and change the default password immediately."
}

main() {
  require_root
  detect_platform
  install_packages
  if [[ "$DRY_RUN" == "1" ]]; then
    log "dry-run complete; no packages, services, configuration, or web files were changed"
    return 0
  fi
  discover_services
  configure_mysql
  enable_and_start_service "$PHP_FPM_SERVICE"
  configure_php_fpm
  configure_nginx
  wait_for_database "$(find_database_admin_client)"
  create_database_and_user "$(find_database_client)"
  print_summary
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
