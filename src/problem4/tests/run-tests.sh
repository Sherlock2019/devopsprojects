#!/usr/bin/env bash
# Offline tests for the Problem 4 deploy scripts. No AWS account needed.
# Requires: bash, jq, curl, docker (for the backend tests). Uses host port 18081.
#
#   bash tests/run-tests.sh
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
scripts="$here/../scripts"
export PATH="$here/aws-stub:$PATH"
chmod +x "$here/aws-stub/aws"
pass=0; fail=0
check() { if eval "$2"; then echo "PASS  $1"; pass=$((pass + 1)); else echo "FAIL  $1"; fail=$((fail + 1)); fi; }
new_stub() { STUB_DIR="$(mktemp -d)"; export STUB_DIR; }

echo "== frontend: deploy-frontend.sh"
new_stub
dist="$(mktemp -d)"; mkdir -p "$dist/assets"
echo '<html>v1</html>' >"$dist/index.html"; echo 'console.log(1)' >"$dist/assets/app.3f9a.js"
DIST_DIR="$dist" S3_BUCKET=demo-bucket ENVIRONMENT=staging RELEASE_ID=abc123 API_BASE_URL=https://api.staging.example.com \
  CLOUDFRONT_DISTRIBUTION_ID=E123 bash "$scripts/deploy-frontend.sh" >"$STUB_DIR/out" 2>&1
check "frontend deploy exits 0" "[ $? -eq 0 ]"
check "config.json carries env, API URL and release" \
  "jq -e '.environment==\"staging\" and .apiBaseUrl==\"https://api.staging.example.com\" and .release==\"abc123\"' '$dist/config.json' >/dev/null"
order_ok() {
  local log="$STUB_DIR/calls.log" upload index prune
  upload="$(grep -n 's3 sync' "$log" | grep -v -- '--delete' | head -1 | cut -d: -f1)"
  index="$(grep -n 'index.html s3://' "$log" | cut -d: -f1)"
  prune="$(grep -n 's3 sync.*--delete' "$log" | cut -d: -f1)"
  [[ -n "$upload" && -n "$index" && -n "$prune" ]] && ((upload < index && index < prune))
}
check "assets uploaded before index.html, prune last" order_ok
check "index.html uploaded with no-cache" "grep 'index.html s3://demo-bucket/index.html' '$STUB_DIR/calls.log' | grep -q no-cache"
check "CloudFront invalidates entry points and waits" \
  "grep -q 'create-invalidation --distribution-id E123 --paths /index.html /config.json' '$STUB_DIR/calls.log' && grep -q 'cloudfront wait invalidation-completed' '$STUB_DIR/calls.log'"
new_stub; empty="$(mktemp -d)"
DIST_DIR="$empty" S3_BUCKET=b ENVIRONMENT=dev RELEASE_ID=x bash "$scripts/deploy-frontend.sh" >/dev/null 2>&1
check "frontend refuses a build without index.html" "[ $? -ne 0 ] && [ ! -s '$STUB_DIR/calls.log' ]"

echo "== backend: deploy-backend.sh (+ ec2-deploy-container.sh through simulated SSM)"
if ! docker info >/dev/null 2>&1; then echo "SKIP  docker not available"; else
  docker pull -q nginx:1.25 >/dev/null; docker pull -q redis:7 >/dev/null
  good="$(docker inspect --format '{{index .RepoDigests 0}}' nginx:1.25)"
  bad="$(docker inspect --format '{{index .RepoDigests 0}}' redis:7)"   # no HTTP server -> fails health check
  name="p4test-backend"; docker rm -f "$name" >/dev/null 2>&1
  common=(AWS_REGION=ap-southeast-1 EC2_INSTANCE_ID=i-0123456789abcdef0 CONTAINER_NAME="$name"
          HOST_PORT=18081 APP_PORT=80 HEALTH_PATH=/ HEALTH_TIMEOUT=10 SSM_TIMEOUT=60)

  new_stub
  env "${common[@]}" IMAGE=nginx:1.25 bash "$scripts/deploy-backend.sh" >"$STUB_DIR/out" 2>&1
  check "rejects an image that is not pinned by digest" "[ $? -ne 0 ] && grep -q 'pinned by digest' '$STUB_DIR/out'"

  new_stub
  env "${common[@]}" IMAGE="$good" bash "$scripts/deploy-backend.sh" >"$STUB_DIR/out" 2>&1
  check "deploys good image via SSM payload (exit 0)" "[ $? -eq 0 ] && grep -q 'DEPLOY OK' '$STUB_DIR/out'"
  check "container serves on :18081" "curl -fsS -o /dev/null http://127.0.0.1:18081/"
  check "running image is the requested digest" "[ \"\$(docker inspect -f '{{.Config.Image}}' $name)\" = '$good' ]"

  new_stub
  env "${common[@]}" IMAGE="$bad" bash "$scripts/deploy-backend.sh" >"$STUB_DIR/out" 2>&1
  check "unhealthy image fails the deploy (exit 1)" "[ $? -ne 0 ] && grep -q 'DEPLOY FAILED' '$STUB_DIR/out'"
  check "automatic rollback to previous image" "grep -q 'ROLLBACK OK' '$STUB_DIR/out'"
  check "service still up after rollback" "curl -fsS -o /dev/null http://127.0.0.1:18081/ && [ \"\$(docker inspect -f '{{.Config.Image}}' $name)\" = '$good' ]"

  new_stub
  env "${common[@]}" IMAGE="$good" HEALTHCHECK_URL=http://127.0.0.1:18081/ bash "$scripts/deploy-backend.sh" >"$STUB_DIR/out" 2>&1
  check "redeploy + public smoke test" "[ $? -eq 0 ]"
  docker rm -f "$name" >/dev/null 2>&1
fi

echo "== summary: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
