# PHP, MySQL, and Nginx Installer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a cross-family `install-web-nginx-mysql.sh` installer and README instructions for an Nginx/PHP-FPM/MySQL-compatible web stack rooted at `/var/www/html`.

**Architecture:** Use one Bash entrypoint with explicit package-manager adapters for apt, dnf/yum, pacman, apk, and zypper. Keep package installation, service discovery, Nginx/PHP configuration, and database setup in separate functions, with dry-run support and a shell contract test that exercises safe helpers against temporary files.

**Tech Stack:** Bash, POSIX utilities, Nginx, PHP-FPM, MySQL/MariaDB client/server, shell test harness.

**Spec:** `docs/superpowers/specs/2026-09-09-install-web-nginx-mysql-design.md`

## Global Constraints

- Install into `/var/www/html` and write `/var/www/html/index.php` with `Welcome to custom page`.
- Support apt, dnf/yum, pacman, apk, and zypper package-manager families; fail clearly when unsupported.
- Configure the database to listen on all IPv4 interfaces where supported.
- Create database `billing` and `%` host user `superadmin` with password `superadmin` and `ALL PRIVILEGES ON *.*`, without `WITH GRANT OPTION`.
- Use a dedicated Nginx configuration, validate with `nginx -t`, and avoid deleting unrelated web files.
- README installation instructions must use `wget`.
- Do not change global Git configuration; repository commits use the local identity already configured for this checkout.

---

### Task 1: Add failing installer contract tests

**Files:**
- Create: `tests/test-install-web-nginx-mysql.sh`

**Interfaces:**
- Consumes: the future executable `install-web-nginx-mysql.sh` and its `--dry-run` output.
- Produces: repeatable shell assertions for required metadata, package-manager branches, generated content, SQL, and safety checks.

- [ ] **Step 1: Write the failing test harness**

Create a Bash test script that locates the repository root, asserts the installer exists and is executable, runs `bash -n`, and checks these literal contracts with `grep -F`:

```bash
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

for marker in apt-get dnf yum pacman apk zypper /var/www/html/index.php billing superadmin; do
  assert_contains "$SCRIPT" "$marker"
done
assert_contains "$SCRIPT" 'bind-address = 0.0.0.0'
assert_contains "$SCRIPT" 'GRANT ALL PRIVILEGES ON *.* TO' 
assert_contains "$SCRIPT" 'Welcome to custom page'

output="$(INSTALLER_DRY_RUN=1 "$SCRIPT" 2>&1 || true)"
assert_contains <(printf '%s\n' "$output") 'dry-run'
printf 'PASS: installer contract\n'
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test-install-web-nginx-mysql.sh`

Expected: FAIL because `install-web-nginx-mysql.sh` does not exist.

- [ ] **Step 3: Commit the failing test**

```bash
git add tests/test-install-web-nginx-mysql.sh
git commit -m "test: define installer contract"
```

### Task 2: Implement the installer and make the contract pass

**Files:**
- Create: `install-web-nginx-mysql.sh`
- Modify: `tests/test-install-web-nginx-mysql.sh` only if an assertion needs to match the final interface exactly.

**Interfaces:**
- Consumes: `INSTALLER_DRY_RUN=1` for non-mutating planning output; optional existing `/etc/os-release`, package manager, service manager, Nginx/PHP/MySQL configuration paths.
- Produces: an executable root-only installer with functions `detect_platform`, `install_packages`, `configure_php_fpm`, `configure_nginx`, `configure_mysql`, and `enable_and_start_services`.

- [ ] **Step 1: Add the Bash entrypoint and constants**

Use `#!/usr/bin/env bash`, `set -Eeuo pipefail`, a cleanup/error trap, constants for `/var/www/html`, `billing`, `superadmin`, and `superadmin`, plus a `run` helper that prints commands in dry-run mode and executes them otherwise. Reject non-root execution unless `INSTALLER_DRY_RUN=1` is set.

- [ ] **Step 2: Add platform detection and package adapters**

Read `/etc/os-release`, recognize the five supported package-manager families, select package arrays, and define database/PHP-FPM service candidates. Use `apt-get update && apt-get install -y`, `dnf install -y` or `yum install -y`, `pacman -Syu --noconfirm`, `apk add --no-cache`, or `zypper --non-interactive install`. For Alpine, select the available `php*-fpm` package family before installing its CLI/FPM/MySQL-extension packages. Exit before configuration when no supported manager is found.

- [ ] **Step 3: Add service discovery and lifecycle helpers**

