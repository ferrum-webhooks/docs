# Fifty logins took the API down: Argon2, thread pools and glibc

*A load test that was supposed to measure webhook ingest instead killed the API with a memory limit. The investigation found two independent causes,
one of which only exists on Linux, and an unauthenticated denial of service in the process.*

> **In short:** Checking passwords is deliberately memory-hungry. Fifty people logging in at once crashed the server. The fix took two steps, one of which was a quirk of how Linux hands memory back.

## Symptom

The first in-cluster load test (50 virtual users, each registering and logging in before sending events) produced **100% failed requests**.
`kubectl describe pod` explained why: the gateway pods were `OOMKilled` (limit 256 MiB) within seconds of the run starting, then restarted, and were killed again.

Nothing in the ingest path allocates that much. The memory was going into the part of the test nobody had been measuring: password hashing.

## Cause 1: Argon2's default memory cost is a weapon

Passwords are hashed with Argon2id through `passlib`. Argon2 is *memory-hard on purpose*: that is how it resists GPU cracking. passlib's default is **64 MiB per hash**.
`/register` and `/login` are unauthenticated, so a client can start as many hashes as the server will accept. With FastAPI's 40-thread pool, 40 simultaneous logins need
40 × 64 MiB = **2.5 GiB** in a pod limited to 256 MiB. This is not only a load-test artefact: it is a remote, unauthenticated way to kill the service.

First fix (obvious):

| Change | Effect |
|---|---|
| Use the OWASP minimum profile: **19 MiB**, 2 iterations, 1 lane (`ARGON2_MEMORY_COST_KIB`) | 3.4× less memory per hash |
| Cap concurrent hashes per process at 4 (`HASH_CONCURRENCY`) | bound: 4 × 19 MiB ≈ 76 MiB, whatever the traffic |
| Per-IP token bucket on `/register` and `/login` (20 burst, 2/s) | the attacker's request rate is bounded before it reaches the hasher |
| Hashes made with the old parameters still verify (parameters are embedded in each hash) | no forced password resets |

The limit was raised to 384 MiB and the test re-run. **The pods were still being OOM-killed.** (Part of that was a different mistake: the "fixed" image was never deployed because `minikube image load`
silently kept the old image for the same tag; the rule since then is a unique tag per build.) But even with the fix really running, the numbers did not add up: a cap of 4 concurrent hashes should never exceed ~76 MiB.

## Cause 2: freed memory that glibc keeps

Measuring inside the real container, 40 hashes spread across 40 threads, with the concurrency cap in place:

- 4 threads: peak **124 MiB**. As predicted.
- 40 threads: peak **806 MiB**. About 40 × 19 MiB.

Only 4 hashes can run at once, yet memory scaled with the number of *threads*. The explanation is in how glibc's `malloc` behaves with many threads:

1. Each thread tends to get its own allocation **arena**.
2. A 19 MiB buffer is above the default mmap threshold, so it is normally `mmap`'d and returned to the OS on `free`. But glibc's threshold is **dynamic**: after freeing a large mmap'd chunk it *raises* the threshold, so later large allocations come from the arena heap instead,
   and freed arena memory is retained, not returned.
3. With 40 threads taking turns on 4 hashing slots, every thread's arena ends up holding a freed ~19 MiB block.

Two environment variables fix it: `MALLOC_ARENA_MAX=2` (fewer arenas) and `MALLOC_MMAP_THRESHOLD_=1048576` (setting the threshold explicitly disables the dynamic adjustment, so big buffers are always `mmap`'d and returned immediately).
Both are baked into the gateway image.

## The experiment

Measured during the investigation, inside the gateway image (`--memory 2g`), 40 hashes issued from a 40-thread pool, concurrency cap 4, Argon2 cost 19 MiB:

| Allocator settings | Threads | Peak resident memory |
|---|---:|---:|
| glibc defaults | 4 | 124 MiB |
| glibc defaults | 40 | **806 MiB** |
| `MALLOC_ARENA_MAX=2` | 40 | 143 MiB |
| `MALLOC_MMAP_THRESHOLD_=1048576` | 40 | **106 MiB** |
| both (what the image ships) | 40 | 106 MiB |

*Single runs with a small script equivalent to the one under Reproduce. The Argon2 cost was 19 MiB in all rows; the claim that the library default (64 MiB) would need 40 × 64 MiB = 2.5 GiB for 40 simultaneous hashes is arithmetic, not a measurement.*

## Lessons
1. **Memory-hard hashing is an availability risk on unauthenticated endpoints.** Bound it three ways: cost per hash, concurrency, and request rate.
2. **Cap the resource, not the threads.** A semaphore around the hash bounded CPU parallelism but not memory; the allocator turned a concurrency limit into a per-thread retention.
3. **Measure on the target OS.** This effect is invisible on macOS (the development machine's allocator behaves differently). It needed a Linux container with a memory limit.
4. **Verify what is running.** A fix that is not deployed explains nothing; check the image digest the pod actually uses.
5. **Resource limits found it.** Without a memory limit this would have shown up as a slow node and an unexplained bill instead of a clear `OOMKilled`.

## Reproduce

Inside the gateway image (Linux/glibc matters; this does not reproduce on macOS):

```python
# hm.py
import os, sys
os.environ["TESTING"] = "true"
from concurrent.futures import ThreadPoolExecutor
from app import security

def peak_mib():
    return int([l for l in open("/proc/self/status") if l.startswith("VmHWM")][0].split()[1]) // 1024

threads = int(sys.argv[1])
with ThreadPoolExecutor(threads) as ex:
    list(ex.map(lambda i: security.hash_password(f"pw{i}"), range(40)))
print(f"{threads} threads: peak {peak_mib()} MiB")
```
```bash
docker build -t ferrum-gateway ferrum-webhook-gateway
# the image ships the tuned allocator settings:
docker run --rm -m 2g -e PYTHONPATH=/app -v "$PWD/hm.py:/hm.py" ferrum-gateway python /hm.py 40
# glibc defaults, for comparison:
docker run --rm -m 2g -e PYTHONPATH=/app -v "$PWD/hm.py:/hm.py" --entrypoint env ferrum-gateway \
       -u MALLOC_ARENA_MAX -u MALLOC_MMAP_THRESHOLD_ python /hm.py 40
```
