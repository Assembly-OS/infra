#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

service="${1:-}"
case "$service" in
  backend|frontend) compose_service="assembly-os-$service" ;;
  bot) compose_service=bot ;;
  *) echo "Unknown service" >&2; exit 2 ;;
esac
stage="${2:-}"
deploy_root="${3:-}"
infra_commit="${4:-}"
workflow_run="${5:-}"
ghcr_username="${6:-}"
backup_id="${7:-}"

[[ "$deploy_root" == /opt/assembly-os ]] || { echo "Invalid deploy root" >&2; exit 2; }
[[ "$stage" == "$deploy_root"/.staging/* && -d "$stage/repo" && -d "$stage/config" ]] || { echo "Invalid deployment stage" >&2; exit 2; }
cleanup() {
  [[ -z "${docker_config:-}" ]] || rm -rf -- "$docker_config"
  rm -rf -- "$stage"
  [[ -z "${override:-}" ]] || rm -f -- "$override"
}
trap cleanup EXIT
[[ "$infra_commit" =~ ^[0-9a-f]{40}$ ]] || { echo "Invalid infra commit" >&2; exit 2; }
[[ "$workflow_run" =~ ^https://github\.com/[A-Za-z0-9._/-]+/actions/runs/[0-9]+$ ]] || { echo "Invalid workflow run URL" >&2; exit 2; }
[[ "$ghcr_username" =~ ^[A-Za-z0-9-]+$ && "$backup_id" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Invalid deployment metadata" >&2; exit 2; }
[[ "$(<"$stage/repo/INFRA_COMMIT")" == "$infra_commit" ]] || { echo "Staged commit mismatch" >&2; exit 2; }

docker_config="$(mktemp -d)"
override="$(mktemp)"

manifest="$stage/repo/apps/$service/image.env"
case "$service" in
  backend) image_key=BACKEND_IMAGE; version_key=BACKEND_VERSION; image_repo=ghcr.io/assembly-os/backend; version_prefix=backend ;;
  frontend) image_key=FRONTEND_IMAGE; version_key=FRONTEND_VERSION; image_repo=ghcr.io/assembly-os/frontend; version_prefix=frontend ;;
  bot) image_key=BOT_IMAGE; version_key=BOT_VERSION; image_repo=ghcr.io/assembly-os/telegrambot; version_prefix=bot ;;
esac
image="$(awk -F= -v key="$image_key" '$1 == key { print substr($0, index($0, "=") + 1) }' "$manifest")"
version="$(awk -F= -v key="$version_key" '$1 == key { print substr($0, index($0, "=") + 1) }' "$manifest")"
[[ "${image%%@sha256:*}" == "$image_repo" && "${image#*@}" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "Manifest image is not an immutable digest" >&2; exit 2; }
[[ "$version" =~ ^${version_prefix}-[0-9a-f]{40}$ ]] || { echo "Manifest version is invalid" >&2; exit 2; }
digest="${image#*@}"
image_tag="$image_repo:$version"
if [[ "$image" == *@sha256:0000000000000000000000000000000000000000000000000000000000000000 ]]; then
  echo "$service has not been promoted yet; skipping its placeholder manifest."
  exit 0
fi

available="$(df -PB1 /var/lib/docker | awk 'NR == 2 {print $4}')"
if ! [[ "$available" =~ ^[0-9]+$ ]] || (( available < 2147483648 )); then echo "At least 2 GiB of free Docker disk space is required" >&2; exit 1; fi

[[ -f /var/lib/assembly-os/restore-verified ]] || { echo "Data restore must be approved and verified first" >&2; exit 1; }
python3 "$stage/repo/scripts/project-db.py" check --require-restored --config "$stage/config/database.json"
install -d -o root -g root -m 0755 "$deploy_root/current" /var/lib/assembly-os/deployments
rsync -a --delete "$stage/repo/" "$deploy_root/current/"
for env_file in backend.env frontend.env bot.env caddy.env backup.env compose.env database.json; do
  [[ -f "$stage/config/$env_file" ]] || { echo "Missing rendered runtime configuration" >&2; exit 2; }
  # Backend/frontend deploys can render without BOT_TOKEN. Preserve the bot's
  # installed credentials until a bot deployment explicitly replaces them.
  if [[ "$env_file" == bot.env && "$service" != bot && -f "/etc/assembly-os/$env_file" ]]; then
    continue
  fi
  install -o root -g root -m 0600 "$stage/config/$env_file" "/etc/assembly-os/$env_file"
done
install -o root -g root -m 0755 "$deploy_root/current/scripts/project-db.py" /usr/local/sbin/assembly-os-project-db
install -o root -g root -m 0755 "$deploy_root/current/scripts/backup.sh" /usr/local/sbin/assembly-os-backup
install -o root -g root -m 0755 "$deploy_root/current/scripts/restore-media.py" /usr/local/sbin/assembly-os-restore-media
install -o root -g root -m 0755 "$deploy_root/current/scripts/restore.sh" /usr/local/sbin/assembly-os-restore
install -o root -g root -m 0644 "$deploy_root/current/systemd/assembly-os-backup.service" /etc/systemd/system/assembly-os-backup.service
install -o root -g root -m 0644 "$deploy_root/current/systemd/assembly-os-backup.timer" /etc/systemd/system/assembly-os-backup.timer
systemctl daemon-reload
systemctl enable assembly-os-backup.timer
systemctl restart assembly-os-backup.timer

export DOCKER_CONFIG="$docker_config"
docker login ghcr.io --username "$ghcr_username" --password-stdin < "$stage/secrets/ghcr-token"

compose=(docker compose -p assembly-os
  --env-file /etc/assembly-os/compose.env
  --env-file "$deploy_root/current/apps/backend/image.env"
  --env-file "$deploy_root/current/apps/frontend/image.env"
  --env-file "$deploy_root/current/apps/bot/image.env"
  -f "$deploy_root/current/compose.yaml")
"${compose[@]}" config --quiet

caddy_image="$("${compose[@]}" config --images | grep '^caddy:' | head -n1)"
[[ "$caddy_image" == caddy@sha256:* || "$caddy_image" == caddy:*@sha256:* ]] || { echo "Caddy image is not digest-pinned" >&2; exit 2; }
docker pull "$caddy_image"
# Validate in a one-shot container with no published ports and no dependent services.
"${compose[@]}" run --rm --no-deps assembly-os-proxy caddy validate --config /etc/caddy/Caddyfile

wait_healthy() {
  local target="$1" id status
  for _ in $(seq 1 36); do
    case "$target" in backend|frontend) target="assembly-os-$target" ;; esac
    id="$("${compose[@]}" ps -q "$target")"
    if [[ -n "$id" ]]; then
      status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$id")"
      [[ "$status" == healthy ]] && return 0
      [[ "$status" == exited || "$status" == dead || "$status" == unhealthy ]] && return 1
    fi
    sleep 5
  done
  return 1
}

# `--no-deps` is what lets this script recreate only the promoted service.
# Preserve Compose's dependency contract explicitly before starting a consumer.
if [[ "$service" != backend ]] && ! wait_healthy backend; then
  echo "Backend must be healthy before deploying $service" >&2
  exit 1
fi

if [[ "$service" == backend ]]; then
  /usr/local/sbin/assembly-os-backup predeploy "$backup_id"
fi

container_id="$("${compose[@]}" ps -q "$compose_service")"
old_image=""
if [[ -n "$container_id" ]]; then
  old_image="$(docker inspect --format '{{.Config.Image}}' "$container_id")"
fi

docker pull "$image"
"${compose[@]}" up -d --no-deps --force-recreate "$compose_service"

if ! wait_healthy "$service"; then
  echo "$service failed its health check; rolling back" >&2
  if [[ -n "$old_image" ]]; then
    printf 'services:\n  %s:\n    image: %s\n' "$compose_service" "$old_image" > "$override"
    rollback=("${compose[@]}" -f "$override")
    "${rollback[@]}" up -d --no-deps --force-recreate "$compose_service"
    wait_healthy "$service" || echo "The rollback image also failed its health check" >&2
  else
    "${compose[@]}" rm -sf "$compose_service"
  fi
  exit 1
fi

running_id="$("${compose[@]}" ps -q "$compose_service")"
running_image="$(docker inspect --format '{{.Config.Image}}' "$running_id")"
[[ "$running_image" == "$image" ]] || { echo "Running image does not match desired digest" >&2; exit 1; }

"${compose[@]}" up -d --no-deps assembly-os-proxy
wait_healthy assembly-os-proxy || { echo "Caddy failed its health check" >&2; exit 1; }
# A previous rsync can replace the host file inode while an existing container
# still bind-mounts the old inode. Reload the current source through stdin.
"${compose[@]}" exec -T assembly-os-proxy caddy reload --config /dev/stdin --adapter caddyfile < "$deploy_root/current/Caddyfile"

timestamp="$(date -u +%FT%TZ)"
record="/var/lib/assembly-os/deployments/$service.json"
printf '{\n  "service": "%s",\n  "infra_commit": "%s",\n  "version": "%s",\n  "image_tag": "%s",\n  "digest": "%s",\n  "image": "%s",\n  "workflow_run": "%s",\n  "deployed_at": "%s"\n}\n' \
  "$service" "$infra_commit" "$version" "$image_tag" "$digest" "$image" \
  "$workflow_run" "$timestamp" > "$record"
chmod 0644 "$record"
echo "Deployed $service at $image"
