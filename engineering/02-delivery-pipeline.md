# At-least-once delivery with Redis Streams: claims, leases and crash recovery

*The outbox (previous post) gets an event safely to the queue. This post is about the next half: making sure every queued delivery is
attempted, even when workers die at the worst possible moment, and proving it by killing them.*

> **In short:** Delivery workers can crash at any moment. The design makes sure a delivery is never forgotten, at the cost of occasionally sending the same one twice, which receivers can detect.

## The problem

A worker takes a delivery off the queue, makes an HTTP request to a customer, writes the outcome to the database, and acknowledges the message.
A process can die between any two of those steps, and so can the network. The system must never lose the delivery, never run two attempts at once for the same delivery,
and must accept that sometimes the customer will see a request twice. "Exactly once" is not on offer; the question is how to get **at least once** with duplicates that are cheap and bounded.

## What the first version got wrong

The original worker did `BRPOP event_queue`, looped over webhooks, made requests, and called `time.sleep(delay)` between retries.

- `BRPOP` *removes* the item. A crash anywhere afterwards loses the event.
- Sleeping between retries pins a worker for the whole backoff (5 s, 15 s, 30 s in that version) and makes graceful shutdown impossible.
- There was no way to see what was in flight, and nothing to reclaim work from a dead worker.

## The design

```
outbox ──relay──► Redis Stream ──XREADGROUP──► worker ── 1. CLAIM  (atomic UPDATE pending→in_flight, lease 60 s)
                       ▲                                  2. POST to the customer
                       │ XAUTOCLAIM (idle > 90 s)         3. COMMIT the outcome in one DB transaction
                       └──────── dead consumers' ◄─────── 4. XACK  (only now)
                                 messages
```

| Piece | What it prevents |
|---|---|
| **Stream + consumer group** instead of a list | The *pending entries list* keeps every delivered-but-unacknowledged message, so a crashed consumer's work is still there |
| **`XACK` only after the database commit** | A crash between "read" and "recorded" re-delivers instead of losing |
| **`XAUTOCLAIM` of messages idle > 90 s** | Pending messages of a dead consumer are taken over by a live one |
| **Atomic claim** (`UPDATE … SET status='in_flight' WHERE status='pending' OR (in_flight AND lease expired)`) | Duplicate messages (relay republish, reclaim) cannot cause two concurrent POSTs; the second claimer updates 0 rows |
| **Lease** (`locked_until`, 60 s) | A worker that claimed and then died can be superseded; a live one cannot be |
| **`recover_orphaned`** sweep | A delivery stuck `in_flight` whose stream message no longer exists (Redis lost) is put back via the outbox |
| **`recover_stale_pending`** sweep | A `pending` delivery whose outbox row was published long ago but which nobody picked up (Redis wiped) is re-enqueued |
| **`next_retry_at` + scheduler** instead of `sleep` | A failure parks the delivery in the database; nothing occupies a worker while it waits ([next post](03-retries.md)) |
| **One delivery row per (event, webhook)** with `UNIQUE` | One place for state, schedule and lease; attempts are logged separately |
| **Stable `webhook-id`** | The receiver can recognise the duplicates that at-least-once makes unavoidable |

### Two subtle rules

1. **`RECLAIM_IDLE_MS` must exceed the lease.** If a message could be reclaimed while the previous worker's lease is still valid, the claim would fail,
   the worker would conclude "duplicate, someone else has it" and acknowledge the message, leaving a delivery nobody owns. Defaults: lease 60 s, reclaim after 90 s.
2. **A failed claim on a live lease is "busy", not "skipped".** Skipped (already finished) messages are acknowledged; busy ones are **not**, so if the lease holder dies the message is still pending and gets reclaimed.

## The crash matrix

Every place a process can die, and what recovers it:

