#!/usr/bin/env bash
# Runs on the GitHub Actions runner (after OIDC credentials are configured).
# Deploys a backend image, pinned by digest, to one EC2 instance through SSM Run Command (no SSH, no inbound ports),
# then optionally smoke-tests the public health URL.
#
# Inputs (environment variables):
#   AWS_REGION        required
#   EC2_INSTANCE_ID   required  i-0123456789abcdef0
#   IMAGE             required  must contain @sha256: (build once, promote the same digest)
#   CONTAINER_NAME, HOST_PORT, APP_PORT, HEALTH_PATH, HEALTH_TIMEOUT, SSM_ENV_PATH   passed to the host script
#   HEALTHCHECK_URL   optional  public URL checked from the runner after deploy (e.g. https://api.dev.example.com/health)
#   SSM_TIMEOUT       default   600 seconds
#   DRY_RUN=1         print the SSM request instead of calling AWS (for local testing)
set -euo pipefail

: "${AWS_REGION:?AWS_REGION is required}"
: "${EC2_INSTANCE_ID:?EC2_INSTANCE_ID is required}"
: "${IMAGE:?IMAGE is required}"
SSM_TIMEOUT="${SSM_TIMEOUT:-600}"

if [[ "$IMAGE" != *@sha256:* ]]; then
  echo "::error::IMAGE must be pinned by digest (repo@sha256:...), got: $IMAGE" >&2
  exit 1
fi

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script_b64="$(base64 -w0 "$here/ec2-deploy-container.sh")"

# Variables for the host script; %q-quoting keeps values safe inside the remote shell.
host_env="$(printf 'IMAGE=%q CONTAINER_NAME=%q HOST_PORT=%q APP_PORT=%q HEALTH_PATH=%q HEALTH_TIMEOUT=%q SSM_ENV_PATH=%q' \
  "$IMAGE" "${CONTAINER_NAME:-backend}" "${HOST_PORT:-80}" "${APP_PORT:-3000}" \
  "${HEALTH_PATH:-/health}" "${HEALTH_TIMEOUT:-60}" "${SSM_ENV_PATH:-}")"

params="$(jq -n --arg b64 "$script_b64" --arg env "$host_env" '{
  commands: [
    "f=$(mktemp) || exit 1",
    ("echo " + $b64 + " | base64 -d > \"$f\" || { rm -f \"$f\"; exit 1; }"),
    ("env " + $env + " bash \"$f\""),
    "rc=$?; rm -f \"$f\"; exit $rc"
  ]
}')"

comment="deploy ${GITHUB_REPOSITORY:-local}@${GITHUB_SHA:-unknown} run ${GITHUB_RUN_ID:-0}"

if [[ "${DRY_RUN:-0}" == "1" ]]; then
  echo "DRY RUN: aws ssm send-command --region $AWS_REGION --instance-ids $EC2_INSTANCE_ID --document-name AWS-RunShellScript --comment '${comment:0:100}'"
  echo "$params" | jq '.commands |= map(if length > 120 then .[0:120] + "...(truncated)" else . end)'
  exit 0
fi

echo "Sending deploy of $IMAGE to $EC2_INSTANCE_ID"
command_id="$(aws ssm send-command \
  --region "$AWS_REGION" \
  --instance-ids "$EC2_INSTANCE_ID" \
  --document-name AWS-RunShellScript \
  --comment "${comment:0:100}" \
  --timeout-seconds "$SSM_TIMEOUT" \
  --parameters "$params" \
  --query 'Command.CommandId' --output text)"
echo "SSM command id: $command_id"

status="Pending"
deadline=$((SECONDS + SSM_TIMEOUT + 60))
while ((SECONDS < deadline)); do
  sleep 5
  status="$(aws ssm get-command-invocation --region "$AWS_REGION" \
    --command-id "$command_id" --instance-id "$EC2_INSTANCE_ID" \
    --query 'Status' --output text 2>/dev/null || echo Pending)"
  case "$status" in
    Pending | InProgress | Delayed) continue ;;
    *) break ;;
  esac
done

echo "----- host output -----"
aws ssm get-command-invocation --region "$AWS_REGION" --command-id "$command_id" \
  --instance-id "$EC2_INSTANCE_ID" --query 'StandardOutputContent' --output text || true
echo "----- host errors -----"
aws ssm get-command-invocation --region "$AWS_REGION" --command-id "$command_id" \
  --instance-id "$EC2_INSTANCE_ID" --query 'StandardErrorContent' --output text || true

if [[ "$status" != "Success" ]]; then
  echo "::error::Deploy failed on $EC2_INSTANCE_ID (SSM status: $status). The host script rolls back automatically when it can." >&2
  exit 1
fi

if [[ -n "${HEALTHCHECK_URL:-}" ]]; then
  echo "Smoke test: $HEALTHCHECK_URL"
  curl -fsS --retry 10 --retry-delay 3 --retry-all-errors --max-time 5 -o /dev/null "$HEALTHCHECK_URL"
fi
echo "Backend deploy OK: $IMAGE"
