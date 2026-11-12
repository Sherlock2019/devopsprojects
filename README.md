# 99Tech DevOps Challenge: Solutions

**Dzoan Nguyen Tran** · DevOps / SRE / Cloud Engineer

This repo contains my answers to the 99Tech DevOps Challenge. It follows the official template layout (`src/problemN/`), so every answer can be read directly on GitHub. To get everything locally: **Code → Download ZIP**, or `git clone`.

## Solutions

| # | Problem | Full document (PDF) | Summary | Status |
|---|---|---|---|---|
| 1 | Building Castle in the Cloud: HA crypto trading platform on AWS | 📄 [View PDF](docs/AWS_Trading_Platform_Dzoan-tran.pdf) · [⬇ Download](https://github.com/Sherlock2019/devopsprojects/raw/main/docs/AWS_Trading_Platform_Dzoan-tran.pdf) | [SOLUTION.md](src/problem1/SOLUTION.md) | ✅ **Complete** (design) |
| 2 | Diagnose Me Doctor: NGINX LB at 99% disk | 📄 [View PDF](docs/NGINX_Storage_Full_Incident_Report.pdf) · [⬇ Download](https://github.com/Sherlock2019/devopsprojects/raw/main/docs/NGINX_Storage_Full_Incident_Report.pdf) | [SOLUTION.md](src/problem2/SOLUTION.md) | ✅ **Complete** (method + illustrative worked incident) |
| 3 | Debugging issues within the system: Docker Compose API | Code: [src/problem3/](src/problem3/) | [SOLUTION.md](src/problem3/SOLUTION.md) | ✅ **Complete: fixed and tested** |
| 4 | Ship It Twice: GitHub Actions to EC2 + S3 | 📄 [View PDF](docs/Developer_Guide_AWS_CICD.pdf) · [⬇ Download](https://github.com/Sherlock2019/devopsprojects/raw/main/docs/Developer_Guide_AWS_CICD.pdf) | [SOLUTION.md](src/problem4/SOLUTION.md) | ✅ **Complete as code**: workflows + scripts, offline tests 14/14; not run against real AWS |
| 5 | Fortify the Castle: security for Problem 1 | 📄 [View PDF](docs/AWS_Trading_Platform_Security_Updated.pdf) · [⬇ Download](https://github.com/Sherlock2019/devopsprojects/raw/main/docs/AWS_Trading_Platform_Security_Updated.pdf) | [SOLUTION.md](src/problem5/SOLUTION.md) | ✅ **Complete** (design) |

**View PDF** opens the full document in GitHub's built-in viewer. **⬇ Download** saves the file directly. The SOLUTION.md files are Markdown summaries.

## Architecture and security workflow

**AWS Trading Platform: Security, EKS & Recovery** (Problems 1 and 5)

![AWS Trading Platform: Security, EKS & Recovery](docs/diagrams/aws-trading-platform-security-eks-recovery.png)

**Trading Platform: Security Workflow** (Problem 5)

![Trading Platform: Security Workflow](docs/diagrams/trading-platform-security-workflow.png)

More diagrams render inline (Mermaid) in [Problem 1](src/problem1/SOLUTION.md#3-architecture-overview), [Problem 2](src/problem2/SOLUTION.md#3-situation-appraisal-and-dependency-map) and [Problem 4](src/problem4/SOLUTION.md#5-pipeline-flow).

**Workflows:** [backend.yml](src/problem4/.github/workflows/backend.yml) and [frontend.yml](src/problem4/.github/workflows/frontend.yml), with deploy scripts in [src/problem4/scripts/](src/problem4/scripts/). They sit in the template's location, so they are inactive in this repo by design: GitHub only *runs* workflows from the repository-root `.github/workflows/`. The [Problem 4 solution](src/problem4/SOLUTION.md) explains how to drop them into an app repo.

## Problem 3 highlights

| Found | Fix |
|---|---|
| nginx `proxy_pass` → `api:3001`, API listens on `3000` → **100% 502** | Correct upstream |
| Postgres restart → unhandled `pg` Pool `'error'` → **API process exits** and stays down | Error handlers + `restart: unless-stopped` |
| `db.release()` skipped when a query throws → connection leak | `pool.query()` |
| No healthchecks, timeouts or readiness | Added |

## How to run the tests

**Problem 3** (needs Docker + Compose v2, port 8080 free):

```bash
cd src/problem3
docker compose up --build -d
curl localhost:8080/api/users      # {"ok":true,...}
bash scripts/verify.sh             # smoke + load + Postgres-restart resilience probe (brings up its own stack and tears it down; stop the one above first)
docker compose down -v
```

Result recorded on 12 Nov 2026: 200/200 sequential and 100/100 concurrent requests succeeded, and the API survived a Postgres restart. Full table in the [Problem 3 solution](src/problem3/SOLUTION.md#test-results-after-fix).

**Problem 4** (needs bash, jq, curl, Docker; uses port 18081; no AWS account needed):

```bash
cd src/problem4
bash tests/run-tests.sh   # fake AWS CLI; simulates SSM by running the real deploy payload against local Docker
```

Result recorded on 12 Nov 2026: 14 passed, 0 failed (frontend publish order, cache headers and invalidation; backend digest pinning, deploy, automatic rollback).

Problems 1, 2 and 5 are design or process documents. There is nothing to execute.

## What is proposed, simulated or tested

| Item | Nature |
|---|---|
| AWS trading architecture (P1) and security controls (P5) | **Proposed**, not deployed. 500 RPS / p99 < 100 ms are **targets, not measured** |
| Wallets, custody, signing (P1/P5) | **Simulated**: no real funds or keys |
| NGINX incident (P2) | **Illustrative** worked example; only the VM, NGINX and 99% alert are from the brief |
| CI/CD workflows and deploy scripts (P4) | **Tested offline** (stubbed AWS CLI + local Docker); not run on GitHub runners or real AWS. Separate staging/prod deploy repos are **proposed** |
| Problem 3 fixes | **Tested** locally with Docker |

## Assumptions, limitations and outstanding work

- **Problem 4:** no AWS account was used, so no real deployment was tested. `actionlint`/`shellcheck` were not available in the build environment and should be run before first use. Actions are pinned to major tags; pin them to SHAs for production.
- **Problem 2:** the brief mentions two production issues, but the material describes one scenario; I didn't invent a second.
- **Problem 3:** its README is titled "Problem 4" in the template; I treated it as Problem 3 because of its folder.

---

<details>
<summary>Original template README</summary>

# 99Tech DevOps Challenge #
Note that if you fork this repository, your responses may be publicly linked to this repo (DO NO FORK).
Please submit your application along with the solutions attached or linked.

It is important that you minimally attempt the problems, even if you do not arrive at a working solution.

## Submission ##
You can either provide a link to an online repository, attach the solution in your application, or whichever method you prefer. We're cool as long as we can view your solution without any pain.

</details>
