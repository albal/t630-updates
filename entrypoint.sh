#!/bin/sh
# Download the firmware repository from Dell into /repo (a volume), then serve
# it. The image itself contains no Dell files.
#
# Environment variables:
#   MODELS       comma-separated PowerEdge models (default: T630)
#   CATALOG_URL  Dell catalog to build from (default: last catalog with 13G)
#   EXTRA_ARGS   extra build_repo.py options, e.g. "--all-versions"
#   REFRESH      "yes" to re-check every file against Dell's hashes on start
set -eu

MODELS="${MODELS:-T630}"
CATALOG_URL="${CATALOG_URL:-https://downloads.dell.com/FOLDER14611037M/1/Catalog.xml.gz}"
EXTRA_ARGS="${EXTRA_ARGS:-}"
REFRESH="${REFRESH:-no}"
REPO=/repo
STAMP="$REPO/.build-settings"
settings="$MODELS|$CATALOG_URL|$EXTRA_ARGS"

# Skip the download when /repo was already built with the same settings.
if [ "$REFRESH" = "yes" ] || [ ! -f "$REPO/Catalog.xml" ] || [ "$(cat "$STAMP" 2>/dev/null)" != "$settings" ]; then
  echo "Building repository for $MODELS from Dell (about 5 GB per model on first run)..."
  # Remove the old catalog first, so iDRAC never sees a half-built repository.
  rm -f "$REPO/Catalog.xml" "$STAMP"
  # EXTRA_ARGS is deliberately unquoted so it can hold several options.
  # shellcheck disable=SC2086
  python3 -I /usr/local/bin/build_repo.py \
    --models "$MODELS" --catalog-url "$CATALOG_URL" --out "$REPO" $EXTRA_ARGS
  echo "$settings" > "$STAMP"
else
  echo "Repository for $MODELS already present; set REFRESH=yes to re-check it."
fi

echo "Serving $REPO on port 80. Point iDRAC's HTTP update at this host."
exec nginx -g 'daemon off;'
