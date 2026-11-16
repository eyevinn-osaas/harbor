#!/bin/bash
# OSC entrypoint for the all-in-one Harbor image.
# Replaces upstream's Python "prepare" step: renders the configuration and
# environment files for core, jobservice, registryctl, registry and nginx
# from OSC environment variables, then hands over to the supervisor.
set -e

log()  { echo "[osc-entrypoint] $*"; }
die()  { echo "[osc-entrypoint] ERROR: $*" >&2; exit 1; }

DATA_DIR="${DATA_DIR:-/data}"
RUN_DIR=/run/harbor
SECRET_DIR="$DATA_DIR/secret"
HARBOR_UID=10000
HARBOR_GID=10000

# Internal (loopback) ports. Only nginx listens on $PORT.
CORE_PORT=8081
REGISTRYCTL_PORT=8083
JOBSERVICE_PORT=8084
REGISTRY_PORT=5000

PORT="${PORT:-8080}"
[[ "$PORT" =~ ^[0-9]+$ ]] || die "PORT must be a number, got '$PORT'"

# ---------------------------------------------------------------- helpers
url_decode() {
  local s="${1//\\/\\\\}"
  printf '%b' "${s//%/\\x}"
}

# Splits a URL into P_SCHEME P_USER P_PASS P_HAS_AUTH P_HOST P_PORT P_PATH P_QUERY
# (user/pass are kept percent-encoded exactly as supplied).
parse_url() {
  local url="$1" rest authority tail hostport userinfo
  P_SCHEME="" P_USER="" P_PASS="" P_HAS_AUTH="" P_HOST="" P_PORT="" P_PATH="" P_QUERY=""
  [[ "$url" == *"://"* ]] || return 1
  P_SCHEME="${url%%://*}"
  rest="${url#*://}"
  authority="${rest%%[/?#]*}"
  tail="${rest#"$authority"}"
  hostport="${authority##*@}"
  if [[ "$authority" == *"@"* ]]; then
    P_HAS_AUTH=1
    userinfo="${authority%@*}"
    P_USER="${userinfo%%:*}"
    [[ "$userinfo" == *":"* ]] && P_PASS="${userinfo#*:}"
  fi
  if [[ "$hostport" =~ ^(\[[^]]+\])(:([0-9]+))?$ ]]; then
    P_HOST="${BASH_REMATCH[1]}"; P_PORT="${BASH_REMATCH[3]}"
  elif [[ "$hostport" =~ ^([^:]+)(:([0-9]+))?$ ]]; then
    P_HOST="${BASH_REMATCH[1]}"; P_PORT="${BASH_REMATCH[3]}"
  else
    return 1
  fi
  tail="${tail%%#*}"
  if [[ "$tail" == *"?"* ]]; then
    P_QUERY="${tail#*\?}"
    tail="${tail%%\?*}"
  fi
  P_PATH="${tail#/}"
  return 0
}

wait_for_tcp() {  # name host port
  local name="$1" host="${2#[}" port="$3" waited=0 max="${HARBOR_DEPS_WAIT_SECONDS:-30}"
  host="${host%]}"
  until timeout 3 bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null; do
    if [ "$waited" -ge "$max" ]; then
      die "cannot reach $name at $host:$port after ${max}s. Check the URL and that the service is running."
    fi
    sleep 2; waited=$((waited + 2))
  done
  log "$name reachable at $host:$port"
}

# Quote for YAML double-quoted scalar
yq() { local s="${1//\\/\\\\}"; s="${s//\"/\\\"}"; printf '"%s"' "$s"; }

rand() {  # length
  local out
  out="$(head -c 512 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | head -c "$1")" || true
  [ "${#out}" -eq "$1" ] || die "failed to generate random string"
  printf '%s' "$out"
}

# get_secret NAME ENVVALUE LENGTH
# Uses ENVVALUE if given, else the persisted file, else generates and persists.
get_secret() {
  local name="$1" given="$2" len="$3" f="$SECRET_DIR/$1" val
  if [ -n "$given" ]; then
    printf '%s' "$given"; return
  fi
  if [ -s "$f" ]; then
    cat "$f"; return
  fi
  val="$(rand "$len")"
  ( umask 077; printf '%s' "$val" > "$f" )
  printf '%s' "$val"
}

