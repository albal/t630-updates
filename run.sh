#!/usr/bin/env bash
# Start the firmware repository container with sensible defaults.
#
#   ./run.sh                       T630, port 80
#   MODELS=T630,R730 ./run.sh      several models
#   PORT=8080 ./run.sh             another host port
#
# Settings (environment variables):
#   MODELS      comma-separated PowerEdge models     (default: T630)
#   PORT        host port to serve on                (default: 80)
#   NAME        container name                       (default: dell-repo)
#   VOLUME      Docker volume for the firmware       (default: dell-firmware)
#   IMAGE       image to run                         (default: ghcr.io/albal/t630-updates:latest)
#   REFRESH     "yes" to re-check every file against Dell's hashes
#   EXTRA_ARGS  extra build_repo.py options, e.g. "--all-versions"
#   PULL        "no" to skip pulling the latest image
#   FOLLOW      "no" to return straight away instead of waiting for the download
set -euo pipefail

MODELS="${MODELS:-T630}"
PORT="${PORT:-80}"
NAME="${NAME:-dell-repo}"
VOLUME="${VOLUME:-dell-firmware}"
IMAGE="${IMAGE:-ghcr.io/albal/t630-updates:latest}"
REFRESH="${REFRESH:-no}"
EXTRA_ARGS="${EXTRA_ARGS:-}"
PULL="${PULL:-yes}"
FOLLOW="${FOLLOW:-yes}"

die() { echo "Error: $*" >&2; exit 1; }

command -v docker >/dev/null || die "docker is not installed"
docker info >/dev/null 2>&1 || die "can't talk to Docker (is it running, and are you in the docker group?)"

# Replace an earlier container with the same name. The volume, and so the
# downloaded firmware, is kept.
if docker container inspect "$NAME" >/dev/null 2>&1; then
  echo "Removing existing container '$NAME' (the firmware in volume '$VOLUME' is kept)"
  docker rm -f "$NAME" >/dev/null
fi

# Check the port is free now that our own container is gone.
if command -v ss >/dev/null && ss -Hltn "sport = :$PORT" | grep -q .; then
  die "port $PORT is already in use; choose another with PORT=<port> ./run.sh"
fi

if [[ "$PULL" == "yes" ]]; then
  echo "Pulling $IMAGE"
  docker pull -q "$IMAGE" >/dev/null
fi

docker run -d --name "$NAME" --restart unless-stopped \
  -p "$PORT:80" \
  -v "$VOLUME:/repo" \
  -e MODELS="$MODELS" \
  -e REFRESH="$REFRESH" \
  -e EXTRA_ARGS="$EXTRA_ARGS" \
  "$IMAGE" >/dev/null
echo "Started '$NAME' for $MODELS on port $PORT"

host_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") print $(i + 1)}')"
host_ip="${host_ip:-<this-host>}"
address="$host_ip"
[[ "$PORT" != "80" ]] && address="$host_ip:$PORT"

if [[ "$FOLLOW" == "yes" ]]; then
  echo "Waiting for the firmware download (Ctrl-C stops watching; the container keeps running)..."
  # Poll rather than follow the log: once nginx is up it may log nothing more,
  # and a "docker logs -f" pipeline would never exit.
  last=""
  while :; do
    log="$(docker logs "$NAME" 2>&1 || true)"
    # With --restart, a failing container keeps restarting and only briefly
    # shows as running, so treat any restart during startup as a failure.
    read -r status restarts < <(docker inspect -f '{{.State.Status}} {{.RestartCount}}' "$NAME" 2>/dev/null || echo "missing 0")
    if [[ "$status" != "running" || "$restarts" != "0" ]]; then
      docker update --restart no "$NAME" >/dev/null 2>&1 || true
      docker stop "$NAME" >/dev/null 2>&1 || true
      echo "$log" | tail -n 20 >&2
      die "the container failed to start and has been stopped; see the log above"
    fi
    if grep -q 'already present' <<<"$log"; then
      echo "  Firmware already downloaded"
    fi
    if grep -q '^Serving' <<<"$log"; then
      grep -E '^(Selected|Done:)' <<<"$log" | sed 's/^/  /' || true
      break
    fi
    progress="$(grep -oE '^\[[0-9]+/[0-9]+\]' <<<"$log" | tail -n 1 | tr -d '[]' || true)"
    if [[ -n "$progress" && "$progress" != "$last" ]]; then
      echo "  $progress packages"
      last="$progress"
    fi
    sleep 3
  done
fi

cat <<EOF

Firmware list:  http://$address/versions.txt

In iDRAC: iDRAC Settings > Update and Rollback > Update
  File Location:   HTTP
  HTTP Address:    $address
  Catalog fields:  leave blank
Then click "Check for Update".

Logs: docker logs -f $NAME    Stop: docker rm -f $NAME
EOF
