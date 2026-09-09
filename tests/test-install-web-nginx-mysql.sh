#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/install-web-nginx-mysql.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert_file() { [[ -f "$1" ]] || fail "missing file: $1"; }
assert_executable() { [[ -x "$1" ]] || fail "not executable: $1"; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "missing '$2' in $1"; }

assert_file "$SCRIPT"
assert_executable "$SCRIPT"
bash -n "$SCRIPT"

for marker in apt-get dnf yum pacman apk zypper 'WEB_ROOT="/var/www/html"' index.php billing superadmin; do
  assert_contains "$SCRIPT" "$marker"
done
assert_contains "$SCRIPT" 'bind-address = 0.0.0.0'
assert_contains "$SCRIPT" 'GRANT ALL PRIVILEGES ON *.* TO'
assert_contains "$SCRIPT" 'Welcome to custom page'
assert_contains "$SCRIPT" '[[ "$site" == "/etc/nginx/sites-enabled/default" ]]'
assert_contains "$SCRIPT" 'pacman -Syu --noconfirm'
assert_contains "$SCRIPT" 'mariadb-server mariadb'
assert_contains "$SCRIPT" 'migrate_legacy_nginx_backups'
if grep -Fq 'WITH GRANT OPTION' "$SCRIPT"; then
  fail "grant must not include WITH GRANT OPTION"
fi

output="$(INSTALLER_DRY_RUN=1 "$SCRIPT" 2>&1)"
assert_contains <(printf '%s\n' "$output") 'dry-run'

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

INSTALLER_DRY_RUN=1
source "$SCRIPT"
service_exists_systemd() { [[ "$1" == "mariadb" ]]; }
DB_SERVICE_CANDIDATES=(mysql mariadb)
selected_service="$(select_service DB_SERVICE_CANDIDATES)"
[[ "$selected_service" == "mariadb" ]] || fail "service discovery selected $selected_service instead of mariadb"
service_exists_openrc() { [[ "$1" == "mariadb" ]]; }
selected_service="$(select_service DB_SERVICE_CANDIDATES)"
[[ "$selected_service" == "mariadb" ]] || fail "OpenRC service discovery selected $selected_service instead of mariadb"

DRY_RUN=0
WEB_ROOT="$tmp_dir/web"
mkdir -p "$WEB_ROOT"
printf 'existing application entrypoint\n' > "$WEB_ROOT/index.php"
write_custom_index
assert_contains "$WEB_ROOT/index.php" 'Welcome to custom page'
backup_count="$(find "$WEB_ROOT" -maxdepth 1 -name 'index.php.backup.*' | wc -l)"
[[ "$backup_count" -eq 1 ]] || fail "existing index.php was not backed up"
assert_contains "$(find "$WEB_ROOT" -maxdepth 1 -name 'index.php.backup.*' -print -quit)" 'existing application entrypoint'

DB_CONFIG_DIR="$tmp_dir/mysql"
DB_SERVICE="mariadb"
enable_and_start_service() { :; }
restart_service() { :; }
configure_mysql
[[ "$(grep -c 'bind-address = 0.0.0.0' "$DB_CONFIG_DIR/99-custom-remote.cnf")" -eq 1 ]] || fail "database bind configuration missing"
configure_mysql
backup_count="$(find "$DB_CONFIG_DIR" -maxdepth 1 -name '99-custom-remote.cnf.backup.*' | wc -l)"
[[ "$backup_count" -eq 0 ]] || fail "managed database config was backed up unnecessarily"

nginx_site="$tmp_dir/etc/nginx/sites-enabled/default"
nginx_backup_dir="$tmp_dir/nginx-backups"
mkdir -p "$(dirname "$nginx_site")"
printf 'server {}\n' > "$nginx_site"
backup_file "$nginx_site" "$nginx_backup_dir"
[[ "$(find "$nginx_backup_dir" -type f -name 'default.backup.*' | wc -l)" -eq 1 ]] || fail "Nginx backup was not moved outside the include directory"
[[ "$(find "$(dirname "$nginx_site")" -maxdepth 1 -name 'default.backup.*' | wc -l)" -eq 0 ]] || fail "Nginx backup remains in the include directory"

printf 'PASS: installer contract\n'
