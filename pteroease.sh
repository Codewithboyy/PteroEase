#!/usr/bin/env bash
# SPYDR — Pterodactyl Management Toolkit
# Supported target: Ubuntu 22.04 / 24.04
# Run: sudo bash pteroease.sh

set -uo pipefail
umask 077

APP="SPYDR"
VERSION="1.0.0"
PANEL_DIR="/var/www/pterodactyl"
WINGS_CONFIG="/etc/pterodactyl/config.yml"
BACKUP_ROOT="/var/backups/pteroease"
LOG_DIR="/var/log/pteroease"
LOG_FILE="$LOG_DIR/pteroease.log"
PANEL_SERVICE="nginx"
DB_NAME=""
DB_USER=""
DB_PASS=""
LAST_BACKUP=""

# Auto-install settings (populated during guided install)
DOMAIN=""
PANEL_DB_NAME="panel"
PANEL_DB_USER="pterodactyl"
PANEL_DB_PASS=""
ADMIN_EMAIL=""
ADMIN_USER=""
ADMIN_FIRST=""
ADMIN_LAST=""
ADMIN_PASS=""
USE_SSL="yes"
PTEROQ_SERVICE="/etc/systemd/system/pteroq.service"
WINGS_SERVICE="/etc/systemd/system/wings.service"

if [[ $EUID -eq 0 ]]; then
    mkdir -p "$LOG_DIR" "$BACKUP_ROOT" 2>/dev/null || true
    touch "$LOG_FILE" 2>/dev/null || true
fi

# ─────────────────────────────────────────────
#  COLOURS
# ─────────────────────────────────────────────
C_RESET=$'\033[0m'
C_RED=$'\033[1;31m'
C_GREEN=$'\033[1;32m'
C_YELLOW=$'\033[1;33m'
C_BLUE=$'\033[1;34m'
C_CYAN=$'\033[1;36m'
C_BOLD=$'\033[1m'
C_DIM=$'\033[2m'

# ─────────────────────────────────────────────
#  LOGGING
# ─────────────────────────────────────────────
log() {
    local level="$1"; shift
    local msg="$*"
    printf '[%s] [%s] %s\n' "$(date '+%F %T')" "$level" "$msg" \
        >> "$LOG_FILE" 2>/dev/null || true
    case "$level" in
        ERROR) printf '  %s✖  %s%s\n'   "$C_RED"    "$msg" "$C_RESET" ;;
        WARN)  printf '  %s⚠  %s%s\n'   "$C_YELLOW" "$msg" "$C_RESET" ;;
        OK)    printf '  %s✔  %s%s\n'   "$C_GREEN"  "$msg" "$C_RESET" ;;
        *)     printf '  %s›  %s%s\n'   "$C_CYAN"   "$msg" "$C_RESET" ;;
    esac
}

