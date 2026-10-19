# Retries without sleeping

*A retry is just "do this again later". The original worker implemented "later" with `time.sleep`, which turned out to be the most expensive line in the codebase.
This post is about moving the schedule out of the process and into the database, and measuring how accurately it fires.*

> **In short:** Instead of a worker sleeping between retries, the next try time is written in the database and picked up when due. Nothing ever waits, and a restart forgets nothing.

## The problem with `sleep`

The first worker retried like this (simplified):

```python
for attempt in range(3):
    if post(webhook): return
    time.sleep(RETRY_DELAYS[attempt])      # 5 s, 15 s, 30 s
```

| Problem | Consequence |
|---|---|
| The worker is occupied for the whole backoff | One failing endpoint with 30 s of backoff holds a worker slot for ~50 s per event; with N workers, N such events stop all delivery |
| The schedule lives in a process's memory | A restart or crash forgets every pending retry |
| The loop only checks the shutdown flag between events | A `SIGTERM` during a sleep is not honoured until the sleep ends |
| The state was invisible | You could not ask "which deliveries are waiting, and until when?" |

## The design

A failed attempt records its outcome and **parks** the delivery:

```
attempt fails (attempt n < MAX_ATTEMPTS)
   → deliveries.status = 'retrying', next_retry_at = now + 5 · 2^(n-1) s  ±20%        (one DB transaction, with the attempt log)
scheduler thread, every second:
   SELECT … FROM deliveries WHERE status='retrying' AND next_retry_at <= now() FOR UPDATE SKIP LOCKED
   → status = 'pending', INSERT outbox row        (one transaction)
relay → stream → worker      (the same path as a first attempt)
```

Properties that fall out of this:

- **No worker waits.** A delivery that is retrying consumes no thread, no connection, no memory in any process.
- **Retries survive everything.** The schedule is a column; restarts, crashes and Redis loss do not touch it.
- **One durable path.** A retry travels through the outbox exactly like the first attempt, so every recovery mechanism covers it for free.
- **Observable.** `select id, next_retry_at, error_message from deliveries where status='retrying'` answers "what is waiting and why".
- **Safe with many pods.** `SKIP LOCKED` lets any number of schedulers share the work without double-queuing (tested with 6 concurrent schedulers on Postgres).
- **Backoff with jitter.** Delays double (5, 10, 20, 40 s; capped at `RETRY_MAX_SECONDS`) with ±20% jitter so that when an endpoint recovers, thousands of waiting deliveries do not hit it in the same second.
  After `MAX_ATTEMPTS` (5) the delivery is `dead_letter`; a replay resets the counter.

### Why not a Redis sorted set?
A sorted set keyed by due time is the textbook answer and would give sub-second precision. It would also be a **second source of truth** that must be reconciled with Postgres after any Redis loss,
and the `next_retry_at` column already existed. Keeping the schedule in the system of record means one fewer thing to repair. The cost is timing resolution (below).

## How exactly does it fire?

Observed on the local stack with a receiver that fails its first two requests (default settings: 5 s base backoff, jitter on). Timestamps are from the receiver's log:

| Attempt | Time | Gap since previous | Scheduled delay |
|---|---|---|---|
| 1 | 14:30:01 | n/a | n/a |
| 2 | 14:30:07 | **6 s** | 5 s (±20% jitter) |
| 3 | 14:30:18 | **11 s** | 10 s (±20% jitter) |

A retry fires roughly **0 to 1.2 s after its due time**, by construction: a due delivery waits for the next **scheduler tick** (1 s), then the **relay** poll (0.2 s), then a free worker thread.
That is irrelevant for 5 s to 40 s backoffs and is the reason not to use this mechanism for sub-second scheduling (`SCHEDULER_INTERVAL_SECONDS` trades database polling for precision).
Two observations are an illustration, not a measurement of the distribution; a systematic accuracy measurement was not completed.

## Failure behaviour worth knowing
- A timeout, DNS failure, connection refused, TLS error, or any non-2xx (including 3xx, since redirects are not followed) counts as a failed attempt and is recorded in `delivery_attempts` with the error text.
- A forbidden target (SSRF guard) is **not retried**; it is dead-lettered immediately.
- `worker_retry_attempts_total` counts retries scheduled; `worker_dlq_events_total` counts dead letters. A rising dead-letter rate with `HTTP 5xx` errors usually means one receiver is down; fix it and `POST /retry/{event_id}`.

## Reproduce

```bash
infra/local/stack.sh up
# a receiver that fails its first two requests and prints timestamps and signature status (quickstart section 3.3):
WEBHOOK_SECRET=whsec_… PORT=9100 FAIL_FIRST=2 python3 infra/tests/echo_receiver.py
```
