#!/usr/bin/env bash
set -uo pipefail
ulimit -n 65535 2>/dev/null || ulimit -n 16384 2>/dev/null || true   # many users at once
DATA="${JINX_DATA:-/data}"          # persistent volume (Deplexo mounts it at /data by default)
RUN="${JINX_RUN:-/tmp/jinx}"        # small scratch files (pids, status); /tmp is writable but limited to 100 MB
NGX=/tmp/nginx                      # nginx config + temp folders (the root filesystem is read-only)
MODE="$(echo "${JINX_MODE:-panel}" | tr 'A-Z' 'a-z')"

# ---- the volume must be writable by the user this container runs as, otherwise nothing can be saved ----
mkdir -p "$DATA" 2>/dev/null
if ! touch "$DATA/.write-test" 2>/dev/null; then
  echo "[jinx] ERROR: $DATA is not writable. In Deplexo > your app > Storage keep the data mount path at /data."
  echo "[jinx]        running as: $(id)"; ls -ld "$DATA" 2>&1
  exit 1
fi
rm -f "$DATA/.write-test"
mkdir -p "$DATA/node-certs" "$DATA/pg-node" "$RUN" "$NGX/body" "$NGX/proxy" "$NGX/fastcgi" "$NGX/uwsgi" "$NGX/scgi"
rm -f "$RUN"/*.pid "$RUN/fatal"
: > "$RUN/host.log"; chmod 666 "$RUN/host.log"

# the platform may inject its own PORT; nginx answers on it too, the domain target stays 8080
RPORT="${PORT:-8080}"; case "$RPORT" in ''|*[!0-9]*) RPORT=8080;; esac
# never take a port the parts inside use (panel 8000, fast ping 8099, owner service 8100/8101, core 62050, configs 10001-10099)
if [ "$RPORT" -eq 8000 ] || [ "$RPORT" -eq 8099 ] || [ "$RPORT" -eq 8100 ] || [ "$RPORT" -eq 8101 ] || [ "$RPORT" -eq 62050 ] \
   || { [ "$RPORT" -ge 10001 ] && [ "$RPORT" -le 10099 ]; } || [ "$RPORT" -lt 1 ] || [ "$RPORT" -gt 65535 ]; then RPORT=8080; fi
export PORT=8080
export JINX_RPORT="$RPORT"
export JINX_DATA="$DATA" JINX_RUN="$RUN" JINX_MODE="$MODE"
echo "[jinx] mode: $MODE | domain: ${PUBLIC_DOMAIN:-learned from the first visit} | memory limit: $(cat /sys/fs/cgroup/memory.max 2>/dev/null || echo unknown)"

# owner admin/admin is written by bootstrap.py on FIRST boot only
unset SUDO_USERNAME SUDO_PASSWORD

# ---- keep the tiny host.log from filling /tmp (it only has to hold a few visits until the domain is learned) ----
( while true; do
    sleep 60
    s=$(stat -c %s "$RUN/host.log" 2>/dev/null || echo 0)
    [ "$s" -gt 262144 ] && : > "$RUN/host.log"
  done ) &

if [ "$MODE" = "node" ]; then
  # ---- location mode: only core + nginx, files come from JINX_CODE (needs a reachable TCP port, not available on Deplexo) ----
  python /code/jinxnode.py setup 2>&1 || exit 1
  NODE_LISTEN=0.0.0.0
else
  # ---- node secrets: generated once, kept on the volume ----
  [ -f "$DATA/node_api_key" ] || python -c "import uuid;print(uuid.uuid4())" > "$DATA/node_api_key"
  if [ ! -f "$DATA/node-certs/cert.pem" ] || [ ! -f "$DATA/node-certs/.san2" ]; then
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
      -keyout "$DATA/node-certs/key.pem" -out "$DATA/node-certs/cert.pem" -subj "/CN=jinx-node" \
      -addext "subjectAltName=IP:127.0.0.1,DNS:localhost" >/dev/null 2>&1 \
      && touch "$DATA/node-certs/.san2"
  fi
  NODE_LISTEN=127.0.0.1
  EXTRA=""; [ "$RPORT" != "$PORT" ] && EXTRA="listen ${RPORT};"
  sed -e "s|__PORT__|${PORT}|g" -e "s|#__EXTRA_LISTEN__|${EXTRA}|" \
      -e "s|__DATA__|${DATA}|g" -e "s|__RUN__|${RUN}|g" -e "s|__TMP__|${NGX}|g" \
      /etc/nginx/nginx.conf.template > "$NGX/nginx.conf"
fi

# ---- unique config paths for this install (kept on the volume / taken from the code) ----
python /code/genpaths.py 2>&1 || exit 1
nginx -e /dev/stderr -c "$NGX/nginx.conf" -t 2>&1 || exit 1

# ---- supervisor: keeps ONE part alive; guard.py restarts a broken part by stopping it ----
supervise() {   # supervise <name> <command...>
  local name="$1"; shift
  while [ ! -f "$RUN/fatal" ]; do
    "$@" &
    echo $! > "$RUN/$name.pid"
    wait $!
    echo "[jinx] $name stopped, starting again in 3s"
    sleep 3
  done
}

run_node()  { cd /opt/pg-node && SERVICE_PORT=62050 NODE_HOST=$NODE_LISTEN SERVICE_PROTOCOL=grpc \
                API_KEY="$(cat $DATA/node_api_key)" \
                SSL_CERT_FILE="$DATA/node-certs/cert.pem" SSL_KEY_FILE="$DATA/node-certs/key.pem" \
                exec ./main 2>&1; }
run_panel() { cd /code && exec python main.py 2>&1; }
run_nginx() { exec nginx -e /dev/stderr -c "$NGX/nginx.conf" -g 'daemon off;' 2>&1; }
run_boot()  { cd /code && exec python bootstrap.py 2>&1; }
run_join()  { cd /code && exec python jinxnode.py join 2>&1; }
run_guard() { cd /code && exec python guard.py 2>&1; }

# nginx first: the health check and the "getting ready" page on the domain answer within seconds
supervise nginx run_nginx &
if [ "$MODE" != "node" ]; then
  ( cd /code && python -m alembic upgrade head 2>&1 ) || echo "[jinx] migration warning, panel will retry"
fi
supervise node  run_node  &
if [ "$MODE" = "node" ]; then
  supervise join run_join &   # checks in with the panel every minute
else
  supervise panel run_panel &
  supervise boot  run_boot  &   # auto setup + owner key + locations
fi
supervise guard run_guard &   # guard bots + /jx-status

# ---- last line of defence: full service restart only if guard asks for it,
#      or the whole service does not answer for ~3 minutes ----
sleep 120; fails=0
while true; do
  if [ -f "$RUN/fatal" ]; then echo "[jinx] guard asked for a full restart ($(cat $RUN/fatal))"; break; fi
  if /usr/local/bin/jinx-healthcheck; then fails=0; else fails=$((fails+1)); fi
  if [ "$fails" -ge 6 ]; then echo "[jinx] watchdog: service not answering, restarting"; break; fi
  sleep 30
done
touch "$RUN/fatal"
for f in "$RUN"/*.pid; do kill "$(cat "$f")" 2>/dev/null; done
exit 1
