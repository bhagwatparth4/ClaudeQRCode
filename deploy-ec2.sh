#!/usr/bin/env bash
# =============================================================================
#  Rush Hours / ClaudeQRCode  -  one-shot EC2 deploy (Ubuntu 22.04 / 24.04)
#
#  What it sets up:
#    PostgreSQL + Redis ........ Docker (bound to 127.0.0.1 only)
#    Spring Boot backend ....... systemd service "cafeqr-backend" (127.0.0.1:8080)
#    React frontend ............ built with Vite, served by nginx from /var/www/cafeqr
#    nginx ..................... :80  ->  /      frontend
#                                        /api/   backend
#                                        /ws     backend (WebSocket)
#
#  Usage (run as root or with sudo, from anywhere):
#    sudo bash deploy-ec2.sh                       # auto-detects the EC2 public IP
#    sudo PUBLIC_URL=https://cafe.example.com bash deploy-ec2.sh   # with a domain
#    sudo PROJECT_DIR=/root/ClaudeQRCode/ClaudeQRCode bash deploy-ec2.sh
#
#  Safe to re-run: it rebuilds and restarts, and KEEPS your existing secrets.
#
#  EC2 Security Group (inbound): 22 (your IP), 80, 443. Do NOT open 5432/6379/8080.
# =============================================================================
set -euo pipefail

# ----------------------------- settings --------------------------------------
PROJECT_DIR="${PROJECT_DIR:-/root/ClaudeQRCode/ClaudeQRCode}"
APP_NAME="cafeqr"
WEB_ROOT="/var/www/${APP_NAME}"
APP_DIR="/opt/${APP_NAME}"
ENV_DIR="/etc/${APP_NAME}"
ENV_FILE="${ENV_DIR}/backend.env"
SERVICE_USER="cafeqr"
# "dev" profile creates the first admin (admin@rushhour.com / Admin@12345).
# After you log in and change the password, set this to "prod" in backend.env.
SPRING_PROFILE="${SPRING_PROFILE:-dev}"

