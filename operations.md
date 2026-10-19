# Operations runbook

Commands use the local stack (`infra/local/stack.sh psql`, Redis on `:6390`). On Kubernetes substitute
`kubectl exec -n ferrum deploy/postgres -- psql -U ferrum_user ferrum_db` and `kubectl exec -n ferrum deploy/redis -- redis-cli`.

## 1. Is it healthy? (60-second check)

| Check | Command | Healthy |
|---|---|---|
| Gateway ready | `curl -s $GW/readyz` | `{"status":"ready"}` (503 = Postgres unreachable) |
| Worker alive / ready | `curl -s :8101/healthz` / `:8101/readyz` | `ok` / `ok` (`stale_loops` lists a stuck loop) |
| Relay backlog | `select count(*) from outbox where published_at is null` | ≈ 0 (a few during bursts) |
| Unfinished deliveries | `select status, count(*) from deliveries where status in ('pending','in_flight','retrying') group by 1` | small, draining |
| Stream state | `redis-cli XINFO GROUPS deliveries:stream` | `lag` near 0, `pending` small |
| Dead letters | `select count(*) from deliveries where status='dead_letter'` | stable |
| Pipeline latency | PromQL `histogram_quantile(0.95, sum(rate(worker_queue_delay_seconds_bucket[5m])) by (le))` | seconds, not minutes |

## 2. Everyday tasks

| Task | How |
|---|---|
| Get a token | `T=$(curl -s -XPOST $GW/login -H 'content-type: application/json' -d '{"email":"…","password":"…"}' \| jq -r .access_token)` |
| Replay a failed event | `curl -XPOST -H "Authorization: Bearer $T" $GW/retry/$EVENT_ID` |
| Inspect an event's delivery history | `curl -H "Authorization: Bearer $T" $GW/deliveries/$EVENT_ID \| jq` |
| Find dead letters | `curl -H "Authorization: Bearer $T" "$GW/deliveries?status=dead_letter"` or `redis-cli XRANGE deliveries:dlq - + COUNT 20` |
| Scale | `kubectl scale deploy/<release>-worker -n ferrum --replicas=3` (an HPA may override it) |
| Rotate `JWT_SECRET` | update the Secret, `kubectl rollout restart deploy/<gateway>`; every token becomes invalid, users log in again |
| Roll out a release | build with a **unique tag**; run the migration (Job or Helm hook); roll gateway and worker; `kubectl rollout status` |
| Roll back | `kubectl rollout undo deploy/<gateway>`. The schema is roll-forward: the previous app version cannot run on the new schema (the outbox is mandatory) |
| Back up the database | `kubectl exec deploy/postgres -- pg_dump -U ferrum_user ferrum_db > backup.sql` (always before a migration; there is no automated backup) |
| New migration | `cd ferrum-webhook-gateway && python -m alembic revision -m "msg"`; write the SQL by hand; mirror `models.py` into the worker; CI proves up/down/up |

## 3. Playbooks

### Events are accepted but not delivered (`pending`)

1. `select count(*) from outbox where published_at is null` rising → the **relay** is not publishing: is a worker running? Is Redis up? (`worker` logs: `relay_error`)
2. Outbox empty but `XLEN deliveries:stream` growing and `lag` > 0 → **consumers** are not keeping up or are down. `kubectl get pods`, worker `/readyz`.
3. Stream empty but deliveries `pending` for > 15 min → the Redis data was lost; the stale-pending sweep re-enqueues them automatically (`STALE_PENDING_SECONDS`).
4. Everything looks fine but a receiver reports nothing → check `GET /deliveries/{event_id}`: the `attempts` list says what the receiver answered.

### Deliveries stuck `retrying`

`select id, next_retry_at, error_message from deliveries where status='retrying' order by next_retry_at limit 20;`
`next_retry_at` in the past by more than a few seconds means the scheduler thread is not running (worker `/healthz` shows `stale_loops: ["scheduler"]`). Restart the worker.

### Deliveries stuck `in_flight`

