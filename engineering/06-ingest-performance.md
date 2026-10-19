# Where the milliseconds go: ingest performance, measured properly (the second time)

*Performance numbers are easy to produce and hard to trust. The first set of Ferrum numbers was wrong in three different ways, and the corrections changed the conclusions.
This post gives the clean results, says which change bought what, and documents how the bad numbers happened so the next measurement is better.*

> **In short:** How many events the API accepts per second, how fast it answers, which changes helped, and the measurement mistakes made on the way (and fixed).

## What is being measured

`POST /events`: authenticate (JWT), rate-limit (Redis), validate, then one Postgres transaction that stores the event, its deliveries and the outbox rows, then `202`.
The delivery side (worker) is measured separately and then together.

The SRS targets this against: **p95 < 200 ms** and **1,000 events/s**.

## Method

| Choice | Why |
|---|---|
| **Isolated ingest**: no worker running while ingest is measured | With a worker running, its backlog (relay, consumer, status updates) contends for the same Postgres and CPU. The first results mixed the two (see "What went wrong") |
| **Closed model** (fixed number of clients, no think time) for capacity and attribution | Shows maximum throughput and how latency grows with concurrency |
| **Open model** (fixed arrival rate) for latency under a given load | Closed-loop clients hide overload by slowing down ("coordinated omission"); an arrival-rate test does not |
| 3 s warm-up, then a 20 s measurement window; throughput = completed requests / window | k6 reports sub-metric rates over the *whole* run including warm-up, which understates throughput; computed here from counts |
| **Variants interleaved and repeated** (A B A B …), mean ± standard deviation | Single runs differed by more than some of the effects measured; interleaving cancels machine drift |
| One tenant (user, webhook) per client | Per-user rate limits are real but set high so they never throttle the benchmark; the limiter's *cost* stays in the path |
| Same machine for everything: Apple M5 (10 cores), k6, gateway, Postgres, Redis, sink | Conservative for real deployments (everything competes for cores) |

## Results

### 1. Before and after (1 gateway process, isolated ingest)

The "original" is the gateway as it was before the ingest and concurrency work, reconstructed from the current code with each change reverted by `infra/bench/make_variant.py`.

| Clients | Version | Runs | Throughput (req/s) | p50 (ms) | p95 (ms) |
|---:|---|---:|---:|---:|---:|
| 10 | original | 5 | 404 ± 17 | 24.0 | 32 ± 4 |
| 10 | **current** | 5 | 528 ± 21 | 18.3 | 25 ± 4 |
| 10 | *change* | | **+31%** | -24% | **-22%** |
| 50 | original | 5 | 422 ± 9 | 108.7 | 214 ± 6 |
| 50 | **current** | 5 | 549 ± 10 | 89.2 | 111 ± 5 |
| 50 | *change* | | **+30%** | -18% | **-48%** |

*Mean ± sample standard deviation over 5 interleaved runs of 20 s each, after a 3 s warm-up. 0 errors in every run.*

### 2. Which change bought what (50 clients; one change reverted at a time)

| Variant (50 clients) | Runs | Throughput (req/s) | vs current | p95 (ms) |
|---|---:|---:|---:|---:|
| current code | 3 | 558 ± 2 |  | 106 ± 0 |
| revert: re-read the row after commit (`refresh`) | 3 | 468 ± 13 | -16% | 128 ± 11 |
| revert: sync `get_db` dependency (teardown needs a thread) | 3 | 523 ± 15 | -6% | 116 ± 9 |
| revert: handler does not close its session (`SessionReleasingRoute`) | 3 | 558 ± 13 | +0% | 107 ± 5 |
| revert: old pool (5+10, 30 s timeout) | 3 | 561 ± 2 | +1% | 105 ± 1 |

*3 interleaved runs each. A larger drop when a change is reverted means that change was worth more.*

The speed-up comes from removing work from every request:

- **The post-commit re-read** is the biggest single item (about 16% of throughput): after `COMMIT`, SQLAlchemy expired the `event` object, so reading `event.public_id` for the response issued a `SELECT` and started a new transaction.
- **The synchronous `get_db` dependency** costs about 6%: its teardown has to hop onto a worker thread for every request; the async version closes the session on the event loop.
- **Releasing the session in the handler and the new pool settings** are worth nothing at this load, as they should be: they exist for what happens beyond it (next section and the [deadlock post](05-connection-pool-deadlock.md)).
- **Batched inserts** are not visible here because this benchmark gives each tenant one webhook, so there is one delivery per event. Their effect is in the round-trip count below (44 statements → 5 for an event with 20 webhooks).

