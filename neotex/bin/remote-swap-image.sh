#!/bin/bash
# Runs ON the Vikunja box (as root, via SSM AWS-RunShellScript), with IMAGE set
# by neotex/bin/deploy. Pulls $IMAGE, then points the compose file's vikunja
# service at it and recreates the container. The db service is left alone.
# The pull comes first: a compose file naming an image that cannot be pulled
# would keep Vikunja down at the next reboot.
set -eu

compose=${COMPOSE_FILE_PATH:-/data/docker-compose.yml}
dir=$(dirname "$compose")

if ! awk -v img="$IMAGE" '
  /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { service = $1 }
  service == "vikunja:" && !done && /^    image:/ { print "    image: " img; done = 1; next }
  { print }
  END { if (!done) exit 3 }
' "$compose" > "$compose.new"; then
  rm -f "$compose.new"
  echo "remote-swap-image: no image line for the vikunja service in $compose" >&2
  exit 1
fi

if ! docker pull "$IMAGE"; then
  rm -f "$compose.new"
  echo "remote-swap-image: could not pull $IMAGE; compose file left unchanged" >&2
  exit 1
fi
mv "$compose.new" "$compose"

cd "$dir"
docker compose --env-file "$dir/.env" --env-file "$dir/mailer.env" up -d