# env-file writer (shell-sourceable)
emit() { printf '%s=%q\n' "$1" "$2" >> "$ENVFILE"; }

# ------------------------------------------------- Section 1: DATABASE_URL
[ -n "$DATABASE_URL" ] || die "DATABASE_URL is required, e.g. postgres://user:password@host:5432/registry?sslmode=disable"
parse_url "$DATABASE_URL" || die "DATABASE_URL is not a valid URL (expected postgres://user:password@host:port/dbname)"
case "$P_SCHEME" in
  postgres|postgresql) ;;
  *) die "DATABASE_URL scheme must be postgres or postgresql, got '$P_SCHEME'" ;;
esac
[ -n "$P_HOST" ] || die "DATABASE_URL has no host"
DB_HOST="$P_HOST"
DB_PORT="${P_PORT:-5432}"
DB_USER="$(url_decode "${P_USER:-postgres}")"
DB_PASS="$(url_decode "$P_PASS")"
DB_NAME="$(url_decode "${P_PATH%%/*}")"
if [ -z "$DB_NAME" ]; then
  DB_NAME="registry"
  log "DATABASE_URL has no database name, using '$DB_NAME' (the database must already exist)"
fi
DB_SSLMODE="disable"
if [ -n "$P_QUERY" ]; then
  IFS='&' read -ra _q <<< "$P_QUERY"
  for kv in "${_q[@]}"; do
    case "$kv" in
      sslmode=*) DB_SSLMODE="${kv#sslmode=}" ;;
      *) log "WARNING: DATABASE_URL parameter '${kv%%=*}' is ignored (Harbor only supports sslmode)" ;;
    esac
  done
fi
export POSTGRESQL_HOST="${DB_HOST#[}"; POSTGRESQL_HOST="${POSTGRESQL_HOST%]}"

# --------------------------------------------------------- REDIS_URL
[ -n "$REDIS_URL" ] || die "REDIS_URL is required, e.g. redis://:password@host:6379"
parse_url "$REDIS_URL" || die "REDIS_URL is not a valid URL (expected redis://[user]:password@host:port)"
case "$P_SCHEME" in
  redis|rediss) ;;
  *) die "REDIS_URL scheme must be redis or rediss, got '$P_SCHEME' (sentinel is not supported)" ;;
esac
[ -n "$P_HOST" ] || die "REDIS_URL has no host"
REDIS_SCHEME="$P_SCHEME"
REDIS_HOST="$P_HOST"
REDIS_PORT="${P_PORT:-6379}"
REDIS_USER_RAW="$P_USER"
REDIS_PASS_RAW="$P_PASS"
REDIS_USER="$(url_decode "$P_USER")"
REDIS_PASS="$(url_decode "$P_PASS")"
REDIS_QUERY="$P_QUERY"
if [ -n "$P_PATH" ] && [ "$P_PATH" != "0" ]; then
  log "WARNING: database index in REDIS_URL is ignored; Harbor uses db 0 (core), 1 (registry) and 2 (jobservice)"
fi
REDIS_AUTH=""
if [ -n "$P_HAS_AUTH" ]; then REDIS_AUTH="${REDIS_USER_RAW}:${REDIS_PASS_RAW}@"; fi
redis_url() { printf '%s://%s%s:%s/%s%s' "$REDIS_SCHEME" "$REDIS_AUTH" "$REDIS_HOST" "$REDIS_PORT" "$1" "${REDIS_QUERY:+?$REDIS_QUERY}"; }
REDIS_URL_CORE="$(redis_url 0)"
REDIS_URL_REG="$(redis_url 1)"
REDIS_URL_JS="$(redis_url 2)"
REDIS_TLS=false; [ "$REDIS_SCHEME" = "rediss" ] && REDIS_TLS=true

wait_for_tcp "PostgreSQL" "$DB_HOST" "$DB_PORT"
wait_for_tcp "Redis/Valkey" "$REDIS_HOST" "$REDIS_PORT"

# ---------------------------------------------- Section 2: OSC public URL
if [ -n "$HARBOR_EXTERNAL_URL" ]; then
  EXT_ENDPOINT="${HARBOR_EXTERNAL_URL%/}"
elif [ -n "$OSC_HOSTNAME" ]; then
  EXT_ENDPOINT="https://$OSC_HOSTNAME"
else
  EXT_ENDPOINT="http://localhost:$PORT"
  log "WARNING: neither OSC_HOSTNAME nor HARBOR_EXTERNAL_URL set, using $EXT_ENDPOINT. Token auth for docker login will only work locally."
fi
log "External URL: $EXT_ENDPOINT"

# ------------------------------------------------------- Log level
LOG_LEVEL="$(echo "${LOG_LEVEL:-info}" | tr '[:upper:]' '[:lower:]')"
case "$LOG_LEVEL" in
  debug|info|warning|error|fatal) ;;
  *) die "LOG_LEVEL must be one of debug, info, warning, error, fatal (got '$LOG_LEVEL')" ;;
esac
REG_LOG_LEVEL="$LOG_LEVEL"; [ "$LOG_LEVEL" = "warning" ] && REG_LOG_LEVEL="warn"
MAX_JOB_WORKERS="${MAX_JOB_WORKERS:-10}"
[[ "$MAX_JOB_WORKERS" =~ ^[0-9]+$ ]] || die "MAX_JOB_WORKERS must be a number"

# ---------------------------------- Section 3: persistent storage & secrets
mkdir -p "$SECRET_DIR/core" "$SECRET_DIR/keys" "$DATA_DIR/registry" "$DATA_DIR/job_logs" "$RUN_DIR"
chmod 700 "$SECRET_DIR"

SECRET_KEY="$(get_secret secretkey "$HARBOR_SECRET_KEY" 16)"
[ "${#SECRET_KEY}" -eq 16 ] || die "HARBOR_SECRET_KEY must be exactly 16 characters"
CORE_SECRET="$(get_secret core_secret "$HARBOR_CORE_SECRET" 16)"
JOBSERVICE_SECRET="$(get_secret jobservice_secret "$HARBOR_JOBSERVICE_SECRET" 16)"
CSRF_KEY="$(get_secret csrf_key "$HARBOR_CSRF_KEY" 32)"
[ "${#CSRF_KEY}" -eq 32 ] || die "HARBOR_CSRF_KEY must be exactly 32 characters"
REGISTRY_HTTP_SECRET="$(get_secret registry_http_secret "$HARBOR_REGISTRY_HTTP_SECRET" 32)"
REGISTRY_PASSWORD="$(get_secret registry_password "" 32)"
SCAN_ROBOT_PREFIX="$(get_secret scan_robot_prefix "" 8)"
if [ -z "$HARBOR_ADMIN_PASSWORD" ]; then
  if [ ! -s "$SECRET_DIR/admin_password" ]; then
    log "WARNING: HARBOR_ADMIN_PASSWORD not set; generated a random one and stored it in $SECRET_DIR/admin_password. Set HARBOR_ADMIN_PASSWORD to choose it (only used when Harbor initialises a new database)."
  fi
fi
ADMIN_PASSWORD="$(get_secret admin_password "$HARBOR_ADMIN_PASSWORD" 24)"
REGISTRY_USER=harbor_registry_user

# Token signing key (core signs registry tokens, no cert exchange with registry needed
# because registry authenticates core with htpasswd).
TOKEN_KEY="$SECRET_DIR/core/private_key.pem"
if [ -n "$HARBOR_TOKEN_PRIVATE_KEY" ]; then
  TOKEN_KEY="$RUN_DIR/private_key.pem"
  ( umask 077; printf '%s\n' "$HARBOR_TOKEN_PRIVATE_KEY" > "$TOKEN_KEY" )
elif [ ! -s "$TOKEN_KEY" ]; then
  log "Generating token signing key (first start)"
  ( umask 077; openssl genrsa -traditional -out "$TOKEN_KEY" 4096 2>/dev/null ) || die "failed to generate token signing key"
fi
( umask 077; printf '%s' "$SECRET_KEY" > "$SECRET_DIR/keys/secretkey" )

# ------------------------------------------ Section 4: config generation
rm -rf "$RUN_DIR/core" "$RUN_DIR/registry" "$RUN_DIR/registryctl" "$RUN_DIR/jobservice" "$RUN_DIR/nginx"
mkdir -p "$RUN_DIR/core" "$RUN_DIR/registry" "$RUN_DIR/registryctl" "$RUN_DIR/jobservice" "$RUN_DIR/nginx"

# --- core
cat > "$RUN_DIR/core/app.conf" <<EOF
appname = Harbor
runmode = prod
enablegzip = true

[prod]
httpaddr = 127.0.0.1
httpport = $CORE_PORT
EOF

STORAGE_PROVIDER="$(echo "${STORAGE_BACKEND:-filesystem}" | tr '[:upper:]' '[:lower:]')"
case "$STORAGE_PROVIDER" in
  filesystem|s3) ;;
  *) die "STORAGE_BACKEND must be 'filesystem' or 's3' (got '$STORAGE_PROVIDER')" ;;
esac

ENVFILE="$RUN_DIR/core/env"; : > "$ENVFILE"; chmod 600 "$ENVFILE"
emit CONFIG_PATH "$RUN_DIR/core/app.conf"
emit KEY_PATH "$SECRET_DIR/keys/secretkey"
emit TOKEN_PRIVATE_KEY_PATH "$TOKEN_KEY"
emit _REDIS_URL_CORE "$REDIS_URL_CORE"
emit _REDIS_URL_REG "$REDIS_URL_REG"
emit LOG_LEVEL "$LOG_LEVEL"
emit EXT_ENDPOINT "$EXT_ENDPOINT"
emit DATABASE_TYPE postgresql
emit POSTGRESQL_HOST "$POSTGRESQL_HOST"
emit POSTGRESQL_PORT "$DB_PORT"
emit POSTGRESQL_USERNAME "$DB_USER"
emit POSTGRESQL_PASSWORD "$DB_PASS"
emit POSTGRESQL_DATABASE "$DB_NAME"
emit POSTGRESQL_SSLMODE "$DB_SSLMODE"
emit POSTGRESQL_MAX_IDLE_CONNS "${POSTGRESQL_MAX_IDLE_CONNS:-2}"
emit POSTGRESQL_MAX_OPEN_CONNS "${POSTGRESQL_MAX_OPEN_CONNS:-0}"
emit POSTGRESQL_CONN_MAX_LIFETIME 5m
emit POSTGRESQL_CONN_MAX_IDLE_TIME 0
emit REGISTRY_URL "http://127.0.0.1:$REGISTRY_PORT"
emit PORTAL_URL "http://127.0.0.1:$PORT"
emit TOKEN_SERVICE_URL "http://127.0.0.1:$CORE_PORT/service/token"
emit HARBOR_ADMIN_PASSWORD "$ADMIN_PASSWORD"
emit MAX_JOB_WORKERS "$MAX_JOB_WORKERS"
emit CORE_SECRET "$CORE_SECRET"
emit JOBSERVICE_SECRET "$JOBSERVICE_SECRET"
emit WITH_TRIVY false
emit CORE_URL "http://127.0.0.1:$CORE_PORT"
emit CORE_LOCAL_URL "http://127.0.0.1:$CORE_PORT"
emit JOBSERVICE_URL "http://127.0.0.1:$JOBSERVICE_PORT"
emit REGISTRY_STORAGE_PROVIDER_NAME "$STORAGE_PROVIDER"
emit READ_ONLY false
emit REGISTRY_CONTROLLER_URL "http://127.0.0.1:$REGISTRYCTL_PORT"
emit REGISTRY_CREDENTIAL_USERNAME "$REGISTRY_USER"
emit REGISTRY_CREDENTIAL_PASSWORD "$REGISTRY_PASSWORD"
emit CSRF_KEY "$CSRF_KEY"
emit ROBOT_SCANNER_NAME_PREFIX "$SCAN_ROBOT_PREFIX"
emit PERMITTED_REGISTRY_TYPES_FOR_PROXY_CACHE "docker-hub,harbor,azure-acr,ali-acr,aws-ecr,google-gcr,docker-registry,github-ghcr,jfrog-artifactory"
emit REPLICATION_ADAPTER_WHITELIST "ali-acr,aws-ecr,azure-acr,docker-hub,docker-registry,github-ghcr,google-gcr,harbor,huawei-SWR,jfrog-artifactory,tencent-tcr,volcengine-cr"
emit HARBOR_ALLOW_PRIVATE_NETWORK_ACCESS "${HARBOR_ALLOW_PRIVATE_NETWORK_ACCESS:-true}"
emit CONTENT_TRUST_LEGACY_SIGNER_PULL_ENABLED false
emit PORT "$CORE_PORT"
[ -n "$HTTP_PROXY" ]  && emit HTTP_PROXY "$HTTP_PROXY"
[ -n "$HTTPS_PROXY" ] && emit HTTPS_PROXY "$HTTPS_PROXY"
# 127.0.0.1 must never go through a proxy
emit NO_PROXY "127.0.0.1,localhost${NO_PROXY:+,$NO_PROXY}"

# --- registryctl
cat > "$RUN_DIR/registryctl/config.yml" <<EOF
---
protocol: "http"
port: $REGISTRYCTL_PORT
log_level: $REG_LOG_LEVEL
registry_config: "$RUN_DIR/registry/config.yml"
EOF
ENVFILE="$RUN_DIR/registryctl/env"; : > "$ENVFILE"; chmod 600 "$ENVFILE"
emit CORE_SECRET "$CORE_SECRET"
emit JOBSERVICE_SECRET "$JOBSERVICE_SECRET"

# --- registry (distribution)
htpasswd -bcB "$RUN_DIR/registry/passwd" "$REGISTRY_USER" "$REGISTRY_PASSWORD" >/dev/null 2>&1 || die "htpasswd failed"
if [ "$STORAGE_PROVIDER" = "s3" ]; then
  [ -n "$S3_BUCKET" ] && [ -n "$S3_ACCESS_KEY" ] && [ -n "$S3_SECRET_KEY" ] || die "STORAGE_BACKEND=s3 requires S3_BUCKET, S3_ACCESS_KEY and S3_SECRET_KEY"
  STORAGE_BLOCK="  s3:
    accesskey: $(yq "$S3_ACCESS_KEY")
    secretkey: $(yq "$S3_SECRET_KEY")
    region: $(yq "${S3_REGION:-us-east-1}")
    bucket: $(yq "$S3_BUCKET")
    secure: ${S3_SECURE:-true}
    skipverify: ${S3_SKIP_VERIFY:-false}
    forcepathstyle: ${S3_FORCE_PATH_STYLE:-true}"
  [ -n "$S3_ENDPOINT" ] && STORAGE_BLOCK="$STORAGE_BLOCK
    regionendpoint: $(yq "$S3_ENDPOINT")"
  [ -n "$S3_ROOT_DIRECTORY" ] && STORAGE_BLOCK="$STORAGE_BLOCK
    rootdirectory: $(yq "$S3_ROOT_DIRECTORY")"
else
  STORAGE_BLOCK="  filesystem:
    rootdirectory: $DATA_DIR/registry"
fi
# With S3 the registry proxies blobs by default (redirects would hand the
# client the internal S3 endpoint). Set S3_REDIRECT=true to let clients pull directly.
REDIRECT_BLOCK=""
if [ "$STORAGE_PROVIDER" = "s3" ] && [ "${S3_REDIRECT:-false}" != "true" ]; then
  REDIRECT_BLOCK="  redirect:
    disable: true"
fi
cat > "$RUN_DIR/registry/config.yml" <<EOF
version: 0.1
log:
  level: $REG_LOG_LEVEL
  fields:
    service: registry
storage:
  cache:
    layerinfo: redis
$STORAGE_BLOCK
  maintenance:
    uploadpurging:
      enabled: true
      age: 168h
      interval: 24h
      dryrun: false
  delete:
    enabled: true
$REDIRECT_BLOCK
redis:
  addr: $REDIS_HOST:$REDIS_PORT
  readtimeout: 10s
  writetimeout: 10s
  dialtimeout: 10s
  password: $(yq "$REDIS_PASS")
  username: $(yq "$REDIS_USER")
  db: 1
  enableTLS: $REDIS_TLS
  pool:
    maxidle: 100
    maxactive: 500
    idletimeout: 60s
http:
  addr: 127.0.0.1:$REGISTRY_PORT
  secret: $(yq "$REGISTRY_HTTP_SECRET")
  debug:
    addr: localhost:5001
auth:
  htpasswd:
    realm: harbor-registry-basic-realm
    path: $RUN_DIR/registry/passwd
validation:
  disabled: true
compatibility:
  schema1:
    enabled: true
EOF
ENVFILE="$RUN_DIR/registry/env"; : > "$ENVFILE"; chmod 600 "$ENVFILE"

# --- jobservice
cat > "$RUN_DIR/jobservice/config.yml" <<EOF
---
protocol: "http"
port: $JOBSERVICE_PORT
worker_pool:
  workers: $MAX_JOB_WORKERS
  backend: "redis"
  redis_pool:
    redis_url: $(yq "$REDIS_URL_JS")
    namespace: "harbor_job_service_namespace"
    idle_timeout_second: 3600
job_loggers:
  - name: "STD_OUTPUT"
    level: "$LOG_LEVEL"
  - name: "FILE"
    level: "$LOG_LEVEL"
    settings:
      base_dir: "$DATA_DIR/job_logs"
    sweeper:
      duration: 1
      settings:
        work_dir: "$DATA_DIR/job_logs"
loggers:
  - name: "STD_OUTPUT"
    level: "$LOG_LEVEL"
reaper:
  max_update_hours: 24
  max_dangling_hours: 168
max_retrieve_size_mb: 10
EOF
ENVFILE="$RUN_DIR/jobservice/env"; : > "$ENVFILE"; chmod 600 "$ENVFILE"
emit CORE_SECRET "$CORE_SECRET"
emit JOBSERVICE_SECRET "$JOBSERVICE_SECRET"
emit REGISTRY_URL "http://127.0.0.1:$REGISTRY_PORT"
emit CORE_URL "http://127.0.0.1:$CORE_PORT"
emit REGISTRY_CONTROLLER_URL "http://127.0.0.1:$REGISTRYCTL_PORT"
emit JOBSERVICE_WEBHOOK_JOB_MAX_RETRY 3
emit JOBSERVICE_WEBHOOK_JOB_HTTP_CLIENT_TIMEOUT 3
emit LOG_LEVEL "$LOG_LEVEL"
emit HARBOR_ALLOW_PRIVATE_NETWORK_ACCESS "${HARBOR_ALLOW_PRIVATE_NETWORK_ACCESS:-true}"
emit REGISTRY_CREDENTIAL_USERNAME "$REGISTRY_USER"
emit REGISTRY_CREDENTIAL_PASSWORD "$REGISTRY_PASSWORD"
[ -n "$HTTP_PROXY" ]  && emit HTTP_PROXY "$HTTP_PROXY"
[ -n "$HTTPS_PROXY" ] && emit HTTPS_PROXY "$HTTPS_PROXY"
emit NO_PROXY "127.0.0.1,localhost${NO_PROXY:+,$NO_PROXY}"

# --- nginx: reverse proxy + static portal (portal's own nginx is folded in)
cat > "$RUN_DIR/nginx/nginx.conf" <<EOF
worker_processes auto;
pid $RUN_DIR/nginx/nginx.pid;
error_log /dev/stderr warn;

events {
  worker_connections 3096;
  multi_accept on;
}

http {
  include /etc/nginx/mime.types;
  client_body_temp_path $RUN_DIR/nginx/client_body_temp;
  proxy_temp_path $RUN_DIR/nginx/proxy_temp;
  fastcgi_temp_path $RUN_DIR/nginx/fastcgi_temp;
  uwsgi_temp_path $RUN_DIR/nginx/uwsgi_temp;
  scgi_temp_path $RUN_DIR/nginx/scgi_temp;
  tcp_nodelay on;
  proxy_http_version 1.1;

  upstream core {
    server 127.0.0.1:$CORE_PORT;
  }

  log_format timed_combined '\$remote_addr - '
    '"\$request" \$status \$body_bytes_sent '
    '"\$http_referer" "\$http_user_agent" '
    '\$request_time \$upstream_response_time \$pipe';
  access_log /dev/stdout timed_combined;

  map \$http_x_forwarded_proto \$x_forwarded_proto {
    default \$http_x_forwarded_proto;
    ""      \$scheme;
  }

  server {
    listen $PORT;
    server_tokens off;
    # disable limits to avoid HTTP 413 for large image uploads
    client_max_body_size 0;

    add_header X-Frame-Options DENY;
    add_header Content-Security-Policy "frame-ancestors 'none'";

    root /usr/share/harbor-portal;
    index index.html;

    gzip on;
    gzip_min_length 1000;
    gzip_proxied expired no-cache no-store private auth;
    gzip_types text/plain text/css application/json application/javascript application/x-javascript text/xml application/xml application/xml+rss text/javascript;

    location /devcenter-api-2.0 {
      try_files \$uri \$uri/ /swagger-ui-index.html;
    }

    location / {
      try_files \$uri \$uri/ /index.html;
    }

    location = /index.html {
      add_header Cache-Control "no-store, no-cache, must-revalidate";
      add_header X-Frame-Options DENY;
      add_header Content-Security-Policy "frame-ancestors 'none'";
    }

    location /c/ {
      proxy_pass http://core/c/;
      proxy_set_header Host \$host;
      proxy_set_header X-Real-IP \$remote_addr;
      proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto \$x_forwarded_proto;
      proxy_buffering off;
      proxy_request_buffering off;
      proxy_send_timeout 900;
      proxy_read_timeout 900;
    }

    location /api/ {
      proxy_pass http://core/api/;
      proxy_set_header Host \$host;
      proxy_set_header X-Real-IP \$remote_addr;
      proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto \$x_forwarded_proto;
      proxy_buffering off;
      proxy_request_buffering off;
    }

    location /v1/ {
      return 404;
    }

    location /v2/ {
      proxy_pass http://core/v2/;
      proxy_set_header Host \$http_host;
      proxy_set_header X-Real-IP \$remote_addr;
      proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto \$x_forwarded_proto;
      proxy_buffering off;
      proxy_request_buffering off;
      proxy_send_timeout 900;
      proxy_read_timeout 900;
    }

    location /service/ {
      proxy_pass http://core/service/;
      proxy_set_header Host \$host;
      proxy_set_header X-Real-IP \$remote_addr;
      proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto \$x_forwarded_proto;
      proxy_buffering off;
      proxy_request_buffering off;
    }

    location /service/notifications {
      return 404;
    }
  }
}
EOF

# --------------------------------------------- ownership and privilege drop
export HOME=/home/harbor
# Everything is rendered into $RUN_DIR; keep the container environment from leaking
# into the daemons (the registry in particular treats REGISTRY_* variables as config overrides).
for v in $(compgen -e); do
  case "$v" in
    DATABASE_URL|REDIS_URL|HARBOR_*|S3_*|STORAGE_BACKEND|REGISTRY_*|POSTGRESQL_*|MAX_JOB_WORKERS|LOG_LEVEL|OSC_HOSTNAME) unset "$v" ;;
  esac
done
if [ "$(id -u)" = "0" ]; then
  chown -R "$HARBOR_UID:$HARBOR_GID" "$RUN_DIR"
  chown "$HARBOR_UID:$HARBOR_GID" "$DATA_DIR"
  chown -R "$HARBOR_UID:$HARBOR_GID" "$SECRET_DIR"
  for d in registry job_logs; do
    # recursive chown only when needed (registry volumes can be large)
    if [ "$(stat -c %u "$DATA_DIR/$d")" != "$HARBOR_UID" ]; then
      chown -R "$HARBOR_UID:$HARBOR_GID" "$DATA_DIR/$d"
    fi
  done
  log "Starting as uid $HARBOR_UID"
  exec setpriv --reuid="$HARBOR_UID" --regid="$HARBOR_GID" --clear-groups "$@"
fi

# === Section 5: Execute the original command ===
exec "$@"