A worker died mid-delivery. It repairs itself: the message is reclaimed after `RECLAIM_IDLE_MS` (90 s) and the lease taken over after `LEASE_SECONDS` (60 s). Confirm with
`worker_stream_reclaimed_total` and `select id, locked_until from deliveries where status='in_flight'`. If it persists beyond ~3 minutes, check that `RECLAIM_IDLE_MS > LEASE_SECONDS × 1000`.

### Dead letters rising

`select response_code, error_message, count(*) from delivery_attempts where status='failed' and attempted_at > now() - interval '1 hour' group by 1,2 order by 3 desc;`
groups failures by cause (`HTTP 500`, `ConnectTimeout`, `blocked target`…). One receiver down → fix it and replay; `blocked target` → the SSRF guard rejected the URL.

### Gateway returns 503

- `{"detail":"Service busy, retry shortly"}` → database pool exhausted (load above capacity, or a slow database). Add replicas (watch Postgres `max_connections`) or reduce load. Clients should retry with backoff.
- `readyz` 503 → Postgres is unreachable. The pod is removed from rotation, not restarted.

### Latency high

1. `kubectl top pods` (or `top`): CPU-bound gateway pods → scale out.
2. Open the slow trace (`ferrum-gateway`, operation `POST /events`) and look at which span is wide: SQL statements wide → database; large gap outside any span → thread/CPU saturation.
3. `select * from pg_stat_activity where state <> 'idle'` for locks / long queries.

### Worker keeps restarting

`kubectl describe pod` → `OOMKilled` (raise the limit; check `WORKER_CONCURRENCY`) or liveness failures (`/healthz` `stale_loops`). Logs: `kubectl logs --previous`.

### Migration Job failed

`kubectl logs job/migrate`. `password authentication failed` → the application role does not have the password in the Secret (Postgres init scripts only run on first start; fix with
`ALTER USER ferrum_user WITH PASSWORD '…'`). Fix and re-run; no application pod was started with the new schema.

### Redis lost / restarted

Nothing to do. Streams are rebuilt from Postgres: expired `in_flight` leases within about a minute, long-pending deliveries within `STALE_PENDING_SECONDS`. Rate-limit and cache state simply reset.
(Covered by an automated test that deletes the stream and expects the work to be re-enqueued.)

### Postgres lost

The system of record is gone. Restore from `pg_dump`; there is no replication. Events accepted after the last backup are lost.

## 4. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `ImagePullBackOff` | The manifest points at `ghcr.io/<org>/…` which is not pullable: use locally loaded images with `pullPolicy: IfNotPresent`, or create `ghcr-secret` |
| A code change "has no effect" in the cluster | The tag was reused and the old image kept. Use a new tag; check `kubectl get pod -o jsonpath='{..imageID}'` |
| Gateway pod `OOMKilled` under login load | Argon2 memory × concurrency. Defaults are safe (19 MiB, cap 4, 384 Mi limit); do not lower the limit below ~256 Mi |
| `422 Webhook URL rejected` | The SSRF guard. Use a public URL; for local receivers set `ALLOW_PRIVATE_WEBHOOK_TARGETS=true` on **both** gateway and worker |
| Many `429` on `/login` | Per-IP Argon2 protection (burst 20, 2/s). Expected under load tests; honour `Retry-After` |
| `429` on `/events` for one tenant | Per-user bucket (burst 100, 50/s); raise `RATE_LIMIT_*` or spread tenants |
| `kubectl top` / HPA `<unknown>` | metrics-server not enabled: `minikube addons enable metrics-server` |
| Jaeger empty after a restart | all-in-one is in-memory; lower `OTEL_TRACES_SAMPLER_RATIO` or use a durable backend |
| Tests: `Email already registered` on Postgres | the test database kept data from an interrupted run; fixtures now import all models before `drop_all`, rerun |
| Benchmark numbers jump around | the laptop slept (look for gaps in the logs) or the port is held by an orphan process: `lsof -iTCP:8100 -sTCP:LISTEN` |
