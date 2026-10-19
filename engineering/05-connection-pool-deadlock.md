# A deadlock between the connection pool and the thread pool

*At 200 concurrent clients the API did not slow down. It stopped. Three plausible fixes did nothing; the real one is a single design rule.
This is the investigation, with a 20-line reproduction.*

> **In short:** Under heavy load the server froze, because two shared resources were each waiting for the other. The fix is a single rule: give back the database connection before waiting for anything else.

## Symptom

Load test, closed model, one gateway process, increasing the number of concurrent clients (each with its own account, posting `POST /events`):

| Concurrent clients | Result |
|---|---|
| 10 | normal |
| 50 | normal |
| **200** | **59 events accepted in 30 seconds**, 80 log lines of `QueuePool limit of size 5 overflow 10 reached, connection timed out, timeout 30.00` |

Not a degradation curve but a cliff. CPU was idle during the stall.

## Three wrong turns

1. **"The pool is too small."** It was 5 + 10 connections for 40 request threads, so threads were waiting for connections. But making it bigger only moves the cliff, and the cause of
   the *stall* (as opposed to queueing) was still unexplained.
2. **"The session teardown needs a thread, and threads are exhausted."** FastAPI runs a *sync* generator dependency (the one that closes the DB session) in the same bounded thread pool as the endpoints.
   Switching `get_db` to an `async` dependency means closing needs no thread. This was a real improvement and is kept, but the stall remained in a minimal reproduction (below), so it was not the whole story.
3. **"Size the pool to the thread count."** If every thread can always get a connection, nobody waits. This turns out not to be sufficient either; see the argument below.

## Reproducing it in 20 lines

A load test takes minutes and a cluster. The bug needs only three ingredients: a small DB pool, a small thread pool, and more concurrent requests than either.
`ferrum-webhook-gateway/scripts/pool_probe.py` fires N concurrent `GET /events` straight at the ASGI app (no network) against a real Postgres, with a 4-connection pool, 6 threads and a 3 s pool timeout.
`--legacy` restores the old behaviour (connection released only at dependency teardown):

| Mode | Route | Requests OK | Elapsed | Connections left checked out |
|---|---|---:|---:|---:|
| current | `/events` | **120 / 120** | 0.2 s | 0 |
| `--legacy` | `/events` | **6 / 120** (114 × `503`) | **57.2 s** | 0 |
| `--legacy` | `/readyz` (uses the DB, no `response_model`) | 120 / 120 | 0.1 s | 0 |

Watching `pool.checkedout()` during a stalled run showed the pool pinned at 4 of 4 the whole time, held by requests that had *finished their query*.
The third row is the key experiment: the same legacy code on a route that touches the database but has **no response model**, and therefore no serialization step, does not stall. Raw output: [`docs/data/verification/pool_probe.txt`](../data/verification/pool_probe.txt).

## The actual cause: a circular wait

```mermaid
flowchart LR
    A["Requests 1..P: finished their query,<br/>still HOLD all P connections"] -->|"need a thread to<br/>serialize the response"| T["Thread pool: all T threads busy"]
    T -->|"the threads belong to requests P+1..<br/>that are WAITING for"| C["a database connection (0 free)"]
    C -->|"every connection is held by"| A
```