### 3. Past the pool size: 200 clients, one process

One run each (see the table in [the deadlock post](05-connection-pool-deadlock.md)): the original completed **0 requests** in the 20 s window; the current code sustained **520 req/s** with 0 errors and p95 417 ms; reverting only the route release, only the async dependency, or only the pool settings each still sustained 498 to 528 req/s.

The original collapses ([the deadlock post](05-connection-pool-deadlock.md)); the fixed code keeps serving at essentially the same throughput as at 50 clients, with latency growing linearly with the queue (Little's law), no errors.

### 4. Round trips

| Webhooks matching the event | Before (round trips) | After |
|---:|---:|---:|
| 1 | 6 | **5** |
| 5 | 14 | **5** |
| 20 | 44 | **5** |

*Counted with a SQLAlchemy `before_cursor_execute` listener against a real Postgres, plus the `COMMIT`. "Before" is the previous implementation kept inside the script for comparison.
Raw output: `docs/data/statements/`. Command: `ferrum-webhook-gateway/.venv/bin/python infra/bench/count_statements.py`.*

### 5. Scaling with gateway processes (closed model, 100 clients)

| Gateway processes | Runs | Throughput (req/s) | Speed-up | p50 (ms) | p95 (ms) |
|---:|---:|---:|---:|---:|---:|
| 1 | 3 | 525 ± 7 | 1.00× | 191 | 220 ± 8 |
| 2 | 3 | 806 ± 6 | 1.53× | 122 | 165 ± 8 |
| 4 | 3 | 987 ± 44 | 1.88× | 99 | 145 ± 18 |
| 8 | 3 | 1222 ± 116 | 2.33× | 56 | 195 ± 43 |

*100 closed-loop clients, 100 tenants, isolated ingest (no worker). k6, Postgres and Redis share the same 10 cores, so scaling flattens as the machine itself saturates; the step from 4 to 8 processes is sub-linear most likely because of that sharing (not isolated experimentally).*

### 6. Latency versus offered load (open model, 4 gateway processes)

| Offered load (req/s) | Achieved (req/s) | p50 (ms) | p95 (ms) | p99 (ms) | Errors |
|---:|---:|---:|---:|---:|---:|
| 300 | 300 | 2.7 | 3.4 | 4.0 | 0.00% |
| 600 | 600 | 3.0 | 4.4 | 9.5 | 0.00% |
| 900 | 900 | 3.3 | 5.5 | 11.2 | 0.00% |
| 1200 | 1099 | 851.7 | 1957.4 | 2120.0 | 0.00% |
| 1500 | 1029 | 1940.3 | 2338.5 | 2399.5 | 0.00% |

*Constant arrival rate, 20 s, 4 gateway processes, isolated ingest. Up to 900 req/s the service is idle-fast (single-digit milliseconds); the knee is between 900 and 1,200 req/s, where arrivals exceed capacity and a queue builds (seconds of latency, throughput capped near 1,050 to 1,100 req/s).*

### 7. Does the delivery side keep up? Capacity and end-to-end latency

Deliveries are I/O-bound on the receiver, so capacity ≈ (processes × concurrency) / (receiver latency + overhead) until a CPU or the database saturates.
`drain_rate.sh` builds a backlog with no worker running, then times how fast workers drain it:

Measured (backlog of ~13,000 events built with no worker running, sink answering instantly):

| Worker processes × concurrency | Sink latency | Drain rate |
|---|---:|---:|
| 1 × 8 | 0 ms | **353 deliveries/s** |
| 1 × 32 | 0 ms | 323 deliveries/s |

Four times the concurrency inside one process does not help: with an instant sink, one Python worker process is CPU-bound at roughly 320 to 350 deliveries/s (the work per delivery is about nine SQL statements plus an HTTP request). The 4-process and the 50 ms-sink configurations in `drain_rate.sh` were not run.

End to end, with everything running at a fixed ingest rate (event created → first successful delivery attempt, read from the database):

Open model at 300 events/s for 30 s, 2 gateway processes, all components running; latency is event creation → first successful attempt, read from the database:

| Worker processes | p50 | p95 | p99 | max | Backlog drained after load stopped |
|---:|---:|---:|---:|---:|---|
| 1 | **28.9 s** | 37.1 s | 38.0 s | 38.3 s | 22 s |
| 2 | 232 ms | 1,098 ms | 1,232 ms | 66.1 s | immediately |
| 4 | 223 ms | 256 ms | 281 ms | 310 ms | immediately |

- **One worker process cannot sustain 300 events/s** (consistent with its ~320 to 350/s ceiling once ingest competes for the same cores): the queue grows for the whole run.
- With enough workers, the median of ~225 ms is dominated by the relay's 0.2 s poll interval, not by processing.
- **The 66 s maximum in the 2-worker run is unexplained.** It was a single event out of ~9,800; the matching ingest request also took ~65 s, so the stall was inside the gateway's request, not in delivery. The logs needed to diagnose it were overwritten by the next stage (the harness truncated them; it should append). It did not recur in the 1- and 4-worker runs. Treat it as an open question, not a measured property.

### 8. What tracing costs

| Configuration (50 clients) | Runs | Throughput (req/s) | vs ratio 0 | p95 (ms) |
|---|---:|---:|---:|---:|
| tracing code present, sampler ratio 0 (nothing recorded) | 4 | 606 ± 7 |  | 99 ± 2 |
| every request recorded, no exporter | 4 | 557 ± 11 | -8% | 107 ± 4 |
| 10% sampled, exported to Jaeger *(Kubernetes/Helm default)* | 4 | 587 ± 18 | -3% | 104 ± 6 |
| 100% sampled, exported to Jaeger | 4 | 493 ± 10 | -19% | 121 ± 5 |

## Against the SRS targets

| Target | Result on this laptop (everything co-located) | Verdict |
|---|---|---|
| Ingest p95 < 200 ms | single-digit milliseconds at up to 900 req/s offered (4 gateway processes); 111 ms at 50 closed-loop clients on one process | **met** |
| 1,000 events/s ingest | 987 ± 44 req/s with 4 processes and 1,222 ± 116 with 8 (closed model); the knee is between 900 and 1,200 req/s offered | **met** with 4 or more gateway processes |
| Sustained end to end at 300 events/s | needs at least 2 worker processes; clean (p99 281 ms) with 4 | met with enough workers; **not measured at 1,000/s end to end** |

These are co-located, single-machine numbers (the load generator, Postgres, Redis and the receiver share the cores), so they are conservative for ingest and say nothing about network effects.

## What went wrong the first time (and how to avoid it)

The first benchmark run produced numbers that were wrong in three independent ways. Each produced a plausible-looking table.

1. **The laptop slept.** A run showed a maximum latency of ~1,000 seconds. The gateway log had a 12,000-second gap. Sleep froze the clock the test measured with. *Fix:* `caffeinate`; the logs are checked for gaps.
2. **An orphan process answered for the new one.** The harness started a new gateway, polled `/readyz`, and reported "up", but the port was held by a gateway left over from an earlier aborted run, which answered the health check.
   The same had happened with a **worker**: an orphan from days earlier silently joined the Redis consumer group and consumed deliveries. It made delivery look faster, made "retry timing" look like it ignored its configuration (the orphan had default settings),
   and inflated the first before/after comparison (+41% at 10 clients, versus +31% when measured in isolation). *Fix:* `local/stack.sh` verifies it owns the listening port and refuses to start if untracked Ferrum processes exist (`doctor`).
3. **Delivery was benchmarked inside the ingest test.** With one worker the delivery backlog grew, and the relay and status updates contended with ingest for Postgres, so ingest results depended on how much work the *worker* could absorb.
   Once the orphan was gone, "optimized" briefly looked *slower* than "original" at 10 clients (258 vs 301 req/s). *Fix:* isolate ingest from delivery and measure each alone, then together.

And a reporting bug: k6's `rate` on a tagged sub-metric divides by the whole test duration, understating throughput by about 20% with a 5 s warm-up; throughput is now computed from request counts.

**The takeaway is procedural:** a benchmark harness must verify its own preconditions (right process, right port, machine awake, no strays, correct units) and fail loudly. Most of the time spent in this investigation went into making that true.

## Reproduce

```bash
caffeinate -dims infra/bench/run_all.sh /tmp/ferrum-results        # the whole suite, ~1 hour
infra/bench/ablation.sh && python3 infra/bench/aggregate.py /tmp/ferrum-bench/abl 20      # sections 1 to 3
infra/bench/scaling.sh && python3 infra/bench/aggregate.py /tmp/ferrum-bench/scale 20     # sections 5, 6
```
Raw outputs of the runs quoted here are in [`docs/data/`](https://github.com/ferrum-webhooks/docs/tree/main/data).