# ─────────────────────────────────────────────
#  HEADER
# ─────────────────────────────────────────────
header() {
    clear 2>/dev/null || true
    printf '%s\n' "$C_CYAN"
    echo "  ███████╗██████╗ ██╗   ██╗██████╗ ██████╗ "
    echo "  ██╔════╝██╔══██╗╚██╗ ██╔╝██╔══██╗██╔══██╗"
    echo "  ███████╗██████╔╝ ╚████╔╝ ██████╔╝██████╔╝"
    echo "  ╚════██║██╔═══╝   ╚██╔╝  ██╔══██╗██╔══██╗"
    echo "  ███████║██║        ██║   ██║  ██║██║  ██║"
    echo "  ╚══════╝╚═╝        ╚═╝   ╚═╝  ╚═╝╚═╝  ╚═╝"
    printf '%s\n' "$C_RESET"
    printf '       %sMade by SpiderGamer with ❤️%s\n' "$C_YELLOW" "$C_RESET"
    echo
    printf '  %sSPYDR%s | Pterodactyl Management Toolkit   %sv%s%s\n' \
        "$C_BLUE$C_BOLD" "$C_RESET" "$C_DIM" "$VERSION" "$C_RESET"
    printf '  %s────────────────────────────────────────────%s\n' "$C_DIM" "$C_RESET"
    printf '  Host: %s%s%s\n' "$C_BOLD" "$(hostname)" "$C_RESET"
    printf '  OS:   %s\n' "$(grep -oP '^PRETTY_NAME="\K[^"]+' /etc/os-release 2>/dev/null || echo unknown)"
    local panel_status wings_status
    panel_status="$(systemctl is-active pteroq 2>/dev/null || echo unknown)"
    wings_status="$(systemctl is-active wings   2>/dev/null || echo unknown)"
    _status_colour() {
        [[ "$1" == "active" ]] && printf '%s%s%s' "$C_GREEN" "$1" "$C_RESET" \
                               || printf '%s%s%s' "$C_RED"   "$1" "$C_RESET"
    }
    printf '  Panel: %s   Wings: %s\n' "$(_status_colour "$panel_status")" "$(_status_colour "$wings_status")"
    printf '  %s────────────────────────────────────────────%s\n\n' "$C_DIM" "$C_RESET"
}

# ─────────────────────────────────────────────
#  HELPERS
# ─────────────────────────────────────────────
pause() {
    echo
    printf '  %sPress Enter to return to menu...%s' "$C_DIM" "$C_RESET"
    read -r _ || true
}

confirm() {
    local expected="$1"
    local prompt="$2"
    echo
    printf '  %s⚠  %s%s\n' "$C_YELLOW" "$prompt" "$C_RESET"
    printf '  Type %s%s%s to confirm: ' "$C_BOLD" "$expected" "$C_RESET"
    read -r answer || return 1
    [[ "$answer" == "$expected" ]]
}

need_root() {
    if [[ $EUID -ne 0 ]]; then
        log ERROR "Run this toolkit as root: sudo bash pteroease.sh"
        return 1
    fi
}

supported_os() {
    [[ -r /etc/os-release ]] || return 1
    # shellcheck disable=SC1091
    source /etc/os-release
    [[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" =~ ^(22\.04|24\.04)$ ]]
}

panel_installed() { [[ -d "$PANEL_DIR" && -f "$PANEL_DIR/artisan" ]]; }
wings_installed()  { [[ -x /usr/local/bin/wings || -f "$WINGS_CONFIG" ]]; }

# ─────────────────────────────────────────────
#  PROGRESS SPINNER
# ─────────────────────────────────────────────
progress_wait() {
    local pid="$1" label="$2"
    local frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0
    while kill -0 "$pid" 2>/dev/null; do
        printf '\r  %s%s%s %s' "$C_CYAN" "${frames:i%10:1}" "$C_RESET" "$label"
        sleep 0.1
        (( i += 1 ))
    done
    wait "$pid"
    local rc=$?
    if (( rc == 0 )); then
        printf '\r  %s✔%s  %-55s\n' "$C_GREEN" "$C_RESET" "$label"
    else
        printf '\r  %s✖%s  %-50s (exit %s)\n' "$C_RED" "$C_RESET" "$label" "$rc"
    fi
    return "$rc"
}

run_task() {
    local label="$1"; shift
    log INFO "START: $label"
    "$@" > >(tee -a "$LOG_FILE") 2> >(tee -a "$LOG_FILE" >&2) &
    local pid=$!
    progress_wait "$pid" "$label"
    local rc=$?
    if (( rc == 0 )); then
        log OK "$label"
    else
        log ERROR "$label failed with exit code $rc"
    fi
    return "$rc"
}

# ─────────────────────────────────────────────
#  SECTION BANNER  (used by sub-menus)
# ─────────────────────────────────────────────
section_header() {
    local title="$1"
    echo
    printf '  %s%s%s\n' "$C_GREEN$C_BOLD" "$title" "$C_RESET"
    printf '  %s────────────────────────────────────────────%s\n' "$C_DIM" "$C_RESET"
    echo
}

# ─────────────────────────────────────────────
#  SERVICE HELPERS
# ─────────────────────────────────────────────
service_action() {
    local service="$1" action="$2"
    need_root || return 1
    systemctl list-unit-files "${service}.service" --no-legend 2>/dev/null |
        grep -q "^${service}\.service" || {
            log WARN "Service ${service} is not installed."
            return 1
        }
    run_task "systemctl $action $service" systemctl "$action" "$service"
    systemctl --no-pager --full status "$service" 2>&1 | head -n 12 || true
}

# ─────────────────────────────────────────────
#  DATABASE DETECTION
# ─────────────────────────────────────────────
detect_db() {
    DB_NAME=""; DB_USER=""; DB_PASS=""
    local envfile="$PANEL_DIR/.env"
    [[ -r "$envfile" ]] || return 1
    DB_NAME="$(sed -n 's/^DB_DATABASE=//p' "$envfile" | tail -n1 | tr -d '\r' | sed "s/^[\"']//;s/[\"']$//")"
    DB_USER="$(sed -n 's/^DB_USERNAME=//p' "$envfile" | tail -n1 | tr -d '\r' | sed "s/^[\"']//;s/[\"']$//")"
    DB_PASS="$(sed -n 's/^DB_PASSWORD=//p' "$envfile" | tail -n1 | tr -d '\r' | sed "s/^[\"']//;s/[\"']$//")"
    [[ -n "$DB_NAME" && -n "$DB_USER" ]]
}

# ─────────────────────────────────────────────
#  BLUEPRINT LISTING
# ─────────────────────────────────────────────
show_blueprints() {
    header
    section_header "Blueprint — Installation Overview"
    cat <<'BLUEPRINT'
  This toolkit can fully automate Panel + Wings on a fresh Ubuntu 22.04/24.04 server.
  Below is what each automated install option does:

  ┌─────────────────────────────────────────────────────────────────┐
  │  OPTION 2  ─  Full Panel Auto-Install                           │
  │                                                                 │
  │  Step 1   Add Ondřej PHP PPA + Redis repo, apt update           │
  │  Step 2   Install PHP 8.3 + extensions, MariaDB, NGINX, Redis   │
  │  Step 3   Install Composer v2                                   │
  │  Step 4   Create database + user in MariaDB                     │
  │  Step 5   Download panel.tar.gz from GitHub (latest)            │
  │  Step 6   Run Composer install (no-dev, optimized)              │
  │  Step 7   Generate APP_KEY, run p:environment:setup             │
  │  Step 8   Run migrations + seed                                 │
  │  Step 9   Create admin user (interactive)                       │
  │  Step 10  Set file ownership (www-data)                         │
  │  Step 11  Install pteroq.service (queue worker)                 │
  │  Step 12  Add cron job for artisan schedule:run                 │
  │  Step 13  Obtain Let's Encrypt cert (certbot)                   │
  │  Step 14  Write NGINX config from official template             │
  │  Step 15  Enable + restart NGINX                                │
  └─────────────────────────────────────────────────────────────────┘

  ┌─────────────────────────────────────────────────────────────────┐
  │  OPTION 3  ─  Full Wings Auto-Install                           │
  │                                                                 │
  │  Step 1   Install Docker CE (get.docker.com stable channel)     │
  │  Step 2   Enable + start docker service                         │
  │  Step 3   Download wings binary (amd64 or arm64 auto-detect)    │
  │  Step 4   chmod +x wings binary                                 │
  │  Step 5   Write wings.service systemd unit                      │
  │  Step 6   systemctl daemon-reload + enable wings                │
  │  Note:    You must paste config.yml from Panel node page        │
  │           before starting Wings (Step 7 prompts you)            │
  └─────────────────────────────────────────────────────────────────┘

  ┌─────────────────────────────────────────────────────────────────┐
  │  OPTION 1  ─  Dependencies Only                                 │
  │                                                                 │
  │  Installs: curl, ca-certificates, tar, gzip, xz-utils,         │
  │            rsync, mariadb-client, nginx, php-cli                │
  │  Does NOT configure Panel or Wings.                             │
  └─────────────────────────────────────────────────────────────────┘

  Required before Panel install:
    • A domain name pointing to this server (DNS A record)
    • Ports 80, 443, 8080, 8443, 2022 open in firewall

BLUEPRINT
    pause
}

# ─────────────────────────────────────────────
#  1-3  INSTALL / SETUP
# ─────────────────────────────────────────────
install_dependencies() {
    need_root || return
    section_header "Install Basic Dependencies"
    printf '  %s▶%s Check Ubuntu version\n'               "$C_CYAN" "$C_RESET"
    printf '  %s▶%s Add PHP + Redis repos\n'              "$C_CYAN" "$C_RESET"
    printf '  %s▶%s Install base packages\n'              "$C_CYAN" "$C_RESET"
    echo
    supported_os || { log ERROR "Supported OS: Ubuntu 22.04 or 24.04 only."; return 1; }
    confirm INSTALL "Install/update basic system dependencies?" || return
    export DEBIAN_FRONTEND=noninteractive

    run_task "Refresh apt package lists" apt-get update || return
    run_task "Install base tools" \
        apt-get install -y curl ca-certificates tar gzip xz-utils \
        rsync mariadb-client nginx php-cli software-properties-common \
        apt-transport-https gnupg || return
    log OK "Basic dependencies installed."
}

# ─── PANEL FULL AUTO-INSTALL ───────────────────
install_panel_guided() {
    need_root || return
    supported_os || { log ERROR "Ubuntu 22.04/24.04 required."; return 1; }

    if panel_installed; then
        header
        section_header "Panel Already Installed"
        log WARN "Panel files already exist at $PANEL_DIR."
        log INFO "Use option 11 (Update Panel) to update, or option 12 (Remove Panel) to uninstall."
        return
    fi

    # ── Gather inputs ──────────────────────────
    header
    section_header "Panel Auto-Install — Setup"
    printf '  %sThis will fully install Pterodactyl Panel on this machine.%s\n\n' "$C_YELLOW" "$C_RESET"

    while [[ -z "$DOMAIN" ]]; do
        read -r -p "  Panel domain (e.g. panel.example.com): " DOMAIN
        [[ -z "$DOMAIN" ]] && log WARN "Domain cannot be empty."
    done

    printf '  %s▶%s Use SSL / Let'\''s Encrypt? (requires domain to resolve here)\n' "$C_CYAN" "$C_RESET"
    read -r -p "  Use SSL? [Y/n]: " ssl_ans
    [[ "${ssl_ans,,}" == "n" ]] && USE_SSL="no" || USE_SSL="yes"

    read -r -p "  Database name [$PANEL_DB_NAME]: " _in
    [[ -n "$_in" ]] && PANEL_DB_NAME="$_in"

    read -r -p "  Database user [$PANEL_DB_USER]: " _in
    [[ -n "$_in" ]] && PANEL_DB_USER="$_in"

    while [[ -z "$PANEL_DB_PASS" ]]; do
        read -r -s -p "  Database password (leave empty to auto-generate): " PANEL_DB_PASS; echo
        [[ -z "$PANEL_DB_PASS" ]] && PANEL_DB_PASS="$(tr -dc 'A-Za-z0-9!@#%^&*' </dev/urandom | head -c 24)"
    done

    while [[ -z "$ADMIN_EMAIL" ]]; do
        read -r -p "  Admin e-mail: " ADMIN_EMAIL
        [[ -z "$ADMIN_EMAIL" ]] && log WARN "Email cannot be empty."
    done

    while [[ -z "$ADMIN_USER" ]]; do
        read -r -p "  Admin username: " ADMIN_USER
        [[ -z "$ADMIN_USER" ]] && log WARN "Username cannot be empty."
    done

    read -r -p "  Admin first name [Admin]: " ADMIN_FIRST
    [[ -z "$ADMIN_FIRST" ]] && ADMIN_FIRST="Admin"
    read -r -p "  Admin last name [User]: " ADMIN_LAST
    [[ -z "$ADMIN_LAST" ]] && ADMIN_LAST="User"

    while [[ -z "$ADMIN_PASS" ]]; do
        read -r -s -p "  Admin password: " ADMIN_PASS; echo
        [[ -z "$ADMIN_PASS" ]] && log WARN "Password cannot be empty."
    done

    echo
    log INFO "Starting automated Panel installation..."
    echo

    export DEBIAN_FRONTEND=noninteractive

    # ── 1. PHP PPA + Redis repo ────────────────
    run_task "Add Ondrej PHP PPA" \
        bash -c 'LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php' || return 1

    run_task "Add Redis official repo" \
        bash -c '
            curl -fsSL https://packages.redis.io/gpg | gpg --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg
            echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $(lsb_release -cs) main" \
                | tee /etc/apt/sources.list.d/redis.list
        ' || return 1

    run_task "apt update" apt-get update || return 1

    # ── 2. Install packages ────────────────────
    run_task "Install PHP 8.3 + extensions, MariaDB, NGINX, Redis" \
        apt-get install -y \
            php8.3 php8.3-common php8.3-cli php8.3-gd php8.3-mysql \
            php8.3-mbstring php8.3-bcmath php8.3-xml php8.3-fpm \
            php8.3-curl php8.3-zip \
            mariadb-server nginx tar unzip git redis-server curl || return 1

    # ── 3. Composer v2 ────────────────────────
    if ! command -v composer >/dev/null 2>&1; then
        run_task "Install Composer v2" \
            bash -c 'curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer' || return 1
    else
        log OK "Composer already installed: $(composer --version 2>/dev/null | head -n1)"
    fi

    # ── 4. MariaDB setup ──────────────────────
    run_task "Start MariaDB" systemctl enable --now mariadb || return 1
    run_task "Create panel database + user" \
        bash -c "mysql -e \"
            CREATE USER IF NOT EXISTS '${PANEL_DB_USER}'@'127.0.0.1' IDENTIFIED BY '${PANEL_DB_PASS}';
            CREATE DATABASE IF NOT EXISTS \`${PANEL_DB_NAME}\`;
            GRANT ALL PRIVILEGES ON \`${PANEL_DB_NAME}\`.* TO '${PANEL_DB_USER}'@'127.0.0.1' WITH GRANT OPTION;
            FLUSH PRIVILEGES;
        \"" || return 1

    # ── 5. Download Panel files ────────────────
    run_task "Create panel directory" mkdir -p "$PANEL_DIR" || return 1
    run_task "Download panel.tar.gz" \
        bash -c "cd ${PANEL_DIR} && curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz" || return 1
    run_task "Extract panel archive" \
        bash -c "cd ${PANEL_DIR} && tar -xzvf panel.tar.gz && rm -f panel.tar.gz" || return 1
    run_task "Set storage permissions" \
        bash -c "chmod -R 755 ${PANEL_DIR}/storage/* ${PANEL_DIR}/bootstrap/cache/" || return 1

    # ── 6. .env + Composer install ────────────
    run_task "Copy .env.example" bash -c "cd ${PANEL_DIR} && cp .env.example .env" || return 1
    run_task "Composer install (no-dev, optimized)" \
        bash -c "cd ${PANEL_DIR} && COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader" || return 1

    # ── 7. Artisan setup ──────────────────────
    run_task "Generate APP_KEY" bash -c "cd ${PANEL_DIR} && php artisan key:generate --force" || return 1

    run_task "Configure environment (non-interactive)" \
        bash -c "cd ${PANEL_DIR} && php artisan p:environment:setup \
            --author='${ADMIN_EMAIL}' \
            --url='http${USE_SSL:+s}://${DOMAIN}' \
            --timezone='UTC' \
            --cache='redis' \
            --session='redis' \
            --queue='redis' \
            --redis-host='127.0.0.1' \
            --redis-pass='null' \
            --redis-port='6379'" || return 1

    run_task "Configure database (non-interactive)" \
        bash -c "cd ${PANEL_DIR} && php artisan p:environment:database \
            --host='127.0.0.1' \
            --port='3306' \
            --database='${PANEL_DB_NAME}' \
            --username='${PANEL_DB_USER}' \
            --password='${PANEL_DB_PASS}'" || return 1

    # ── 8. Migrate + seed ─────────────────────
    run_task "Run database migrations + seed" \
        bash -c "cd ${PANEL_DIR} && php artisan migrate --seed --force" || return 1

    # ── 9. Create admin user ──────────────────
    log INFO "Creating admin user..."
    (cd "$PANEL_DIR" && php artisan p:user:make \
        --email="$ADMIN_EMAIL" \
        --username="$ADMIN_USER" \
        --name-first="$ADMIN_FIRST" \
        --name-last="$ADMIN_LAST" \
        --password="$ADMIN_PASS" \
        --admin=1) || log WARN "Admin user creation failed — run manually: php artisan p:user:make"

    # ── 10. File ownership ────────────────────
    run_task "Set file ownership (www-data)" \
        chown -R www-data:www-data "$PANEL_DIR/" || return 1

    # ── 11. pteroq queue worker service ───────
    cat > "$PTEROQ_SERVICE" <<'PTEROQ'
[Unit]
Description=Pterodactyl Queue Worker
After=redis-server.service

[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php /var/www/pterodactyl/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
PTEROQ
    run_task "Enable pteroq.service" \
        bash -c 'systemctl daemon-reload && systemctl enable --now pteroq.service' || return 1

    # ── 12. Cron job ──────────────────────────
    local cron_line="* * * * * php /var/www/pterodactyl/artisan schedule:run >> /dev/null 2>&1"
    if ! crontab -l 2>/dev/null | grep -qF "pterodactyl/artisan schedule:run"; then
        (crontab -l 2>/dev/null; echo "$cron_line") | crontab -
        log OK "Cron job added for artisan schedule:run"
    else
        log OK "Cron job already present"
    fi

    # ── 13. SSL / certbot ─────────────────────
    if [[ "$USE_SSL" == "yes" ]]; then
        if ! command -v certbot >/dev/null 2>&1; then
            run_task "Install certbot" \
                apt-get install -y certbot python3-certbot-nginx || return 1
        fi
        log INFO "Obtaining Let's Encrypt certificate for $DOMAIN ..."
        certbot certonly --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$ADMIN_EMAIL" || {
            log WARN "certbot failed — continuing without SSL. Re-run certbot manually."
            USE_SSL="no"
        }
    fi

    # ── 14. NGINX config ──────────────────────
    rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
    local nginx_conf="/etc/nginx/sites-available/pterodactyl.conf"
    local php_sock="/run/php/php8.3-fpm.sock"

    if [[ "$USE_SSL" == "yes" ]]; then
        cat > "$nginx_conf" <<NGINXSSL
server {
    listen 80;
    server_name ${DOMAIN};
    return 301 https://\$server_name\$request_uri;
}
server {
    listen 443 ssl http2;
    server_name ${DOMAIN};

    root /var/www/pterodactyl/public;
    index index.php;

    access_log /var/log/nginx/pterodactyl.app-access.log;
    error_log  /var/log/nginx/pterodactyl.app-error.log error;

    client_max_body_size 100m;
    client_body_timeout 120s;
    sendfile off;

    ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_session_cache   shared:SSL:10m;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384";
    ssl_prefer_server_ciphers on;

    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";
    add_header X-Robots-Tag none;
    add_header Content-Security-Policy "frame-ancestors 'self'";
    add_header X-Frame-Options DENY;
    add_header Referrer-Policy same-origin;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }
    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass unix:${php_sock};
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize = 100M \n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
        fastcgi_intercept_errors off;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
        fastcgi_connect_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
        include /etc/nginx/fastcgi_params;
    }
    location ~ /\.ht { deny all; }
}
NGINXSSL
    else
        cat > "$nginx_conf" <<NGINXNOSSL
server {
    listen 80;
    server_name ${DOMAIN};

    root /var/www/pterodactyl/public;
    index index.html index.htm index.php;
    charset utf-8;

    access_log off;
    error_log /var/log/nginx/pterodactyl.app-error.log error;

    client_max_body_size 100m;
    client_body_timeout 120s;
    sendfile off;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }
    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }
    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass unix:${php_sock};
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize = 100M \n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
        fastcgi_intercept_errors off;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
        fastcgi_connect_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
    }
    location ~ /\.ht { deny all; }
}
NGINXNOSSL
    fi

    ln -sf "$nginx_conf" /etc/nginx/sites-enabled/pterodactyl.conf
    run_task "Test NGINX config" nginx -t || {
        log ERROR "NGINX config test failed. Check $nginx_conf"
        return 1
    }
    run_task "Restart NGINX" systemctl restart nginx || return 1

    # ── Done ──────────────────────────────────
    echo
    printf '  %s════════════════════════════════════════════%s\n' "$C_GREEN" "$C_RESET"
    printf '  %s✔  Panel installation complete!%s\n' "$C_GREEN$C_BOLD" "$C_RESET"
    printf '  %s════════════════════════════════════════════%s\n' "$C_GREEN" "$C_RESET"
    echo
    printf '  URL:      %shttp%s://%s%s\n' "$C_CYAN" "$([ "$USE_SSL" == "yes" ] && echo s)" "$DOMAIN" "$C_RESET"
    printf '  Username: %s%s%s\n' "$C_BOLD" "$ADMIN_USER" "$C_RESET"
    printf '  DB Pass:  %s%s%s\n' "$C_BOLD" "$PANEL_DB_PASS" "$C_RESET"
    printf '\n  %s⚠  Save the DB password above — it will not be shown again.%s\n' "$C_YELLOW" "$C_RESET"
    printf '  %s⚠  Install Wings next (option 3) to run game servers.%s\n\n' "$C_YELLOW" "$C_RESET"
    log OK "Panel install finished. APP_KEY is in ${PANEL_DIR}/.env — back it up!"
}

# ─── WINGS FULL AUTO-INSTALL ───────────────────
install_wings_guided() {
    need_root || return
    supported_os || { log ERROR "Ubuntu 22.04/24.04 required."; return 1; }

    if wings_installed; then
        header
        section_header "Wings Already Installed"
        log WARN "Wings appears to be installed. Use service controls (option 4) to manage it."
        log INFO "If you need to reinstall, use option 13 (Remove Wings) first."
        return
    fi

    header
    section_header "Wings Auto-Install"
    printf '  %sThis will install Docker and the Wings daemon.%s\n\n' "$C_YELLOW" "$C_RESET"
    log INFO "Wings needs a Panel node configuration to start. You will be prompted to paste it."
    echo
    confirm INSTALL "Install Wings (Docker + daemon + service)?" || return

    export DEBIAN_FRONTEND=noninteractive

    # ── 1. Docker ─────────────────────────────
    if ! command -v docker >/dev/null 2>&1; then
        run_task "Download Docker install script" \
            bash -c 'curl -fsSL https://get.docker.com -o /tmp/get-docker.sh' || return 1
        run_task "Install Docker CE (stable)" \
            bash -c 'CHANNEL=stable sh /tmp/get-docker.sh' || return 1
        rm -f /tmp/get-docker.sh
    else
        log OK "Docker already installed: $(docker --version 2>/dev/null)"
    fi
    run_task "Enable + start Docker service" \
        systemctl enable --now docker || return 1

    # ── 2. Wings binary (arch-aware) ──────────
    local arch
    arch="$([[ "$(uname -m)" == "x86_64" ]] && echo "amd64" || echo "arm64")"
    log INFO "Detected architecture: $arch"

    run_task "Create /etc/pterodactyl directory" \
        mkdir -p /etc/pterodactyl || return 1
    run_task "Download Wings binary ($arch)" \
        bash -c "curl -L -o /usr/local/bin/wings \
            https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_${arch}" || return 1
    run_task "Set wings executable" \
        chmod u+x /usr/local/bin/wings || return 1

    # ── 3. Systemd service ────────────────────
    cat > "$WINGS_SERVICE" <<'WINGSVC'
[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service
Requires=docker.service
PartOf=docker.service

[Service]
User=root
WorkingDirectory=/etc/pterodactyl
LimitNOFILE=4096
PIDFile=/var/run/wings/daemon.pid
ExecStart=/usr/local/bin/wings
Restart=on-failure
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
WINGSVC

    run_task "Reload systemd" systemctl daemon-reload || return 1

    # ── 4. Prompt for config.yml ──────────────
    echo
    printf '  %s══════════════════════════════════════════════%s\n' "$C_YELLOW" "$C_RESET"
    printf '  %s  ACTION REQUIRED — Paste config.yml%s\n' "$C_YELLOW$C_BOLD" "$C_RESET"
    printf '  %s══════════════════════════════════════════════%s\n\n' "$C_YELLOW" "$C_RESET"
    printf '  In your Panel admin area:\n'
    printf '  1. Go to Admin → Nodes → [your node] → Configuration tab\n'
    printf '  2. Copy the entire config block\n'
    printf '  3. Paste it below (then press Enter, then Ctrl+D)\n\n'

    if [[ ! -f "$WINGS_CONFIG" ]]; then
        printf '  %sPaste config.yml content (Ctrl+D when done):%s\n' "$C_CYAN" "$C_RESET"
        cat > "$WINGS_CONFIG" || {
            log ERROR "Failed to write $WINGS_CONFIG"
            return 1
        }
        chmod 600 "$WINGS_CONFIG"
        log OK "config.yml written to $WINGS_CONFIG"
    else
        log WARN "config.yml already exists at $WINGS_CONFIG — skipping paste."
    fi

    # ── 5. Test Wings before enabling ─────────
    log INFO "Testing Wings in debug mode (30 s timeout)..."
    timeout 30 /usr/local/bin/wings --debug 2>&1 | head -n 20 || true
    echo

    run_task "Enable + start wings.service" \
        bash -c 'systemctl enable --now wings' || {
        log ERROR "Wings failed to start. Check: journalctl -u wings -n 50"
        return 1
    }

    echo
    printf '  %s════════════════════════════════════════════%s\n' "$C_GREEN" "$C_RESET"
    printf '  %s✔  Wings installation complete!%s\n' "$C_GREEN$C_BOLD" "$C_RESET"
    printf '  %s════════════════════════════════════════════%s\n' "$C_GREEN" "$C_RESET"
    echo
    printf '  Check status:  %ssystemctl status wings%s\n' "$C_CYAN" "$C_RESET"
    printf '  View logs:     %sjournalctl -u wings -n 50%s\n' "$C_CYAN" "$C_RESET"
    printf '\n  %s⚠  Open ports 8080, 8443, 2022 in your firewall!%s\n\n' "$C_YELLOW" "$C_RESET"
    log OK "Wings install finished."
}

# ─────────────────────────────────────────────
#  4  SERVICE CONTROLS
# ─────────────────────────────────────────────
service_menu() {
    header
    section_header "Service Controls"
    echo "  [1]  Panel queue worker  (pteroq)"
    echo "  [2]  Web server          (nginx)"
    echo "  [3]  Database            (mariadb)"
    echo "  [4]  Cache               (redis-server)"
    echo "  [5]  Wings"
    echo "  [6]  Docker"
    echo
    read -r -p "  Select service: " n
    local service
    case "$n" in
        1) service="pteroq"       ;;
        2) service="nginx"        ;;
        3) service="mariadb"      ;;
        4) service="redis-server" ;;
        5) service="wings"        ;;
        6) service="docker"       ;;
        *) log ERROR "Invalid selection."; return 1 ;;
    esac
    echo
    echo "  [1] Status   [2] Start   [3] Stop   [4] Restart"
    echo
    read -r -p "  Select action: " a
    case "$a" in
        1) section_header "Service Status — $service"
           printf '  %s▶%s systemctl status %s\n' "$C_CYAN" "$C_RESET" "$service"
           echo
           systemctl status "$service" --no-pager ;;
        2) section_header "Start Services"
           printf '  %s▶%s Start %s\n' "$C_CYAN" "$C_RESET" "$service"
           echo
           service_action "$service" start ;;
        3) section_header "Stop Services"
           printf '  %s▶%s Stop %s\n' "$C_CYAN" "$C_RESET" "$service"
           echo
           confirm STOP "Stop $service? This may interrupt services." || return
           service_action "$service" stop ;;
        4) section_header "Restart Services"
           printf '  %s▶%s Restart %s\n' "$C_CYAN" "$C_RESET" "$service"
           echo
           confirm RESTART "Restart $service? This may cause downtime." || return
           service_action "$service" restart ;;
        *) log ERROR "Invalid action."; return 1 ;;
    esac
}

# ─────────────────────────────────────────────
#  5  DIAGNOSTICS
# ─────────────────────────────────────────────
diagnostics() {
    header
    section_header "Diagnostics"
    printf '  %s▶%s Check operating system\n'          "$C_CYAN" "$C_RESET"
    printf '  %s▶%s Check disk and memory\n'           "$C_CYAN" "$C_RESET"
    printf '  %s▶%s Check ports and networking\n'      "$C_CYAN" "$C_RESET"
    printf '  %s▶%s Check Docker and service health\n' "$C_CYAN" "$C_RESET"
    echo

    printf '  %s── SYSTEM ─────────────────────────────────%s\n' "$C_DIM" "$C_RESET"
    printf '  OS:     %s\n' "$(. /etc/os-release; echo "${PRETTY_NAME:-unknown}")"
    printf '  Kernel: %s\n' "$(uname -r)"
    printf '  Uptime: %s\n' "$(uptime -p 2>/dev/null || uptime)"
    echo
    printf '  %s── DISK ────────────────────────────────────%s\n' "$C_DIM" "$C_RESET"
    df -h / /var 2>/dev/null || true
    echo
    printf '  %s── MEMORY ──────────────────────────────────%s\n' "$C_DIM" "$C_RESET"
    free -h 2>/dev/null || true
    echo
    printf '  %s── SERVICES ────────────────────────────────%s\n' "$C_DIM" "$C_RESET"
    for s in nginx apache2 mariadb mysql redis-server pteroq wings docker; do
        local st
        st="$(systemctl is-active "$s" 2>/dev/null || echo not-installed)"
        if [[ "$st" == "active" ]]; then
            printf '  %-18s %s●%s %s\n' "$s" "$C_GREEN" "$C_RESET" "$st"
        else
            printf '  %-18s %s●%s %s\n' "$s" "$C_RED"   "$C_RESET" "$st"
        fi
    done
    echo
    printf '  %s── PANEL ───────────────────────────────────%s\n' "$C_DIM" "$C_RESET"
    if panel_installed; then
        ls -ld "$PANEL_DIR"
        command -v php >/dev/null 2>&1 && php -v | head -n 1
        [[ -f "$PANEL_DIR/.env" ]] \
            && printf '  Panel .env: %spresent%s (values hidden)\n' "$C_GREEN" "$C_RESET" \
            || printf '  Panel .env: %smissing%s\n' "$C_RED" "$C_RESET"
    else
        printf '  Panel directory: %snot detected%s\n' "$C_RED" "$C_RESET"
    fi
    echo
    printf '  %s── WINGS ───────────────────────────────────%s\n' "$C_DIM" "$C_RESET"
    if [[ -f "$WINGS_CONFIG" ]]; then
        ls -l "$WINGS_CONFIG"
        command -v wings >/dev/null 2>&1 && wings version 2>&1 | head -n 3 || true
    else
        printf '  Wings config: %snot detected%s\n' "$C_RED" "$C_RESET"
    fi
    echo
    printf '  %s── LISTENING PORTS ─────────────────────────%s\n' "$C_DIM" "$C_RESET"
    command -v ss >/dev/null 2>&1 && ss -lntup 2>/dev/null | head -n 20 || true
    echo
    printf '  %s── RECENT ERRORS ───────────────────────────%s\n' "$C_DIM" "$C_RESET"
    journalctl -p err -n 15 --no-pager 2>/dev/null || true
    log INFO "Diagnostics collected"
}

# ─────────────────────────────────────────────
#  6  VIEW LOGS
# ─────────────────────────────────────────────
view_logs() {
    header
    section_header "View Logs"
    printf '  %s▶%s journalctl -u wings -n 50\n'  "$C_CYAN" "$C_RESET"
    printf '  %s▶%s journalctl -u pteroq -n 50\n' "$C_CYAN" "$C_RESET"
    echo
    echo "  [1]  SPYDR log"
    echo "  [2]  Panel queue worker  (pteroq)"
    echo "  [3]  Wings"
    echo "  [4]  Nginx"
    echo
    read -r -p "  Select log source: " c
    echo
    case "$c" in
        1) tail -n 100 "$LOG_FILE" 2>/dev/null || log WARN "Log file not found." ;;
        2) journalctl -u pteroq -n 100 --no-pager ;;
        3) journalctl -u wings  -n 100 --no-pager ;;
        4) journalctl -u nginx  -n 100 --no-pager ;;
        *) log ERROR "Invalid choice." ;;
    esac
}

# ─────────────────────────────────────────────
#  7-9  BACKUPS
# ─────────────────────────────────────────────
backup_panel() {
    need_root || return
    panel_installed || { log ERROR "Panel installation not detected."; return 1; }
    header
    section_header "Create Backup — Panel"
    printf '  %s▶%s Select backup destination\n'      "$C_CYAN" "$C_RESET"
    printf '  %s▶%s Prepare database and panel archive\n' "$C_CYAN" "$C_RESET"
    printf '  %s▶%s Review backup summary\n'           "$C_CYAN" "$C_RESET"
    echo

    local dest="$BACKUP_ROOT/panel-$(date +%Y%m%d-%H%M%S).tar.gz"
    local stage
    stage="$(mktemp -d)" || return 1
    trap 'rm -rf "$stage"' RETURN

    printf '  Destination: %s%s%s\n' "$C_BOLD" "$dest" "$C_RESET"
    log WARN "This includes Panel files (including .env) and may contain secrets."
    confirm BACKUP "Create a protected Panel backup?" || return

    if [[ -f "$PANEL_DIR/.env" ]]; then
        DB_NAME="$(sed -n 's/^DB_DATABASE=//p' "$PANEL_DIR/.env" | tail -n1 | tr -d '"' | tr -d "'")"
        DB_USER="$(sed -n 's/^DB_USERNAME=//p' "$PANEL_DIR/.env" | tail -n1 | tr -d '"' | tr -d "'")"
        DB_PASS="$(sed -n 's/^DB_PASSWORD=//p' "$PANEL_DIR/.env" | tail -n1 | sed "s/^ *//;s/ *$//;s/^\"\\(.*\\)\"$/\1/;s/^'\\(.*\\)'$/\1/")"
    fi

    if [[ -n "$DB_NAME" && -n "$DB_USER" ]]; then
        read -r -s -p "  MariaDB password for '$DB_USER' (Enter to use .env value): " prompt_pass
        echo
        local dump_pass="${prompt_pass:-$DB_PASS}"
        unset prompt_pass
        if [[ -n "$dump_pass" ]]; then
            MYSQL_PWD="$dump_pass" mysqldump --single-transaction \
                --routines --triggers -u "$DB_USER" "$DB_NAME" > "$stage/panel.sql" || {
                unset MYSQL_PWD dump_pass
                log ERROR "Database dump failed; backup aborted."
                return 1
            }
            unset MYSQL_PWD dump_pass
        else
            mysqldump --single-transaction --routines --triggers \
                -u "$DB_USER" "$DB_NAME" > "$stage/panel.sql" || return 1
        fi
    else
        log WARN "Database settings not detected; creating file-only backup."
    fi

    printf 'Backup created: %s\n' "$(date -Is)" > "$stage/backup-info.txt"
    printf 'Panel path: %s\n' "$PANEL_DIR"       >> "$stage/backup-info.txt"
    tar -czf "$dest" -C / "$PANEL_DIR" \
        -C "$stage" backup-info.txt ${DB_NAME:+panel.sql} || return 1
    chmod 600 "$dest"
    tar -tzf "$dest" >/dev/null || { rm -f "$dest"; log ERROR "Archive validation failed."; return 1; }
    LAST_BACKUP="$dest"
    log OK "Verified Panel backup: $dest"
}

backup_wings() {
    need_root || return
    [[ -d /etc/pterodactyl || -d /var/lib/pterodactyl ]] || {
        log ERROR "Wings configuration/server data not found."
        return 1
    }
    header
    section_header "Create Backup — Wings"
    printf '  %s▶%s Select backup destination\n'      "$C_CYAN" "$C_RESET"
    printf '  %s▶%s Prepare Wings archive\n'          "$C_CYAN" "$C_RESET"
    printf '  %s▶%s Review backup summary\n'          "$C_CYAN" "$C_RESET"
    echo

    local dest="$BACKUP_ROOT/wings-$(date +%Y%m%d-%H%M%S).tar.gz"
    confirm BACKUP "Back up Wings config and server data? This can be very large." || return
    local paths=()
    [[ -d /etc/pterodactyl ]] && paths+=(etc/pterodactyl)
    [[ -d /var/lib/pterodactyl ]] && paths+=(var/lib/pterodactyl)
    [[ -f /etc/systemd/system/wings.service ]] && paths+=(etc/systemd/system/wings.service)
    tar -czf "$dest" -C / "${paths[@]}" || return 1
    chmod 600 "$dest"
    tar -tzf "$dest" >/dev/null || { rm -f "$dest"; return 1; }
    LAST_BACKUP="$dest"
    log OK "Verified Wings backup: $dest"
}

list_backups() {
    header
    section_header "Available Backups"
    printf '  Directory: %s%s%s\n\n' "$C_BOLD" "$BACKUP_ROOT" "$C_RESET"
    local count=0
    while IFS= read -r line; do
        printf '  %s▸%s %s\n' "$C_CYAN" "$C_RESET" "$line"
        (( count++ ))
    done < <(find "$BACKUP_ROOT" -maxdepth 1 -type f -name '*.tar.gz' \
        -printf '%TY-%Tm-%Td %TH:%TM  %10s bytes  %f\n' 2>/dev/null | sort -r || true)
    (( count == 0 )) && log WARN "No backups found in $BACKUP_ROOT"
}

# ─────────────────────────────────────────────
#  10  RESTORE
# ─────────────────────────────────────────────
restore_backup() {
    need_root || return
    header
    section_header "Restore Backup"
    printf '  %s▶%s List available backups\n'        "$C_CYAN" "$C_RESET"
    printf '  %s▶%s Validate selected archive\n'     "$C_CYAN" "$C_RESET"
    printf '  %s▶%s Request restore confirmation\n'  "$C_CYAN" "$C_RESET"
    echo

    list_backups
    echo
    read -r -p "  Full path to backup archive: " src
    [[ -f "$src" ]] || { log ERROR "File not found."; return 1; }
    tar -tzf "$src" >/dev/null || { log ERROR "Invalid archive."; return 1; }
    log WARN "Restoration overwrites files and can replace live configuration."
    confirm RESTORE "Restore this archive?" || return

    local stage
    stage="$(mktemp -d)" || return 1
    trap 'rm -rf "$stage"' RETURN
    tar -xzf "$src" -C "$stage" || return 1

    if [[ "$src" == *"/panel-"* ]]; then
        [[ -d "$stage/$PANEL_DIR" ]] || { log ERROR "Panel directory missing from archive."; return 1; }
        rsync -a --delete "$stage/$PANEL_DIR/" "$PANEL_DIR/" || return 1
        if [[ -f "$stage/panel.sql" ]]; then
            log WARN "Database dump found. Import manually after verifying the target DB."
            log INFO "Dump path: $stage/panel.sql (temporary; removed when this action ends)."
            read -r -p "  Press Enter after reviewing this warning..." _
        fi
        log OK "Panel files restored. Review ownership, .env, and database state before restarting."
    elif [[ "$src" == *"/wings-"* ]]; then
        confirm RESTORE "Wings restore can overwrite server data. Continue?" || return
        rsync -a "$stage/etc/pterodactyl/" /etc/pterodactyl/ 2>/dev/null || true
        if [[ -d "$stage/var/lib/pterodactyl" ]]; then
            rsync -a "$stage/var/lib/pterodactyl/" /var/lib/pterodactyl/ || return 1
        fi
        systemctl daemon-reload
        log OK "Wings files restored. Check config and node connectivity before starting."
    else
        log ERROR "Backup filename must include /panel- or /wings- to select restore type."
        return 1
    fi
}

# ─────────────────────────────────────────────
#  UPDATE PANEL + WINGS
# ─────────────────────────────────────────────
update_panel() {
    need_root || return
    panel_installed || { log ERROR "Panel not detected at $PANEL_DIR."; return 1; }
    header
    section_header "Update Panel"
    printf '  %s▶%s Check current version\n'         "$C_CYAN" "$C_RESET"
    printf '  %s▶%s Enter maintenance mode\n'        "$C_CYAN" "$C_RESET"
    printf '  %s▶%s Download + extract latest\n'     "$C_CYAN" "$C_RESET"
    printf '  %s▶%s Run migrations, clear cache\n'   "$C_CYAN" "$C_RESET"
    printf '  %s▶%s Restore + exit maintenance\n'    "$C_CYAN" "$C_RESET"
    echo

    log INFO "Current Panel version:"
    (cd "$PANEL_DIR" && php artisan --version 2>/dev/null) || true
    echo

    log WARN "Always back up before updating. Run option 7 first if you haven't."
    confirm UPDATE "Update Panel to latest release?" || return

    export DEBIAN_FRONTEND=noninteractive

    # ── Enter maintenance mode ─────────────────
    run_task "Enter maintenance mode" \
        bash -c "cd ${PANEL_DIR} && php artisan down" || return 1

    # ── Download + extract ─────────────────────
    run_task "Download latest panel.tar.gz" \
        bash -c "cd ${PANEL_DIR} && curl -L https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz | tar -xzv" || {
        (cd "$PANEL_DIR" && php artisan up) 2>/dev/null || true
        return 1
    }

    # ── Permissions + Composer ─────────────────
    run_task "Fix storage permissions" \
        bash -c "chmod -R 755 ${PANEL_DIR}/storage/* ${PANEL_DIR}/bootstrap/cache/" || true
    run_task "Composer install (no-dev, optimized)" \
        bash -c "cd ${PANEL_DIR} && COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader" || {
        (cd "$PANEL_DIR" && php artisan up) 2>/dev/null || true
        return 1
    }

    # ── Clear cache ────────────────────────────
    run_task "Clear view cache"   bash -c "cd ${PANEL_DIR} && php artisan view:clear"   || true
    run_task "Clear config cache" bash -c "cd ${PANEL_DIR} && php artisan config:clear" || true

    # ── Migrate ────────────────────────────────
    run_task "Run database migrations + seed" \
        bash -c "cd ${PANEL_DIR} && php artisan migrate --seed --force" || {
        (cd "$PANEL_DIR" && php artisan up) 2>/dev/null || true
        return 1
    }

    # ── Ownership ─────────────────────────────
    run_task "Fix file ownership (www-data)" \
        chown -R www-data:www-data "$PANEL_DIR/" || true

    # ── Restart queue + exit maintenance ──────
    run_task "Restart queue worker" \
        bash -c "cd ${PANEL_DIR} && php artisan queue:restart" || true
    run_task "Exit maintenance mode" \
        bash -c "cd ${PANEL_DIR} && php artisan up" || return 1

    log OK "Panel updated successfully."
    log INFO "New version:"
    (cd "$PANEL_DIR" && php artisan --version 2>/dev/null) || true
}

update_wings() {
    need_root || return
    wings_installed || { log ERROR "Wings not detected."; return 1; }
    header
    section_header "Update Wings"
    printf '  %s▶%s Stop wings service\n'            "$C_CYAN" "$C_RESET"
    printf '  %s▶%s Download latest binary\n'        "$C_CYAN" "$C_RESET"
    printf '  %s▶%s Restart wings service\n'         "$C_CYAN" "$C_RESET"
    echo

    log INFO "Current Wings version:"
    /usr/local/bin/wings version 2>/dev/null || true
    echo
    confirm UPDATE "Update Wings to latest release?" || return

    local arch
    arch="$([[ "$(uname -m)" == "x86_64" ]] && echo "amd64" || echo "arm64")"

    run_task "Stop wings.service" systemctl stop wings || true
    run_task "Download Wings binary ($arch)" \
        bash -c "curl -L -o /usr/local/bin/wings \
            https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_${arch}" || return 1
    run_task "Set wings executable" chmod u+x /usr/local/bin/wings || return 1
    run_task "Restart wings.service" systemctl restart wings || return 1

    log OK "Wings updated."
    log INFO "New version:"
    /usr/local/bin/wings version 2>/dev/null || true
}

# ─────────────────────────────────────────────
#  11-12  REMOVAL
# ─────────────────────────────────────────────
remove_panel() {
    need_root || return
    panel_installed || { log WARN "Panel not detected at $PANEL_DIR."; return 1; }
    header
    section_header "Uninstall / Remove — Panel"
    printf '  %s▶%s Detect installed components\n'  "$C_CYAN" "$C_RESET"
    printf '  %s▶%s Show removal plan\n'             "$C_CYAN" "$C_RESET"
    printf '  %s▶%s Require explicit confirmation\n' "$C_CYAN" "$C_RESET"
    echo
    log WARN "This removes Panel files and the pteroq service, not the database or web server."
    log WARN "Create a Panel backup first. Database deletion is deliberately not automatic."
    confirm REMOVE-PANEL "Permanently remove Panel files?" || return
    systemctl stop pteroq 2>/dev/null || true
    local dest="$BACKUP_ROOT/pre-removal-panel-$(date +%Y%m%d-%H%M%S).tar.gz"
    tar -czf "$dest" -C / "$PANEL_DIR" || { log ERROR "Automatic safety backup failed; refusing removal."; return 1; }
    chmod 600 "$dest"
    tar -tzf "$dest" >/dev/null || return 1
    rm -rf -- "$PANEL_DIR"
    log WARN "Panel files removed. Safety backup: $dest"
    log WARN "Database, nginx, PHP, Redis and certificates were retained."
}

remove_wings() {
    need_root || return
    wings_installed || { log WARN "Wings not detected."; return 1; }
    header
    section_header "Uninstall / Remove — Wings"
    printf '  %s▶%s Detect installed components\n'  "$C_CYAN" "$C_RESET"
    printf '  %s▶%s Show removal plan\n'             "$C_CYAN" "$C_RESET"
    printf '  %s▶%s Require explicit confirmation\n' "$C_CYAN" "$C_RESET"
    echo
    log WARN "This stops Wings and removes its binary, service, and configuration."
    log WARN "Server data in /var/lib/pterodactyl will be retained."
    confirm REMOVE-WINGS "Remove Wings binary/service/config?" || return
    local dest="$BACKUP_ROOT/pre-removal-wings-$(date +%Y%m%d-%H%M%S).tar.gz"
    local paths=()
    [[ -d /etc/pterodactyl ]] && paths+=(etc/pterodactyl)
    [[ -f /etc/systemd/system/wings.service ]] && paths+=(etc/systemd/system/wings.service)
    [[ -x /usr/local/bin/wings ]] && paths+=(usr/local/bin/wings)
    (( ${#paths[@]} )) || { log ERROR "Nothing to back up."; return 1; }
    tar -czf "$dest" -C / "${paths[@]}" || return 1
    tar -tzf "$dest" >/dev/null || return 1
    systemctl disable --now wings 2>/dev/null || true
    rm -f /usr/local/bin/wings /etc/systemd/system/wings.service
    rm -rf /etc/pterodactyl
    systemctl daemon-reload
    log WARN "Wings removed. Server data retained. Backup: $dest"
}

# ─────────────────────────────────────────────
#  ADMIN / USER MANAGEMENT
# ─────────────────────────────────────────────

# Require Panel to be installed before any user management
_require_panel() {
    panel_installed || { log ERROR "Panel not installed at $PANEL_DIR."; return 1; }
    command -v php >/dev/null 2>&1 || { log ERROR "PHP not found."; return 1; }
}

# Pretty-print the raw artisan p:user:list output with colour
_list_users() {
    section_header "All Panel Users"
    printf '  %s%-5s %-30s %-20s %-10s%s\n' \
        "$C_BOLD" "ID" "Email" "Username" "Admin?" "$C_RESET"
    printf '  %s%s%s\n' "$C_DIM" "$(printf '─%.0s' {1..65})" "$C_RESET"
    # artisan outputs a table; parse lines that start with │
    (cd "$PANEL_DIR" && php artisan p:user:list 2>/dev/null) | \
        grep -E '^\s*\|' | \
        grep -v -E '(Email|^[\s|─]+$)' | \
        while IFS='|' read -r _ id email username _admin _rest; do
            id="${id// /}"
            email="${email// /}"
            username="${username// /}"
            _admin="${_admin// /}"
            [[ -z "$id" ]] && continue
            if [[ "$_admin" == "1" || "$_admin" == "yes" || "$_admin" == "true" ]]; then
                printf '  %s%-5s %-30s %-20s %s●  yes%s\n' \
                    "$C_GREEN" "$id" "$email" "$username" "$C_GREEN" "$C_RESET"
            else
                printf '  %-5s %-30s %-20s %s●%s  no\n' \
                    "$id" "$email" "$username" "$C_DIM" "$C_RESET"
            fi
        done || true
    echo
}

admin_menu() {
    _require_panel || return
    while true; do
        header
        section_header "User / Admin Management"
        echo "  [1]  List all users"
        echo "  [2]  Create new user"
        echo "  [3]  Promote user to admin"
        echo "  [4]  Demote admin to regular user"
        echo "  [5]  Reset user password"
        echo "  [6]  Delete user"
        echo "  [0]  Back to main menu"
        echo
        printf '  %s────────────────────────────────────────────%s\n' "$C_DIM" "$C_RESET"
        printf '  Select an option: '
        read -r choice || return
        case "$choice" in
            1) _admin_list_users    ;;
            2) _admin_create_user   ;;
            3) _admin_promote_user  ;;
            4) _admin_demote_user   ;;
            5) _admin_reset_pass    ;;
            6) _admin_delete_user   ;;
            0) return ;;
            *) log ERROR "Invalid option." ;;
        esac
        pause
    done
}

_admin_list_users() {
    header
    _list_users
}

_admin_create_user() {
    header
    section_header "Create New User"
    printf '  %s▶%s Fill in the details below. Leave admin blank for a regular user.%s\n\n' \
        "$C_CYAN" "$C_RESET" "$C_RESET"

    local email username first last pass is_admin

    while [[ -z "$email" ]]; do
        read -r -p "  Email: " email
        [[ -z "$email" ]] && log WARN "Email cannot be empty."
    done
    while [[ -z "$username" ]]; do
        read -r -p "  Username: " username
        [[ -z "$username" ]] && log WARN "Username cannot be empty."
    done
    read -r -p "  First name [User]: " first;  [[ -z "$first" ]] && first="User"
    read -r -p "  Last name  [New]:  " last;   [[ -z "$last"  ]] && last="New"
    while [[ -z "$pass" ]]; do
        read -r -s -p "  Password: " pass; echo
        [[ -z "$pass" ]] && log WARN "Password cannot be empty."
    done
    read -r -p "  Make admin? [y/N]: " ans
    [[ "${ans,,}" == "y" ]] && is_admin=1 || is_admin=0

    echo
    (cd "$PANEL_DIR" && php artisan p:user:make \
        --email="$email" \
        --username="$username" \
        --name-first="$first" \
        --name-last="$last" \
        --password="$pass" \
        --admin="$is_admin") \
        && log OK "User '$username' created successfully." \
        || log ERROR "Failed to create user. Check artisan output above."
}

_admin_promote_user() {
    header
    section_header "Promote User to Admin"
    _list_users
    local email
    read -r -p "  Enter the user's email to promote: " email
    [[ -z "$email" ]] && { log ERROR "No email entered."; return 1; }

    # Use direct DB update — artisan has no p:user:promote but does expose DB
    (cd "$PANEL_DIR" && php artisan tinker --no-interaction \
        --execute="
            \$u = \App\Models\User::where('email', '$email')->first();
            if (!\$u) { echo 'User not found.\n'; exit(1); }
            \$u->root_admin = 1;
            \$u->save();
            echo 'Promoted: ' . \$u->username . '\n';
        " 2>/dev/null) \
        && log OK "User '$email' is now an admin." \
        || log ERROR "Promotion failed. Is the email correct?"
}

_admin_demote_user() {
    header
    section_header "Demote Admin to Regular User"
    _list_users
    local email
    read -r -p "  Enter the admin's email to demote: " email
    [[ -z "$email" ]] && { log ERROR "No email entered."; return 1; }

    (cd "$PANEL_DIR" && php artisan tinker --no-interaction \
        --execute="
            \$u = \App\Models\User::where('email', '$email')->first();
            if (!\$u) { echo 'User not found.\n'; exit(1); }
            \$u->root_admin = 0;
            \$u->save();
            echo 'Demoted: ' . \$u->username . '\n';
        " 2>/dev/null) \
        && log OK "User '$email' is now a regular user." \
        || log ERROR "Demotion failed. Is the email correct?"
}

_admin_reset_pass() {
    header
    section_header "Reset User Password"
    _list_users
    local email new_pass

    read -r -p "  Enter the user's email: " email
    [[ -z "$email" ]] && { log ERROR "No email entered."; return 1; }
    while [[ -z "$new_pass" ]]; do
        read -r -s -p "  New password: " new_pass; echo
        [[ -z "$new_pass" ]] && log WARN "Password cannot be empty."
    done

    (cd "$PANEL_DIR" && php artisan tinker --no-interaction \
        --execute="
            \$u = \App\Models\User::where('email', '$email')->first();
            if (!\$u) { echo 'User not found.\n'; exit(1); }
            \$u->password = \Illuminate\Support\Facades\Hash::make('${new_pass}');
            \$u->save();
            echo 'Password updated for: ' . \$u->username . '\n';
        " 2>/dev/null) \
        && log OK "Password reset for '$email'." \
        || log ERROR "Password reset failed. Is the email correct?"
}

_admin_delete_user() {
    header
    section_header "Delete User"
    _list_users
    local email

    read -r -p "  Enter the user's email to delete: " email
    [[ -z "$email" ]] && { log ERROR "No email entered."; return 1; }

    log WARN "This permanently deletes the user and cannot be undone."
    confirm "DELETE-$email" "Type DELETE-$email to confirm deletion:" || return

    (cd "$PANEL_DIR" && php artisan tinker --no-interaction \
        --execute="
            \$u = \App\Models\User::where('email', '$email')->first();
            if (!\$u) { echo 'User not found.\n'; exit(1); }
            \$name = \$u->username;
            \$u->delete();
            echo 'Deleted user: ' . \$name . '\n';
        " 2>/dev/null) \
        && log OK "User '$email' deleted." \
        || log ERROR "Deletion failed. User may have active servers — remove them first."
}

# ─────────────────────────────────────────────
#  MAIN MENU
# ─────────────────────────────────────────────
main_menu() {
    while true; do
        header
        printf '  %s[SETUP]%s\n'           "$C_YELLOW$C_BOLD" "$C_RESET"
        echo "  [1]  Install basic dependencies"
        echo "  [2]  Install Panel  (full auto)"
        echo "  [3]  Install Wings  (full auto)"
        echo "  [B]  Blueprint — view install overview"
        echo
        printf '  %s[MANAGEMENT]%s\n'      "$C_YELLOW$C_BOLD" "$C_RESET"
        echo "  [4]  Service controls"
        echo "  [5]  Diagnostics"
        echo "  [6]  View logs"
        echo "  [U]  User / Admin management"
        echo
        printf '  %s[BACKUPS / RESTORE]%s\n' "$C_YELLOW$C_BOLD" "$C_RESET"
        echo "  [7]  Create backup — Panel"
        echo "  [8]  Create backup — Wings"
        echo "  [9]  List backups"
        echo "  [10] Restore backup"
        echo
        printf '  %s[UPDATES]%s\n'         "$C_YELLOW$C_BOLD" "$C_RESET"
        echo "  [11] Update Panel"
        echo "  [12] Update Wings"
        echo
        printf '  %s[REMOVAL]%s\n'         "$C_YELLOW$C_BOLD" "$C_RESET"
        echo "  [13] Remove Panel  (auto backup)"
        echo "  [14] Remove Wings  (auto backup)"
        echo
        echo "  [0]  Exit"
        echo
        printf '  %s────────────────────────────────────────────%s\n' "$C_DIM" "$C_RESET"
        printf '  Select an option: '
        read -r choice || exit 0
        case "${choice,,}" in
            1)   install_dependencies    ;;
            2)   install_panel_guided    ;;
            3)   install_wings_guided    ;;
            b)   show_blueprints; continue ;;
            4)   service_menu            ;;
            u)   admin_menu              ;;
            5)   diagnostics             ;;
            6)   view_logs               ;;
            7)   backup_panel            ;;
            8)   backup_wings            ;;
            9)   list_backups            ;;
            10)  restore_backup          ;;
            11)  update_panel            ;;
            12)  update_wings            ;;
            13)  remove_panel            ;;
            14)  remove_wings            ;;
            0)   printf '\n  %sExiting SPYDR. Goodbye!%s\n\n' "$C_CYAN" "$C_RESET"
                 exit 0 ;;
            *)   log ERROR "Invalid option '$choice'." ;;
        esac
        pause
    done
}

# ─────────────────────────────────────────────
#  ENTRY POINT
# ─────────────────────────────────────────────
if [[ "${1:-}" == "--help" ]]; then
    printf 'SPYDR %s — Pterodactyl Management Toolkit\n' "$VERSION"
    printf 'Run with: sudo bash pteroease.sh\n'
    exit 0
fi

if [[ $EUID -ne 0 ]]; then
    printf '%sRun with root privileges: sudo bash %s%s\n' "$C_RED" "$0" "$C_RESET"
    exit 1
fi

mkdir -p "$LOG_DIR" "$BACKUP_ROOT"
chmod 700 "$LOG_DIR" "$BACKUP_ROOT"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"

main_menu
