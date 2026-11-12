#!/usr/bin/env bash
# Runs ON the EC2 host. deploy-backend.sh ships this file through SSM Run Command (AWS-RunShellScript runs as root).
# Pulls IMAGE (pinned by digest), replaces the running container, health-checks it locally,
# and automatically rolls back to the previous image if the new one is unhealthy.
#
# Host prerequisites: docker, curl, AWS CLI v2, SSM agent, an instance profile allowing ECR pull
# (and ssm:GetParametersByPath on SSM_ENV_PATH if used).
#
# Inputs (environment variables):
#   IMAGE           required  e.g. 123456789012.dkr.ecr.ap-southeast-1.amazonaws.com/backend@sha256:...
#   CONTAINER_NAME  default   backend
#   HOST_PORT       default   80
#   APP_PORT        default   3000
#   HEALTH_PATH     default   /health
#   HEALTH_TIMEOUT  default   60 (seconds)
#   SSM_ENV_PATH    optional  SSM Parameter Store path; each parameter becomes NAME=value in the container env
#   STATE_DIR       default   /var/lib/deploy/$CONTAINER_NAME (records current/previous image)
set -euo pipefail

: "${IMAGE:?IMAGE is required}"
CONTAINER_NAME="${CONTAINER_NAME:-backend}"
HOST_PORT="${HOST_PORT:-80}"
APP_PORT="${APP_PORT:-3000}"
HEALTH_PATH="${HEALTH_PATH:-/health}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-60}"
STATE_DIR="${STATE_DIR:-/var/lib/deploy/${CONTAINER_NAME}}"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }

registry="${IMAGE%%/*}"
if [[ "$registry" == *.dkr.ecr.*.amazonaws.com ]]; then
  region="$(echo "$registry" | cut -d. -f4)"
  log "Logging in to ECR ${registry}"
  aws ecr get-login-password --region "$region" | docker login --username AWS --password-stdin "$registry" >/dev/null
fi

log "Pulling ${IMAGE}"
docker pull "$IMAGE" >/dev/null

env_file="$(mktemp)"
chmod 600 "$env_file"
trap 'rm -f "$env_file"' EXIT
if [[ -n "${SSM_ENV_PATH:-}" ]]; then
  log "Loading runtime configuration from SSM path ${SSM_ENV_PATH}"
  aws ssm get-parameters-by-path --path "$SSM_ENV_PATH" --recursive --with-decryption \
    --query 'Parameters[].[Name,Value]' --output text |
    while IFS=$'\t' read -r name value; do printf '%s=%s\n' "${name##*/}" "$value"; done >"$env_file"
fi

previous="$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null || true)"
log "Previous image: ${previous:-<none>}"

run_container() {
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  docker run -d --name "$CONTAINER_NAME" --restart unless-stopped \
    -p "${HOST_PORT}:${APP_PORT}" --env-file "$env_file" \
    --log-opt max-size=50m --log-opt max-file=5 \
    "$1" >/dev/null
}

healthy() {
  local deadline=$((SECONDS + HEALTH_TIMEOUT))
  while ((SECONDS < deadline)); do
    if curl -fsS -o /dev/null --max-time 3 "http://127.0.0.1:${HOST_PORT}${HEALTH_PATH}"; then
      return 0
    fi
    sleep 2
  done
  return 1
}

log "Starting ${IMAGE}"
run_container "$IMAGE"

if healthy; then
  if mkdir -p "$STATE_DIR" 2>/dev/null && [[ -w "$STATE_DIR" ]]; then
    if [[ -n "$previous" && "$previous" != "$IMAGE" ]]; then echo "$previous" >"$STATE_DIR/previous"; fi
    echo "$IMAGE" >"$STATE_DIR/current"
  else
    log "warning: cannot record release state in $STATE_DIR"
  fi
  docker image prune -f >/dev/null || true
  log "DEPLOY OK: ${IMAGE} healthy on :${HOST_PORT}${HEALTH_PATH}"
  exit 0
fi

log "DEPLOY FAILED: ${IMAGE} not healthy within ${HEALTH_TIMEOUT}s. Last container logs:"
docker logs --tail 50 "$CONTAINER_NAME" 2>&1 || true

if [[ -n "$previous" && "$previous" != "$IMAGE" ]]; then
  log "Rolling back to ${previous}"
  run_container "$previous"
  if healthy; then
    log "ROLLBACK OK: ${previous} restored"
  else
    log "ROLLBACK FAILED: ${previous} also unhealthy, manual action required"
  fi
else
  log "No previous image to roll back to"
fi
exit 1