Implement candidates for `mysql`, `mysqld`, and `mariadb`, and candidates for PHP-FPM service names. Prefer `systemctl enable --now` when systemd is available; otherwise use `rc-update`/`rc-service` or `service`. Discover a PHP-FPM Unix socket under `/run` or `/var/run`, falling back to `127.0.0.1:9000` only when no socket is present. Wait for `mysqladmin ping` before SQL setup.

- [ ] **Step 4: Configure Nginx and PHP-FPM**

Create `/etc/nginx/conf.d/custom-php.conf` with `listen 80 default_server`, `/var/www/html`, `index index.php index.html`, `try_files`, FastCGI parameters, and the discovered PHP-FPM endpoint. If `/etc/nginx/sites-enabled/default` exists, copy it to a timestamped backup and remove only that default link/file. Write the requested PHP page after removing only known default index names such as `index.nginx-debian.html` and `index.html`. Run `nginx -t` before reloading/enabling Nginx.

- [ ] **Step 5: Configure remote database access and credentials**

Write a timestamped-safe drop-in containing `[mysqld]` and `bind-address = 0.0.0.0` in the distro’s MySQL configuration include directory. Initialize an empty MariaDB data directory when the platform requires it. Run idempotent SQL through the local root socket:

```sql
CREATE DATABASE IF NOT EXISTS `billing`;
CREATE USER IF NOT EXISTS 'superadmin'@'%' IDENTIFIED BY 'superadmin';
ALTER USER 'superadmin'@'%' IDENTIFIED BY 'superadmin';
GRANT ALL PRIVILEGES ON *.* TO 'superadmin'@'%';
FLUSH PRIVILEGES;
```

Do not add `WITH GRANT OPTION`. Report that host firewalls may still block port 3306 and that exposing this account is unsafe.

- [ ] **Step 6: Make the contract test pass**

Run: `chmod +x install-web-nginx-mysql.sh && bash tests/test-install-web-nginx-mysql.sh`

Expected: PASS with `PASS: installer contract` and a dry-run message, with no changes to `/etc`, `/var/www/html`, or the real database.

- [ ] **Step 7: Commit the installer**

```bash
git add install-web-nginx-mysql.sh tests/test-install-web-nginx-mysql.sh
git commit -m "feat: add cross-platform web stack installer"
```

### Task 3: Update README with wget usage and operational notes

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: the installer’s GitHub raw URL and the fixed configuration values.
- Produces: concise operator documentation with copy-paste installation, supported platforms, results, credentials, and security warning.

- [ ] **Step 1: Replace the placeholder README**

Document this command using `wget`:

```bash
wget -O install-web-nginx-mysql.sh https://raw.githubusercontent.com/kevindb23/web-app-install-linux/main/install-web-nginx-mysql.sh
chmod +x install-web-nginx-mysql.sh
sudo ./install-web-nginx-mysql.sh
```

Include that the script supports Debian/Ubuntu, RHEL/Fedora/CentOS, Arch, Alpine, and openSUSE; installs Nginx/PHP-FPM/PHP-MySQL/MySQL-compatible server; writes `/var/www/html/index.php`; creates `billing`; and configures `superadmin` / `superadmin` from any host with all-database privileges. Put the security warning immediately beside the credentials and explain that the password must be changed and access restricted after first login.

- [ ] **Step 2: Verify README contracts**

Run:

```bash
grep -Fq 'wget -O install-web-nginx-mysql.sh' README.md
grep -Fq 'Welcome to custom page' install-web-nginx-mysql.sh
git diff --check
```

Expected: all commands exit 0.

- [ ] **Step 3: Commit the README**

```bash
git add README.md
git commit -m "docs: document web stack installer"
```

### Task 4: Full verification and push

**Files:**
- Verify: `install-web-nginx-mysql.sh`, `README.md`, `tests/test-install-web-nginx-mysql.sh`, and committed history.

- [ ] **Step 1: Run the complete local verification**

Run:

```bash
bash -n install-web-nginx-mysql.sh
bash -n tests/test-install-web-nginx-mysql.sh
bash tests/test-install-web-nginx-mysql.sh
git diff --check HEAD~3..HEAD
git status --short --branch
```

Expected: syntax checks and contract test pass, diff check is clean, and the feature branch contains only the intended commits/files.

- [ ] **Step 2: Review the final diff against the spec**

Confirm the installer includes every package-manager branch, writes the exact page text, configures the requested `%` database user and `ALL PRIVILEGES ON *.*`, and does not use `WITH GRANT OPTION`; confirm README includes the `wget` command and warning.

- [ ] **Step 3: Push the feature branch**

```bash
git push -u origin feat/install-web-nginx-mysql
```

Expected: GitHub reports the new branch and its commits. Do not claim the installer was executed on a real server unless a target host is separately provided and tested.