log()  { echo -e "\n\033[1;32m==> $*\033[0m"; }
warn() { echo -e "\033[1;33m[warn]\033[0m $*"; }
die()  { echo -e "\033[1;31m[error]\033[0m $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root:  sudo bash $0"
[[ -f "${PROJECT_DIR}/backend/pom.xml" ]] || die "Project not found at ${PROJECT_DIR} (set PROJECT_DIR=...)"
[[ -f "${PROJECT_DIR}/frontend/package.json" ]] || die "Frontend not found in ${PROJECT_DIR}/frontend"
command -v apt-get >/dev/null || die "This script supports Ubuntu/Debian (apt) only."

export DEBIAN_FRONTEND=noninteractive

# ----------------------------- public URL ------------------------------------
if [[ -z "${PUBLIC_URL:-}" ]]; then
  TOKEN="$(curl -fsS -m 3 -X PUT http://169.254.169.254/latest/api/token \
            -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' 2>/dev/null || true)"
  PUBLIC_IP="$(curl -fsS -m 3 -H "X-aws-ec2-metadata-token: ${TOKEN}" \
            http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || true)"
  [[ -n "${PUBLIC_IP}" ]] || PUBLIC_IP="$(curl -fsS -m 5 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]' || true)"
  [[ -n "${PUBLIC_IP}" ]] || die "Could not detect public IP. Run with PUBLIC_URL=http://YOUR_IP"
  PUBLIC_URL="http://${PUBLIC_IP}"
fi
PUBLIC_URL="${PUBLIC_URL%/}"
WS_URL="$(echo "${PUBLIC_URL}" | sed -E 's#^https#wss#; s#^http#ws#')/ws"
log "Public URL: ${PUBLIC_URL}   (WebSocket: ${WS_URL})"

# ----------------------------- swap (small instances) ------------------------
MEM_MB="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)"
if (( MEM_MB < 3000 )) && ! swapon --show | grep -q .; then
  log "Only ${MEM_MB} MB RAM - adding 2 GB swap so Maven/Vite builds don't get killed"
  fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# ----------------------------- packages --------------------------------------
log "Installing packages (nginx, Java 21, Node 20, Docker)"
apt-get update -y
apt-get install -y nginx openjdk-21-jdk-headless curl ca-certificates gnupg openssl unzip

if ! command -v node >/dev/null || [[ "$(node -p 'process.versions.node.split(".")[0]')" -lt 20 ]]; then
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y nodejs
fi

if ! command -v docker >/dev/null; then
  curl -fsSL https://get.docker.com | sh
fi
systemctl enable --now docker
docker compose version >/dev/null 2>&1 || apt-get install -y docker-compose-plugin

# ----------------------------- secrets / env ---------------------------------
mkdir -p "${ENV_DIR}"
chmod 750 "${ENV_DIR}"

# helper: read KEY from an env-style file (strips Windows CRLF), empty if absent
getv() { [[ -f "$2" ]] && sed 's/\r$//' "$2" | grep -E "^$1=" | tail -n1 | cut -d= -f2- || true; }

if [[ -f "${ENV_FILE}" ]]; then
  log "Keeping existing secrets in ${ENV_FILE}"
else
  log "Creating ${ENV_FILE}"
  PROJECT_ENV="${PROJECT_DIR}/.env"
  PG_DB="$(getv POSTGRES_DB "${PROJECT_ENV}")";           PG_DB="${PG_DB:-cafe_ordering}"
  PG_USER="$(getv POSTGRES_USER "${PROJECT_ENV}")";       PG_USER="${PG_USER:-cafe_user}"
  PG_PASS="$(getv POSTGRES_PASSWORD "${PROJECT_ENV}")";   PG_PASS="${PG_PASS:-$(openssl rand -hex 16)}"
  JWT="$(getv JWT_SECRET "${PROJECT_ENV}")"
  [[ ${#JWT} -ge 64 ]] || JWT="$(openssl rand -base64 64 | tr -d '\n')"

  RZP_ID="${RAZORPAY_KEY_ID:-$(getv RAZORPAY_KEY_ID "${PROJECT_ENV}")}";                 RZP_ID="${RZP_ID:-rzp_test_replace_me}"
  RZP_SECRET="${RAZORPAY_KEY_SECRET:-$(getv RAZORPAY_KEY_SECRET "${PROJECT_ENV}")}";     RZP_SECRET="${RZP_SECRET:-replace-me}"
  RZP_WH="${RAZORPAY_WEBHOOK_SECRET:-$(getv RAZORPAY_WEBHOOK_SECRET "${PROJECT_ENV}")}"; RZP_WH="${RZP_WH:-replace-me}"

  cat > "${ENV_FILE}" <<EOF
# ---- Database / Redis (Docker, localhost only) ----
POSTGRES_DB=${PG_DB}
POSTGRES_USER=${PG_USER}
POSTGRES_PASSWORD=${PG_PASS}
DB_URL=jdbc:postgresql://127.0.0.1:5432/${PG_DB}
REDIS_HOST=127.0.0.1
REDIS_PORT=6379

# ---- Security ----
JWT_SECRET=${JWT}

# ---- Razorpay (put your real keys here, then: systemctl restart ${APP_NAME}-backend) ----
RAZORPAY_KEY_ID=${RZP_ID}
RAZORPAY_KEY_SECRET=${RZP_SECRET}
RAZORPAY_WEBHOOK_SECRET=${RZP_WH}

# ---- App ----
BUSINESS_TYPE=SMALL_CAFE
CAFE_NAME=Rush Hours
APP_TIMEZONE=Asia/Kolkata
# Must EXACTLY match what the browser shows in the address bar (CORS + WebSocket origin check)
FRONTEND_URL=${PUBLIC_URL}

# ---- Optional ----
VAPID_PUBLIC_KEY=
VAPID_PRIVATE_KEY=
VAPID_SUBJECT=mailto:owner@example.com
TWOFACTOR_API_KEY=
TWOFACTOR_SMS_HEADER=
WHATSAPP_ENABLED=false

# ---- Spring runtime ----
SPRING_PROFILES_ACTIVE=${SPRING_PROFILE}
SERVER_ADDRESS=127.0.0.1
SERVER_FORWARD_HEADERS_STRATEGY=framework
SPRING_JPA_SHOW_SQL=false
EOF
  chmod 640 "${ENV_FILE}"
fi

# Keep FRONTEND_URL in sync if you re-run with a different PUBLIC_URL
if grep -q '^FRONTEND_URL=' "${ENV_FILE}"; then
  sed -i "s#^FRONTEND_URL=.*#FRONTEND_URL=${PUBLIC_URL}#" "${ENV_FILE}"
else
  echo "FRONTEND_URL=${PUBLIC_URL}" >> "${ENV_FILE}"
fi

# ----------------------------- Postgres + Redis ------------------------------
log "Starting PostgreSQL + Redis (Docker)"
mkdir -p "${APP_DIR}"
cat > "${APP_DIR}/docker-compose.yml" <<'EOF'
services:
  postgres:
    image: postgres:16-alpine
    container_name: cafe-qr-postgres
    restart: unless-stopped
    environment:
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    ports:
      - "127.0.0.1:5432:5432"
    volumes:
      - cafe_qr_postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 10s

  redis:
    image: redis:7-alpine
    container_name: cafe-qr-redis
    restart: unless-stopped
    ports:
      - "127.0.0.1:6379:6379"

volumes:
  cafe_qr_postgres_data:
    name: cafe_qr_postgres_data
EOF

# Old dev containers (from the project's own docker-compose.yml) would clash on ports/names
docker rm -f cafe-qr-postgres cafe-qr-redis >/dev/null 2>&1 || true
docker compose --env-file "${ENV_FILE}" -f "${APP_DIR}/docker-compose.yml" up -d

log "Waiting for PostgreSQL to be healthy"
for i in $(seq 1 40); do
  [[ "$(docker inspect -f '{{.State.Health.Status}}' cafe-qr-postgres 2>/dev/null || true)" == "healthy" ]] && break
  sleep 3
  [[ $i -eq 40 ]] && die "PostgreSQL did not become healthy. Check: docker logs cafe-qr-postgres  (if the password changed, the old volume must be removed: docker volume rm cafe_qr_postgres_data)"
done

# ----------------------------- backend build ---------------------------------
log "Building backend (first run downloads Maven + dependencies, takes a few minutes)"
cd "${PROJECT_DIR}/backend"
sed -i 's/\r$//' mvnw
chmod +x mvnw
./mvnw -q -DskipTests clean package

JAR="$(ls target/*.jar | grep -v '\.original$' | head -n1)"
[[ -n "${JAR}" ]] || die "Backend jar not found in ${PROJECT_DIR}/backend/target"
id -u "${SERVICE_USER}" >/dev/null 2>&1 || useradd --system --home "${APP_DIR}" --shell /usr/sbin/nologin "${SERVICE_USER}"
install -m 644 -o "${SERVICE_USER}" -g "${SERVICE_USER}" "${JAR}" "${APP_DIR}/backend.jar"
chgrp "${SERVICE_USER}" "${ENV_FILE}" "${ENV_DIR}"

cat > "/etc/systemd/system/${APP_NAME}-backend.service" <<EOF
[Unit]
Description=Cafe QR backend (Spring Boot)
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
User=${SERVICE_USER}
WorkingDirectory=${APP_DIR}
EnvironmentFile=${ENV_FILE}
ExecStart=/usr/bin/java -Xms256m -Xmx512m -jar ${APP_DIR}/backend.jar
SuccessExitStatus=143
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable "${APP_NAME}-backend" >/dev/null
systemctl restart "${APP_NAME}-backend"

# ----------------------------- frontend build --------------------------------
log "Building frontend"
cd "${PROJECT_DIR}/frontend"

# NOTE: the code already prefixes every request with "/api/...", so VITE_API_URL must be the
# site ORIGIN (no "/api" at the end). Same for the WebSocket: <origin>/ws.
CAFE_NAME="$(getv VITE_CAFE_NAME .env)";       CAFE_NAME="${CAFE_NAME:-Rush Hours}"
CAFE_TAG="$(getv VITE_CAFE_TAGLINE .env)";     CAFE_TAG="${CAFE_TAG:-Brews · Bites · Tales}"
CAFE_ADDR="$(getv VITE_CAFE_ADDRESS .env)"
CAFE_PHONE="$(getv VITE_CAFE_PHONE .env)"

cat > .env.production <<EOF
VITE_API_URL=${PUBLIC_URL}
VITE_WS_URL=${WS_URL}
VITE_CAFE_NAME=${CAFE_NAME}
VITE_CAFE_TAGLINE=${CAFE_TAG}
VITE_CAFE_ADDRESS=${CAFE_ADDR}
VITE_CAFE_PHONE=${CAFE_PHONE}
EOF
# a stray .env with VITE_API_URL=/api would be overridden by .env.production, but remove the confusion:
[[ -f .env ]] && sed -i '/^VITE_API_URL=/d;/^VITE_WS_URI=/d;/^VITE_WS_URL=/d' .env

if [[ -f package-lock.json ]]; then npm ci --no-audit --no-fund; else npm install --no-audit --no-fund; fi
npm run build

mkdir -p "${WEB_ROOT}"
rm -rf "${WEB_ROOT:?}"/*
cp -r dist/. "${WEB_ROOT}/"
chown -R www-data:www-data "${WEB_ROOT}"

# ----------------------------- nginx -----------------------------------------
log "Configuring nginx"
cat > "/etc/nginx/sites-available/${APP_NAME}" <<'EOF'
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    root /var/www/cafeqr;
    index index.html;

    client_max_body_size 10m;

    gzip on;
    gzip_types text/css application/javascript application/json image/svg+xml;

    # --- REST API ---
    location /api/ {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 60s;
    }

    # --- WebSocket (STOMP) ---
    location /ws {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade           $http_upgrade;
        proxy_set_header Connection        $connection_upgrade;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }

    # Dev test pages shipped inside the backend - not for production
    location = /payment-test.html   { return 404; }
    location = /websocket-test.html { return 404; }

    # Service worker must never be cached (Web Push)
    location = /sw.js {
        add_header Cache-Control "no-cache";
        try_files $uri =404;
    }

    # Hashed build assets can be cached for a long time
    location /assets/ {
        expires 30d;
        add_header Cache-Control "public, immutable";
        try_files $uri =404;
    }

    # --- React single-page app ---
    location / {
        try_files $uri $uri/ /index.html;
    }
}
EOF

# NOTE the spelling: sites-enabled (with an "s"), not site-enabled
ln -sf "/etc/nginx/sites-available/${APP_NAME}" "/etc/nginx/sites-enabled/${APP_NAME}"
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl enable nginx >/dev/null
systemctl reload nginx || systemctl restart nginx

# ----------------------------- health check ----------------------------------
log "Waiting for the backend to start (up to ~2 min)"
OK=0
for i in $(seq 1 40); do
  code="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/api/menu/categories || true)"
  if [[ "${code}" == "200" ]]; then OK=1; break; fi
  sleep 3
done

echo
if [[ ${OK} -eq 1 ]]; then
  echo -e "\033[1;32m✔ DONE - the app is live\033[0m"
else
  warn "Backend did not answer 200 yet. See logs:  journalctl -u ${APP_NAME}-backend -n 100 --no-pager"
fi
cat <<EOF

  Open:        ${PUBLIC_URL}
  Admin login: ${PUBLIC_URL}/login
               admin@rushhour.com / Admin@12345     <-- CHANGE THIS NOW

  Secrets:     ${ENV_FILE}
               (add real RAZORPAY_* keys there, then: systemctl restart ${APP_NAME}-backend)

  Useful:
    journalctl -u ${APP_NAME}-backend -f          backend logs
    systemctl restart ${APP_NAME}-backend         restart backend
    nginx -t && systemctl reload nginx            reload nginx
    docker ps                                     postgres / redis

  Remember:
    * EC2 Security Group must allow inbound TCP 80 (and 443 later).
    * QR codes embed FRONTEND_URL. If your IP/domain changes, update it and REPRINT the QRs.
      Use an Elastic IP (or a domain) so the address never changes.
    * Razorpay webhooks and Web Push need HTTPS -> use a domain, then:
        apt install -y certbot python3-certbot-nginx && certbot --nginx -d cafe.example.com
        sudo PUBLIC_URL=https://cafe.example.com bash $0
EOF
