# Deployment

| Mode | For | Command |
|---|---|---|
| Tests only | development | `python -m pytest` in each service |
| Local stack | experiments, benchmarks, demos | `infra/local/stack.sh up` ([quickstart](quickstart.md)) |
| Kubernetes | probes, rolling updates, autoscaling | raw manifests or the Helm chart |

## Images

| Image | Source | Entrypoint |
|---|---|---|
| gateway | `ferrum-webhook-gateway/Dockerfile` | `uvicorn app.main:app --timeout-graceful-shutdown 20 --proxy-headers` |
| worker | `ferrum-webhook-worker/Dockerfile` | `python -m worker.main` |

Both are `python:3.11-slim`, run as a non-root user (uid 10001), and use exec-form `CMD` so the application is PID 1 and receives `SIGTERM`.
The gateway image also sets `MALLOC_ARENA_MAX=2 MALLOC_MMAP_THRESHOLD_=1048576` ([why](engineering/04-argon2-memory.md)) and doubles as the **migration** image (`python -m alembic upgrade head`).

Each service's CI (`.github/workflows/ci.yml`) installs dependencies, runs the tests against a Redis **and a Postgres** service container, (gateway) applies the migrations up, down and up again, builds the image and pushes it to GHCR.

> **Tagging rule:** never reuse an image tag when loading images into a local cluster. `minikube image load` silently keeps the old image for an existing tag. Use a timestamp or the git SHA.

## Secrets: placeholders in git, real values at install time

No credentials are in the repository. Templates live in `infra/k8s/secret/*.example.yaml` (every value is `CHANGE_ME`), and real Secrets are generated randomly in the cluster:

```bash
infra/k8s/secret/create-secrets.sh ferrum            # creates postgres-secret, ferrum-secret, grafana-secret; refuses to overwrite existing ones
DRY_RUN=1 infra/k8s/secret/create-secrets.sh         # no cluster needed; prints key names only
```
`k8s/secret/*.yaml` (except `*.example.yaml`) is git-ignored. Postgres reads `DB_PASSWORD` only when its volume is first initialised; replacing the Secret later does not change the database role.

## Kubernetes

### Raw manifests (`infra/k8s`)

| Path | Resource |
|---|---|
| `namespace/` | Namespace `ferrum` |
| `config/ferrum-config.yaml` | ConfigMap with non-secret settings; also the variables `envsubst` expands (`GITHUB_ORG`, `IMAGE_TAG`, `IMAGE_PULL_POLICY`) |
| `secret/` | templates and the generator script (above) |
| `pvc/` | 1 Gi volume for Postgres |
| `services/postgres|redis|jaeger|prometheus|grafana.yaml` | infrastructure Deployments and Services (single instances) |
| `jobs/migrate.yaml` | migration Job |
| `services/gateway.yaml`, `worker.yaml` | application Deployments and Services (`${…}` placeholders, apply through `envsubst`) |
| `hpa/`, `pdb/` | autoscalers (CPU 70%, 1 to 5 replicas) and PodDisruptionBudgets |

```bash
kubectl apply -f k8s/namespace/ -f k8s/config/ -f k8s/pvc/
k8s/secret/create-secrets.sh ferrum
kubectl apply -f k8s/services/postgres.yaml -f k8s/services/redis.yaml -f k8s/services/jaeger.yaml -f k8s/services/prometheus.yaml -f k8s/services/grafana.yaml
export GITHUB_ORG=ferrum-local IMAGE_TAG=$TAG IMAGE_PULL_POLICY=IfNotPresent      # $TAG: a fresh tag for locally loaded images
kubectl delete job migrate -n ferrum --ignore-not-found
envsubst < k8s/jobs/migrate.yaml | kubectl apply -f - && kubectl wait --for=condition=complete job/migrate -n ferrum --timeout=120s
envsubst < k8s/services/gateway.yaml | kubectl apply -f -
envsubst < k8s/services/worker.yaml  | kubectl apply -f -
kubectl apply -f k8s/hpa/ -f k8s/pdb/
```
These manifests, the migration Job and the probes were deployed and exercised on minikube; the Grafana Secret reference and `create-secrets.sh` were added afterwards and have been checked only offline (`DRY_RUN=1`). A rolling update uses `maxUnavailable: 0, maxSurge: 1`, so a new pod must be Ready before an old one is removed.

### Helm chart (`infra/charts/ferrum`)

Deploys **only the application** (gateway, worker, config, HPAs, PDBs, migration hook). Postgres, Redis and the trace backend are inputs (`database.*`, `redis.*`, `tracing.endpoint`).
The chart **never creates Secrets**; it references two that must already exist (`postgres-secret` key `DB_PASSWORD`, `ferrum-secret` key `JWT_SECRET`; both configurable).

```bash
helm lint infra/charts/ferrum --set image.tag=$TAG
helm template ferrum infra/charts/ferrum -n ferrum --set image.tag=$TAG | less
helm upgrade --install ferrum infra/charts/ferrum -n ferrum --set image.tag=$TAG --set image.pullPolicy=IfNotPresent
```
Status: the chart **lints and renders** (default values and variants for autoscaling off, hook off, pull secrets, NodePort, tracing off, extra env, PDB off). It has not been installed on a cluster.
Notable values: `gateway.resources` (memory limit sized for Argon2: do not go below ~256 Mi), `security.allowPrivateWebhookTargets` (default `false`), `tracing.samplerRatio` (default `0.1`), `migrations.enabled`.
The migration runs as a `pre-install,pre-upgrade` hook with inline environment, so a failing migration aborts the release before any new pod starts.

### The probe and shutdown contract

| | Gateway | Worker |
|---|---|---|
| startup | `GET /healthz`, up to 60 s | `GET /healthz` |
| readiness | `GET /readyz`: Postgres `SELECT 1`. Redis is not required (ingest does not use it) | `GET /readyz`: Postgres + Redis; false once shutting down |
| liveness | `GET /healthz`: process only, so a database blip does not restart pods | `GET /healthz`: consumer, relay and scheduler loops each heartbeated within 60 s |
| `preStop` | `sleep 10`: lets endpoint removal propagate before uvicorn stops accepting | none (no inbound traffic) |
| on `SIGTERM` | drain in-flight requests ≤ 20 s, close pools | finish and acknowledge in-flight deliveries, stop loops, close pools |
| `terminationGracePeriodSeconds` | 30 | 30 |
| resources | req 100m / 192 Mi, limit 500m / 384 Mi | req 100m / 128 Mi, limit 500m / 256 Mi |

### Why migrations are a separate step

Running `alembic upgrade head` in every pod's start command makes N replicas race on the same DDL, ties a schema change to a pod restart, and leaves a half-rolled fleet on failure.
A Job/hook runs once per release and its failure stops the rollout. The outbox migration is not backward compatible with the previous application version, so releases are **roll-forward**; future schema changes should be additive (expand, then contract).

## Limits of the provided deployments

Single Postgres and Redis pods without backups or replication; no TLS or ingress; NodePort Services for the gateway, Prometheus and Grafana in the dev manifests; HPAs scale on CPU although the worker is I/O-bound (queue-delay or stream-lag based scaling would track load better).
