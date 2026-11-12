# Problem 3: Debugging issues within the system

**Status: complete. Reproduced, fixed and re-tested locally with Docker Compose on 12 Nov 2026.**

> The task statement is in [README.md](README.md). Its heading says "Problem 4", but it sits in the template's `problem3` folder, so I treated it as Problem 3.
> The first commit of this repo is the unmodified template, so the exact changes are visible with `git diff $(git rev-list --max-parents=0 HEAD) -- src/problem3`, or by opening the "Problem 3" commit on GitHub.

## Summary

| # | Problem found | Symptom | Root cause | Fix |
|---|---|---|---|---|
| 1 | **Wrong upstream port** | Every `/api/*` request returns **502** | `nginx/conf.d/default.conf` had `proxy_pass http://api:3001`, but the API listens on **3000** | Use `server api:3000` in an `upstream` block |
| 2 | **API crashes when Postgres restarts or drops a connection** | API "sometimes inaccessible" and then down for good | `pg.Pool` emits `'error'` on idle clients; with no listener Node throws `Unhandled 'error' event` and exits | Add `pool.on('error')` and `redis.on('error')` handlers |
| 3 | **No restart policy** | After one crash the API stays down until someone intervenes | Compose services had no `restart:` | `restart: unless-stopped` on all services |
| 4 | **Connection leak on query failure** | Pool exhaustion → requests hang under DB errors | `pool.connect()` … `db.release()` with no `finally`, so a throwing query never released the client | Use `pool.query()`, which always releases the client |
| 5 | **No timeouts** | Requests could hang instead of failing | Pool `connectionTimeoutMillis` defaulted to 0 (wait forever); nginx used default 60 s timeouts | Pool connect/query timeouts; nginx 2 s connect / 10 s read |
| 6 | **Startup ordering only, not readiness** | Possible 5xx while dependencies boot | `depends_on` without health conditions | Healthchecks on postgres, redis and api; `condition: service_healthy` |
| 7 | **Redis failure fails the whole request** | 500 when Redis is down although the DB answered | `await redis.set` inside the request path | Best-effort write with `.catch()`; Redis checked in `/api/ready` instead |
| 8 | **`/status` not reachable through nginx** | 404 from nginx | No location for it | `location = /status` proxied to the API |

Also observed, deliberately left unchanged:

- **`postgres/init.sql` (`ALTER SYSTEM SET max_connections = 20`) is never mounted**, so it has no effect: measured `max_connections` is 100. If someone mounts it later, it caps Postgres at 20 connections, which becomes the limit when the API scales beyond two replicas at `max: 10` each. I left it unmounted and documented it rather than silently changing DB capacity.
- `nginx/nginx.conf` is empty but is not mounted (only `conf.d/` is), so it is harmless. `.env` is empty. Compose now reads an optional `POSTGRES_PASSWORD` from it and falls back to the demo default.
- I removed the obsolete `version: "3.9"` key, which Compose v2 ignores with a warning.

## How I diagnosed it

1. **Reproduce first.** I brought up the untouched stack and probed `/`, `/api/users` and `/status`: `/` returned 200, every `/api/users` returned **502**, and `/status` returned **404**.
2. **Read the proxy's error log.** nginx logged
   `connect() failed (111: Connection refused) while connecting to upstream … upstream: "http://…:3001/api/users"`.
   Compared with the API log `API running on 3000`, that confirms the port mismatch.
3. **Fix one variable and re-test.** With only the port corrected, 200 sequential and 100 concurrent requests all returned 200. Then I restarted Postgres to simulate a DB failover:
   ```text
   api-1  | node:events:502
   api-1  |       throw er; // Unhandled 'error' event
   api-1  | error: terminating connection due to administrator command
   api    exited  Exited (1)
   ```
   The API process died and stayed dead, which explains "sometimes inaccessible": the API works until the first DB blip.
4. **Code review of the request path** found the connection leak (no `finally` around `db.release()`), the missing timeouts and the hard dependency on Redis.
5. **Configuration review** found the unmounted `init.sql`, the missing healthchecks and restart policies, and the hard-coded credentials.

## Fixes applied (files)

- [`nginx/conf.d/default.conf`](nginx/conf.d/default.conf): correct upstream port, keepalive, proxy timeouts, forwarded headers, `/status` route.
- [`api/src/index.js`](api/src/index.js): pool and redis error handlers, `pool.query()` (no leak), connect/query timeouts, best-effort Redis write, `503` on DB failure, new `/api/ready` readiness endpoint, graceful SIGTERM shutdown, credentials from environment.
- [`docker-compose.yml`](docker-compose.yml): healthchecks, `service_healthy` dependencies, `restart: unless-stopped`, read-only nginx config mount, named volume for Postgres data, password from `.env`.
- [`api/Dockerfile`](api/Dockerfile): production install (`--omit=dev`), `NODE_ENV=production`, runs as the non-root `node` user.

## Test results (after fix)

Run with `bash scripts/verify.sh` (requires Docker plus Compose v2).

| Test | Before | After |
|---|---|---|
| `GET /api/users` | 502 | **200** |
| `GET /status` via nginx | 404 | **200** |
| 200 sequential `/api/users` | 200 × 502 | **200 × 200** |
| 100 concurrent (50 parallel) | 100 × 502 | **100 × 200** |
| Restart Postgres, then 3 requests | API process exits (`Unhandled 'error' event`) | API stays up, **3 × 200** |
| Postgres stopped | n/a | **503 in ~50 ms** (fails fast); `/status` still 200 |
| Redis stopped | n/a | `/api/users` still **200**; `/api/ready` reports 503 |
| API process exits (SIGTERM inside container) | stays down | restarted by Docker (RestartCount 0 → 1), healthy, 200 |

## Monitoring and alerts I would add

| Signal | Alert |
|---|---|
| nginx upstream 5xx rate and `upstream connect() failed` log lines | 5xx > 1% for 5 min; any sustained 502 |
| p95/p99 latency of `/api/*` (nginx `$upstream_response_time`) | p99 above SLO for 10 min |
| Container restarts / health status (cAdvisor, or `docker events`) | > 2 restarts in 10 min, or unhealthy for > 1 min |
| `/api/ready` synthetic probe from outside the host | 3 consecutive failures |
| Postgres `numbackends` / `max_connections`, pg pool `waitingCount` | > 80% of connections in use |
| Redis availability and error log lines | Redis down > 1 min (degraded, not an outage) |
| Host disk, memory and CPU | standard saturation alerts |

## How I would prevent this in production

- **CI config tests:** run `nginx -t`, and in CI bring up the stack and run `scripts/verify.sh` as a smoke test on every PR. A wrong port fails the build, not production.
- **Single source of truth for ports:** pass the API port as an env var used by both the API and the proxy config (template it), instead of two hard-coded numbers.
- **Lint for the leak class:** an ESLint rule or code review checklist that forbids `pool.connect()` without `try/finally`; prefer `pool.query()`.
- **Chaos and failure tests:** restart the DB and cache in staging regularly; the API must survive.
- **Real orchestration in production:** liveness and readiness probes, more than one API replica behind the proxy, and a managed Postgres (for example RDS) with failover. Docker Compose `restart:` is only a single-host safety net.
- **Secrets:** move DB credentials out of compose and source into a secret store; don't run with the default `postgres/postgres`.
- **Capacity budget:** keep `replicas × pool max` below Postgres `max_connections` with headroom, or put PgBouncer in front.
