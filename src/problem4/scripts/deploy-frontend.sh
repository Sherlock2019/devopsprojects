#!/usr/bin/env bash
# Runs on the GitHub Actions runner (after OIDC credentials are configured).
# Publishes an already-built static frontend to S3 and invalidates CloudFront.
# The same build artifact is promoted to every environment; only config.json differs.
#
# Inputs (environment variables):
#   DIST_DIR                    required  directory containing index.html
#   S3_BUCKET                   required  bucket name (no s3://)
#   ENVIRONMENT                 required  dev | staging | production
#   RELEASE_ID                  required  e.g. commit SHA or artifact checksum, written into config.json
#   API_BASE_URL                optional  written into config.json (non-secret values ONLY)
#   CLOUDFRONT_DISTRIBUTION_ID  optional  invalidate index.html and config.json
#   SITE_URL                    optional  public URL smoke-tested after deploy
#   PRUNE                       default 1: delete objects no longer in the build (after the new index is live)
#   DRY_RUN=1                   print the AWS commands instead of running them
set -euo pipefail

: "${DIST_DIR:?DIST_DIR is required}"
: "${S3_BUCKET:?S3_BUCKET is required}"
: "${ENVIRONMENT:?ENVIRONMENT is required}"
: "${RELEASE_ID:?RELEASE_ID is required}"
PRUNE="${PRUNE:-1}"

aws_cmd() {
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    echo "DRY RUN: aws $*"
  else
    aws "$@"
  fi
}

[[ -f "$DIST_DIR/index.html" ]] || { echo "::error::$DIST_DIR/index.html not found" >&2; exit 1; }

# 1. Runtime config. The SPA must fetch /config.json at startup instead of baking URLs into the bundle.
jq -n --arg api "${API_BASE_URL:-}" --arg env "$ENVIRONMENT" --arg rel "$RELEASE_ID" \
  '{apiBaseUrl: $api, environment: $env, release: $rel}' >"$DIST_DIR/config.json"
echo "config.json: $(cat "$DIST_DIR/config.json")"

dest="s3://${S3_BUCKET}"

# 2. Upload assets first (long cache: bundlers emit content-hashed file names). Nothing is deleted yet,
#    so users still holding the old index.html can load its assets.
aws_cmd s3 sync "$DIST_DIR" "$dest" --only-show-errors \
  --exclude index.html --exclude config.json \
  --cache-control "public,max-age=31536000,immutable"

# 3. Switch the entry points (never cached).
aws_cmd s3 cp "$DIST_DIR/config.json" "$dest/config.json" --only-show-errors \
  --cache-control "no-cache,no-store,must-revalidate" --content-type application/json
aws_cmd s3 cp "$DIST_DIR/index.html" "$dest/index.html" --only-show-errors \
  --cache-control "no-cache,no-store,must-revalidate" --content-type "text/html; charset=utf-8"

# 4. Invalidate the uncached entry points at the edge.
if [[ -n "${CLOUDFRONT_DISTRIBUTION_ID:-}" ]]; then
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    aws_cmd cloudfront create-invalidation --distribution-id "$CLOUDFRONT_DISTRIBUTION_ID" --paths /index.html /config.json
  else
    inv_id="$(aws cloudfront create-invalidation --distribution-id "$CLOUDFRONT_DISTRIBUTION_ID" \
      --paths /index.html /config.json --query 'Invalidation.Id' --output text)"
    echo "CloudFront invalidation $inv_id, waiting..."
    aws cloudfront wait invalidation-completed --distribution-id "$CLOUDFRONT_DISTRIBUTION_ID" --id "$inv_id"
  fi
fi

# 5. Remove objects from older builds.
if [[ "$PRUNE" == "1" ]]; then
  aws_cmd s3 sync "$DIST_DIR" "$dest" --delete --only-show-errors \
    --exclude index.html --exclude config.json \
    --cache-control "public,max-age=31536000,immutable"
fi

# 6. Smoke test through the public URL.
if [[ -n "${SITE_URL:-}" && "${DRY_RUN:-0}" != "1" ]]; then
  echo "Smoke test: $SITE_URL"
  curl -fsS --retry 10 --retry-delay 3 --retry-all-errors --max-time 5 -o /dev/null "$SITE_URL/"
  served="$(curl -fsS --retry 5 --retry-delay 3 --max-time 5 "$SITE_URL/config.json" | jq -r .release)"
  if [[ "$served" != "$RELEASE_ID" ]]; then
    echo "::error::$SITE_URL/config.json serves release '$served', expected '$RELEASE_ID'" >&2
    exit 1
  fi
fi
echo "Frontend deploy OK: release $RELEASE_ID to $ENVIRONMENT"
