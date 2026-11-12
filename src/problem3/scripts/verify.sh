#!/usr/bin/env bash
# Smoke + resilience probe for the Problem 3 stack.
# Usage: scripts/verify.sh [compose-dir] [project-name]   (KEEP=1 leaves the stack running)
# Defaults: compose-dir = parent of this script, project-name = p3verify
set -u
cd "${1:-$(dirname "$0")/..}"
P="${2:-p3verify}"
docker compose -p "$P" up -d --build >/tmp/$P.build.log 2>&1 || { tail -20 /tmp/$P.build.log; exit 1; }
sleep 10
echo "== GET /            -> $(curl -s -o /dev/null -w '%{http_code}' localhost:8080/)"
echo "== GET /api/users   -> $(curl -s -m 5 -w ' [%{http_code}]' localhost:8080/api/users)"
echo "== GET /status      -> $(curl -s -m 5 -w ' [%{http_code}]' localhost:8080/status)"
echo "== nginx error log:"; docker compose -p "$P" logs nginx 2>&1 | grep -i -m3 'error\|connect()'
echo "== postgres max_connections: $(docker compose -p "$P" exec -T postgres psql -U postgres -tAc 'show max_connections' 2>&1)"
echo "== 200 sequential /api/users:"
for i in $(seq 1 200); do curl -s -m 5 -o /dev/null -w '%{http_code}\n' localhost:8080/api/users; done | sort | uniq -c
echo "== 100 concurrent /api/users:"
seq 1 100 | xargs -P 50 -I{} curl -s -m 10 -o /dev/null -w '%{http_code}\n' localhost:8080/api/users | sort | uniq -c
echo "== restart postgres, then request (resilience):"
docker compose -p "$P" restart postgres >/dev/null 2>&1; sleep 6
for i in 1 2 3; do curl -s -m 5 -o /dev/null -w '%{http_code}\n' localhost:8080/api/users; done | sort | uniq -c
echo "== containers:"; docker compose -p "$P" ps --format '{{.Service}} {{.State}} {{.Status}}'
echo "== api log tail:"; docker compose -p "$P" logs api 2>&1 | tail -5
if [ "${KEEP:-0}" != "1" ]; then docker compose -p "$P" down -v >/dev/null 2>&1; fi