A synchronous FastAPI request involves **three** steps that each need a thread from the same bounded pool (`anyio`'s default of 40):

1. resolve sync dependencies (here: authentication),
2. run the endpoint (this is where the DB connection is checked out, on the first query),
3. **serialise the response** (`response_model` validation also runs in the thread pool for sync endpoints).

The DB session stays open, holding its connection, until step 3 completes and the dependency is torn down. So after step 2 a request holds a connection and is *waiting for a thread*.

With a pool of P connections and T threads, consider a burst of requests:

- Requests 1..P take every connection in their step 2 and finish; each now waits for a thread for step 3.
- The thread pool is FIFO. Requests P+1.. are *ahead* of those serialisations in the queue; they take the T threads for their step 2 and **block waiting for a connection**.
- The connections are held by requests 1..P, which are waiting for a thread. The threads are held by requests P+1.. which are waiting for a connection.

Nobody can proceed until a blocked thread gives up at `pool_timeout` (30 s by default), after which the cycle restarts for the next wave. That is the "59 events in 30 seconds".

This also explains why wrong turn 3 fails: with P ≥ T, requests 1..P still take all P connections and queue for serialisation behind requests P+1..2P, which then block on the pool.
Whenever a request can hold a connection while waiting for a thread, there is a cycle, and under enough concurrency it will be traversed.

## The fix: never hold a connection while waiting for a thread

The rule: **a handler releases its database connection in its own thread before it returns.** Then a connection is only ever held by a thread that is running and will finish without needing anything else,
which breaks the cycle regardless of the sizes of the two pools.

```python
class SessionReleasingRoute(APIRoute):
    def __init__(self, path, endpoint, **kw):
        if not inspect.iscoroutinefunction(endpoint):
            endpoint = _close_session_when_done(endpoint)      # try: handler(...) finally: db.close()
        super().__init__(path, endpoint, **kw)

app.router.route_class = SessionReleasingRoute
```

Enforcing it in a route class rather than in each endpoint means a new endpoint cannot forget. Companion changes:

- `get_db` is an `async` generator dependency (teardown needs no thread).
- After `commit()` the session no longer re-queries the row it just wrote (`expire_on_commit=False`), so ingest holds no connection after its commit.
- `DB_POOL_TIMEOUT` drops from 30 s to 5 s and a timeout becomes `503 Retry-After: 1`: an overloaded service should say so quickly instead of hanging clients and load balancers.

## Results

One run each, 200 closed-loop clients, one gateway process, isolated ingest, 20 s window:

| Version | Completed requests | Throughput | p95 |
|---|---:|---:|---:|
| original (everything reverted) | **0** (the whole window stalled) | 0 | n/a |
| current code | 10,407 | 520 req/s | 417 ms |
| only the route release reverted | 10,551 | 528 req/s | 414 ms |
| only the async dependency reverted | 9,951 | 498 req/s | 439 ms |
| only the pool settings reverted | 10,191 | 510 req/s | 430 ms |

**A subtlety this exposes:** reverting any *one* of the three changes did not bring the collapse back, so none of them is individually *necessary* for `POST /events`: the other two, plus the removal of the post-commit re-read (which stops ingest holding a connection after its handler returns), still prevent the cycle.
The original failed because several conditions held at once. What this experiment does **not** show is which single change would be *sufficient* starting from the original; that was not tested. For read handlers (an open read transaction) the early release is what matters, as the probe shows.

## Guarding against regressions

- `tests/test_postgres_concurrency.py` (real Postgres): 120 concurrent ingests and 120 concurrent reads against a 4-connection pool and 6 threads must all succeed within seconds; the pool must have **zero** connections checked out afterwards; and every sync route must be registered through `SessionReleasingRoute` (a structural check).
- The incident numbers are in the test docstring so the context travels with the test.

## Lessons
1. **A bounded resource that can be held while waiting for another bounded resource is a deadlock waiting for load.** Draw the wait-for graph of your request path.
2. **Reproduce at the smallest scale.** Shrinking the pools made a 10-minute cluster experiment into a 1-second script, which is what made the explanation findable.
3. **Resizing hides cycles; ordering removes them.** Bigger pools made it rarer, never impossible.
4. **Be suspicious of a fix that "should" work.** Making the dependency async was right and insufficient; the reproduction said so.
5. **Prefer failing fast.** A 5-second pool timeout turned a hang into a visible, retryable `503`.

## Reproduce

```bash
infra/local/stack.sh up && createdb -h localhost -p 5544 -U ferrum_user ferrum_test
cd ferrum-webhook-gateway
export TEST_DATABASE_URL=postgresql://ferrum_user@localhost:5544/ferrum_test
.venv/bin/python scripts/pool_probe.py --legacy                    # the stall
.venv/bin/python scripts/pool_probe.py                             # the fix
.venv/bin/python scripts/pool_probe.py --legacy --path /readyz     # no serialization step: no stall
cd .. && infra/bench/ablation.sh                                   # the load-test version, with the revert-one-change variants
```
