#!/bin/bash
# Minimal supervisor: starts all Harbor processes, stops everything and exits
# non-zero as soon as any of them dies (so the platform restarts the container).
RUN_DIR=/run/harbor
# shellcheck disable=SC1091
. "$RUN_DIR/ports.env"
pids=()
names=()

start() {  # name envfile command...
  local name="$1" envfile="$2"; shift 2
  (
    set -a
    # shellcheck disable=SC1090
    . "$envfile"
    set +a
    exec "$@" > >(sed -u "s/^/[$name] /") 2>&1
  ) &
  pids+=("$!"); names+=("$name")
}

shutdown() {
  trap - TERM INT
  echo "[supervisor] stopping..."
  kill -TERM "${pids[@]}" 2>/dev/null
  sleep 2
  kill -KILL "${pids[@]}" 2>/dev/null
  exit "${1:-0}"
}
trap 'shutdown 0' TERM INT

# A daemon can be alive without listening (e.g. registryctl hangs silently after a
# bind error), so verify each port and fail loudly instead of reporting a half-working Harbor.
# probe PORT [PATH]: with a PATH, require HTTP 200 (so another process squatting on the
# port, e.g. a PORT clash with nginx, is not mistaken for the daemon).
probe() {
  (
    local resp
    exec 3<>"/dev/tcp/127.0.0.1/$1" || exit 1
    [ -n "$2" ] || exit 0
    printf 'GET %s HTTP/1.0\r\nHost: localhost\r\n\r\n' "$2" >&3
    read -r -t 3 resp <&3
    [[ "$resp" == *" 200 "* ]]
  ) 2>/dev/null
}
wait_listen() {  # name port pid [path]
  local name="$1" port="$2" pid="$3" path="$4" max="${HARBOR_PORT_TIMEOUT:-60}" waited=0
  until probe "$port" "$path"; do
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "[supervisor] ERROR: $name exited before listening on 127.0.0.1:$port" >&2; shutdown 1
    fi
    if [ "$waited" -ge "$max" ]; then
      echo "[supervisor] ERROR: $name is running but not serving on 127.0.0.1:$port${path} after ${max}s (port conflict or startup hang); exiting" >&2
      shutdown 1
    fi
    sleep 1; waited=$((waited + 1))
  done
  echo "[supervisor] $name serving on 127.0.0.1:$port"
}

cd /harbor
start registry    "$RUN_DIR/registry/env"    /usr/bin/registry_DO_NOT_USE_GC serve "$RUN_DIR/registry/config.yml"
start registryctl "$RUN_DIR/registryctl/env" /harbor/harbor_registryctl -c "$RUN_DIR/registryctl/config.yml"
start core        "$RUN_DIR/core/env"        /harbor/harbor_core
start nginx       /dev/null                  nginx -e /dev/stderr -c "$RUN_DIR/nginx/nginx.conf" -g 'daemon off;'

wait_listen registry    "$REGISTRY_PORT"    "${pids[0]}" /
wait_listen registryctl "$REGISTRYCTL_PORT" "${pids[1]}" /api/health
wait_listen nginx       "$NGINX_PORT"       "${pids[3]}" /

# jobservice fetches its configuration from core at startup, so wait until core
# answers (DB migrations on first start can take a while).
core_pid="${pids[2]}"
core_ready() {
  (
    local resp
    exec 3<>/dev/tcp/127.0.0.1/$CORE_PORT || exit 1
    printf 'GET /api/v2.0/ping HTTP/1.0\r\nHost: localhost\r\n\r\n' >&3
    read -r -t 3 resp <&3
    [[ "$resp" == *" 200 "* ]]
  ) 2>/dev/null
}
waited=0
until core_ready; do
  if ! kill -0 "$core_pid" 2>/dev/null; then
    echo "[supervisor] core exited during startup" >&2
    shutdown 1
  fi
  if [ "$waited" -ge "${HARBOR_CORE_START_TIMEOUT:-300}" ]; then
    echo "[supervisor] core did not become ready in time" >&2
    shutdown 1
  fi
  sleep 2; waited=$((waited + 2))
done
echo "[supervisor] core is ready"
start jobservice  "$RUN_DIR/jobservice/env"  /harbor/harbor_jobservice -c "$RUN_DIR/jobservice/config.yml"
wait_listen jobservice "$JOBSERVICE_PORT" "${pids[4]}"

echo "[supervisor] all processes started: ${names[*]}"
wait -n
rc=$?
echo "[supervisor] a process exited (status $rc), shutting down" >&2
shutdown $((rc == 0 ? 1 : rc))
