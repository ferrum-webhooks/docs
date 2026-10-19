# Testing

Distributed-systems bugs live in the gaps between components, so most of the suite runs against **real** Redis and (in CI and by default
for the concurrency tests) **real** Postgres. Only the customer's HTTP endpoint is faked.

## The suites

| Suite | Tests | Needs | Covers |
|---|---|---|---|
| `ferrum-webhook-gateway/tests` | 41 (37 on SQLite + 4 Postgres-only) | nothing; Postgres optional | auth attacks (`alg=none`, expired, wrong key), enumeration resistance, per-user and per-IP limits, tenant isolation across every endpoint, webhook CRUD + secrets + soft delete, **atomic ingest** (event + deliveries + outbox), **idempotency** (replay, conflict, per-user namespace, race), validation, deliveries and replay, rate-limit math (real Lua), SSRF matrix, `traceparent` persisted, probes, **pool/thread deadlock regressions** |
| `ferrum-webhook-worker/tests` | 21 (18 + 3 Postgres-only) | real Redis; Postgres optional | Standard Webhooks test vector, verify/tamper/replay window, relay publish-once and republish-after-crash, success/failure/timeout paths, **retry → dead-letter cycle**, scheduler due-only, deleted webhook, **`XAUTOCLAIM` crash recovery**, stale-lease takeover, orphan recovery, **stale-pending re-enqueue after a Redis wipe**, poison messages, backoff shape, SSRF at send time, **one trace across ingest and retry**; on Postgres: **6 relays never double-publish, 12 workers race for one delivery and exactly one sends, concurrent schedulers re-queue each retry once** |
| `infra/tests/smoke.py` | 13 checks | a running local stack | auth, tenant isolation, idempotency, signature validity, delivery, replay no-op |
| CI migration step | 3 commands | Postgres | `upgrade head` → `downgrade base` → `upgrade head` |

## Running them

```bash
# fast: SQLite for relational tests, real Redis for stream tests
cd ferrum-webhook-gateway && .venv/bin/python -m pytest -q          # 37 passed, 4 skipped
cd ferrum-webhook-worker  && .venv/bin/python -m pytest -q          # 18 passed, 3 skipped   (Redis on :6379 required, else skipped)

# complete: against a disposable Postgres (all tests run, incl. the concurrency ones)
infra/local/stack.sh up                                              # provides Postgres on :5544
createdb -h localhost -p 5544 -U ferrum_user ferrum_test
export TEST_DATABASE_URL=postgresql://ferrum_user@localhost:5544/ferrum_test
cd ferrum-webhook-gateway && .venv/bin/python -m pytest -q          # 41 passed
cd ferrum-webhook-worker  && .venv/bin/python -m pytest -q          # 21 passed
```

`TEST_DATABASE_URL` is refused unless the database name contains `test`: the fixtures **drop and recreate every table** in it.
Worker tests use private Redis stream names (`test:*`) and delete them afterwards; they never flush Redis.

## Checking the migrations

```bash
createdb -h localhost -p 5544 -U ferrum_user ferrum_migtest
cd ferrum-webhook-gateway
export DB_HOST=localhost DB_PORT=5544 DB_USER=ferrum_user DB_PASSWORD=x DB_NAME=ferrum_migtest
.venv/bin/python -m alembic upgrade head && .venv/bin/python -m alembic downgrade base && .venv/bin/python -m alembic upgrade head
dropdb -h localhost -p 5544 -U ferrum_user ferrum_migtest
```
This should run without errors (the same three steps run in CI).

## Design decisions

- **SQLite for speed, Postgres for truth.** SQLite uses one shared connection (`StaticPool`), so it cannot prove locking or concurrency; those tests are marked and skipped there.
  SQLite plus threads can also segfault, so SQLite tests use single-threaded executors.
- **Real Redis, not a fake.** Pending-entry lists, `XAUTOCLAIM` idle times and consumer-group semantics are the behaviour under test.
- **Fault injection in tests, not mocks of internals.** Crashes are simulated by *not* acknowledging, by letting leases expire (`UPDATE … locked_until`), by deleting the stream key, by re-publishing outbox rows.
- **Tests that guard past bugs** carry their story in the docstring (the pool-deadlock test records the numbers from the original incident).
- **Time is injected through the data** (move `next_retry_at` into the past) rather than sleeping.

## What found real bugs

| Bug | Found by |
|---|---|
| `event.status` stayed `processing` because the session had `autoflush=False` and the recompute query read pre-update rows | unit test of the delivery path |
| Test fixtures only worked by accident of import order (`Base.metadata` empty when a module ran alone) | running a test file alone against Postgres |
| Connection-pool/thread-pool deadlock under concurrency | load test; now a Postgres regression test ([write-up](engineering/05-connection-pool-deadlock.md)) |
| Unbounded password-hash memory | load test ([write-up](engineering/04-argon2-memory.md)) |
| A reclaimed message acknowledged while another worker held a live lease | design review, then locked in by `test_crash_mid_delivery_stale_lease_is_taken_over` |
| Pending deliveries stranded after a Redis wipe | design review, then `test_pending_delivery_whose_stream_message_was_lost_is_reenqueued` |

## Not covered by automated tests

TLS, ingress, real DNS (rebinding is tested with a mocked resolver), multi-node failure, Postgres failover (there is none), whole-system fault injection under sustained load (random process kills), and Kubernetes behaviour such as rolling updates under load. The probes and graceful shutdown were exercised by hand on minikube.