| Crash point | State left behind | Recovery | Outcome |
|---|---|---|---|
| Gateway before `COMMIT` | nothing | the client got no `202`; it retries with the same `Idempotency-Key` | no loss |
| Gateway after `COMMIT`, before the client sees `202` | event + deliveries + outbox committed | client retries with the key → `200 Idempotent-Replayed` | no loss, no duplicate event |
| Relay after `XADD`, before marking `published_at` | message on the stream, outbox row unpublished | next relay run republishes | duplicate *message*; the claim absorbs it |
| Worker after `XREADGROUP`, before the claim | message pending | `XAUTOCLAIM` after `RECLAIM_IDLE_MS` | no loss |
| Worker after the claim, during the POST | delivery `in_flight`, message pending | reclaimed, lease taken over | no loss; the receiver may get the request twice |
| Worker after the POST succeeded, before the commit | delivery `in_flight` | reclaimed, POSTed **again** | **duplicate delivery** (receivers dedupe on `webhook-id`) |
| Worker after the commit, before `XACK` | delivery final, message pending | reclaimed, claim fails (already `success`), acknowledged | no re-POST |
| Redis loses everything | deliveries unfinished in Postgres | `recover_orphaned` (≈ 1 min) and `recover_stale_pending` (default 15 min) | no loss, delayed |
| Postgres unavailable | n/a | workers and relay back off and resume | delay only |

The interesting row is the sixth: the system cannot know whether the customer processed a request whose response never arrived. That duplicate is irreducible, which is why `webhook-id` exists.

## Measurements

### A real `kill -9` mid-delivery

With shortened timers (`LEASE_SECONDS=3`, `RECLAIM_IDLE_MS=4000`, `RECLAIM_INTERVAL_SECONDS=2`) a worker was killed while its HTTP request was in flight (the receiver hangs only its first request), a replacement worker was started,
and the delivery completed **2.6 seconds after the kill**. The receiver saw exactly two POSTs: the abandoned one and the recovered one; the attempt log shows one clean attempt. Output: [`docs/data/verification/`](../data/verification/quickstart_scenarios.txt).

This is a single observation, not a distribution. The mechanism says recovery takes about `RECLAIM_IDLE_MS` (the message must go idle) plus up to one `RECLAIM_INTERVAL_SECONDS` plus the replacement worker's startup, so the production defaults (lease 60 s, reclaim after 90 s) recover in roughly a minute and a half.
That is a deliberate trade: shorter windows recover faster but risk reclaiming a worker that is merely slow (the lease protects correctness either way).

### Concurrency under real Postgres

The correctness arguments above rest on row locks, so they are tested against a real Postgres (`ferrum-webhook-worker/tests/test_postgres_concurrency.py`):

| Test | Setup | Property |
|---|---|---|
| `test_concurrent_relays_publish_every_row_exactly_once` | 600 outbox rows, 6 relay threads, batches of 25 | every row published once; none skipped (`FOR UPDATE SKIP LOCKED`) |
| `test_only_one_of_many_concurrent_workers_delivers` | 12 workers race for one delivery whose POST takes 200 ms | exactly one `success`, the rest `busy`/`skipped`, **one** HTTP request |
| `test_concurrent_schedulers_requeue_each_due_retry_once` | 200 due retries, 6 schedulers | each retry re-queued exactly once |

## Operating it

```bash
redis-cli XINFO GROUPS deliveries:stream       # lag, pending, consumers
redis-cli XPENDING deliveries:stream delivery-workers
select status, count(*) from deliveries group by 1;
select count(*) from outbox where published_at is null;     -- relay backlog
```
Runbook for each symptom: [operations](../operations.md#3-playbooks). Settings: [configuration](../configuration.md).

## Reproduce

```bash
infra/local/stack.sh up
# the kill -9 scenario by hand: quickstart section 3.5
TEST_DATABASE_URL=postgresql://…/ferrum_test  ferrum-webhook-worker/.venv/bin/python -m pytest ferrum-webhook-worker/tests -q
```

## What I would do differently / next
- Poison messages are bounded (10 redeliveries → DLQ stream) but the threshold is only checked on the reclaim path.
- There is no per-endpoint concurrency cap or circuit breaker: a slow receiver delays the others in its batch by up to the read timeout (5 s).
- Kafka would turn the transient stream into a durable, replayable log; the outbox is already the right producer-side pattern for it.
