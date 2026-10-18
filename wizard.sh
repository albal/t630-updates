#!/usr/bin/env bash
# Interactive setup: choose the PowerEdge models and settings, check them
# against Dell's catalog, then start the container with run.sh.
set -euo pipefail
cd "$(dirname "$0")"

IMAGE="${IMAGE:-ghcr.io/albal/t630-updates:latest}"

# 13th-generation models in Dell's final 13G catalog (26.06.01).
MODELS_13G=(
  T130 T330 T430 T630
  R230 R330 R430 R530 R530XD R630 R730 R730XD R830 R930
  M630 M630P M830 M830P
  FC430 FC630 FC830
  C4130 C6320 C6320P
)

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
die() { echo "Error: $*" >&2; exit 1; }

# ask VAR "Question" "default"
ask() {
  local reply
  read -r -p "$2 [$3]: " reply
  printf -v "$1" '%s' "${reply:-$3}"
}

[[ -t 0 ]] || die "wizard.sh needs an interactive terminal; use run.sh for scripts"
command -v docker >/dev/null || die "docker is not installed"
docker info >/dev/null 2>&1 || die "can't talk to Docker (is it running, and are you in the docker group?)"
[[ -x ./run.sh ]] || die "run.sh not found next to wizard.sh"

bold "Dell 13G firmware repository for iDRAC"
echo "This downloads Dell's final firmware for your servers and serves it to iDRAC."
echo

# --- Models ------------------------------------------------------------------
bold "1. Which PowerEdge models do you have?"
for i in "${!MODELS_13G[@]}"; do
  printf '  %2d) %-8s' "$((i + 1))" "${MODELS_13G[$i]}"
  (( (i + 1) % 4 == 0 )) && echo
done
echo
echo "Enter numbers or names separated by spaces or commas (e.g. \"4 11\" or \"T630 R730\")."
echo "Other models in the catalog can be typed by name."

selected=()
while ((${#selected[@]} == 0)); do
  read -r -p "Models [4 = T630]: " reply
  reply="${reply:-4}"
  for item in ${reply//,/ }; do
    if [[ "$item" =~ ^[0-9]+$ ]]; then
      if ((item >= 1 && item <= ${#MODELS_13G[@]})); then
        selected+=("${MODELS_13G[$((item - 1))]}")
      else
        echo "  No model number $item"
        selected=(); break
      fi
    else
      selected+=("$(echo "$item" | tr '[:lower:]' '[:upper:]')")
    fi
  done
done
# De-duplicate while keeping the order.
models="$(printf '%s\n' "${selected[@]}" | awk '!seen[$0]++' | paste -sd, -)"

# --- Check the selection against Dell's catalog -------------------------------
echo
bold "Checking $models against Dell's catalog..."
docker pull -q "$IMAGE" >/dev/null 2>&1 || docker image inspect "$IMAGE" >/dev/null 2>&1 \
  || die "can't pull $IMAGE"
if ! check="$(docker run --rm --entrypoint python3 "$IMAGE" -I /usr/local/bin/build_repo.py \
      --models "$models" --dry-run 2>&1)"; then
  echo "$check" | tail -n 3 >&2
  die "fix the model list and run the wizard again"
fi
summary="$(echo "$check" | grep '^Selected' || true)"
echo "  ${summary:-OK}"

# --- Port, names, options -----------------------------------------------------
echo
bold "2. Settings (press Enter to accept the default)"
port_default=80
if command -v ss >/dev/null && ss -Hltn "sport = :80" | grep -q . \
   && ! docker port dell-repo 2>/dev/null | grep -q ':80$'; then
  echo "  Port 80 is in use on this host, so the default is 8080."
  echo "  Note: iDRAC8's HTTP update may only work on port 80."
  port_default=8080
fi
ask port "Host port" "$port_default"
[[ "$port" =~ ^[0-9]+$ ]] && ((port >= 1 && port <= 65535)) || die "invalid port: $port"
ask name "Container name" "dell-repo"
ask volume "Volume for the downloaded firmware" "dell-firmware"

extra=""
ask all_versions "Keep every firmware version, not just the newest?" "n"
[[ "$all_versions" =~ ^[Yy] ]] && extra+=" --all-versions"
ask drivers "Include Windows OS drivers too?" "n"
[[ "$drivers" =~ ^[Yy] ]] && extra+=" --include-drivers"
extra="${extra# }"
if [[ -n "$extra" ]]; then
  echo "  The download size will be larger than the estimate above."
fi

# --- Confirm and run ----------------------------------------------------------
echo
bold "3. Summary"
cat <<EOF
  Models:     $models
  Port:       $port
  Container:  $name
  Volume:     $volume
  Options:    ${extra:-none}
  Image:      $IMAGE
EOF
if docker container inspect "$name" >/dev/null 2>&1; then
  echo "  The existing container '$name' will be replaced (its volume is kept)."
fi
echo
ask go "Start it now?" "y"
[[ "$go" =~ ^[Yy] ]] || { echo "Cancelled."; exit 0; }

echo
MODELS="$models" PORT="$port" NAME="$name" VOLUME="$volume" EXTRA_ARGS="$extra" \
  IMAGE="$IMAGE" PULL=no exec ./run.sh
