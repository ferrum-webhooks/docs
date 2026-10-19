# Signing webhooks and not becoming an SSRF proxy

*Two security problems are unique to a webhook platform: the receiver must be able to trust a request, and the platform must not be
tricked into sending requests to places the customer shouldn't reach. This is how Ferrum handles both, what was measured, and what is still open.*

> **In short:** How a receiver can tell a message really came from Ferrum, and how Ferrum avoids being tricked into calling private addresses inside its own network.

## Part 1: proving a webhook is genuine

### The requirement
A receiver gets an anonymous HTTP POST from the internet. It needs to know that (1) Ferrum sent it, (2) the body was not altered, and
(3) it is not a recording of an old request being replayed. It also needs a stable identifier so that retries (which happen by design) can be de-duplicated.

### The design: Standard Webhooks
Rather than invent a scheme, Ferrum follows the public [Standard Webhooks](https://www.standardwebhooks.com/) specification, so receivers can use
off-the-shelf verification libraries. Every delivery carries three headers:

| Header | Value | Purpose |
|---|---|---|
| `webhook-id` | the event id (`evt_…`) | **Identical on every retry and replay**: the receiver's idempotency key |
| `webhook-timestamp` | Unix seconds, **refreshed on every attempt** | Replay protection: reject if too old |
| `webhook-signature` | `v1,` + base64(HMAC-SHA256(key, `"{id}.{timestamp}.{body}"`)) | Authenticity and integrity |

The key is per webhook: `whsec_` + base64 of 32 random bytes, generated when the webhook is created. A signature header may hold several
space-separated signatures, which is the mechanism for rotating a secret without downtime (not yet exposed through the API).

### Three details that decide whether it works
1. **Sign the bytes you send.** The body is serialised once with compact separators and those exact bytes are both signed and put on the wire (`data=`, not `json=`).
   Signing a dict and letting the HTTP library re-serialise it is the classic bug: the receiver verifies a different byte string.
2. **Fresh timestamp, stable id.** A retry five minutes later must pass the receiver's timestamp tolerance, so the timestamp (and therefore the signature) is regenerated per attempt, while the id stays constant so the receiver can recognise the duplicate.
3. **Constant-time comparison** on the verifier side (`hmac.compare_digest`).

### Verified
- `test_standard_webhooks_vector` recomputes the expected signature directly from `hmac`/`hashlib`/`base64` using the specification's construction (a different code path from `worker/signing.py`), rather than comparing the module against its own output. It is not an official published test vector.
- Tamper tests: a changed body, a wrong secret and a timestamp outside the tolerance window all fail verification.
- End to end: `infra/tests/smoke.py` runs a real receiver that verifies every delivery's signature.

### What signing costs
Measured with `ferrum-webhook-worker/scripts/sign_bench.py` (median of 5 repetitions, Apple M5, Python 3.9):

| Body size | Sign | Verify | Serialise the JSON (`json.dumps`) |
|---:|---:|---:|---:|
| 290 B | 1.8 µs | 3.0 µs | 1.7 µs |
| 2 KB | 2.8 µs | 3.5 µs | 3.8 µs |
| 50 KB | 21 µs | 23 µs | 65 µs |
| 250 KB | 99 µs | 97 µs | 331 µs |

Signing is cheaper than serialising the body it signs, and a rounding error next to the network call (milliseconds), so there is no reason to skip or batch it. Raw output: [`docs/data/verification/sign_bench.txt`](../data/verification/sign_bench.txt).

## Part 2: the platform as an SSRF gadget

### The risk
A webhook URL is attacker-controlled input that the platform will `POST` to **from inside its own network**. A tenant who registers
`http://169.254.169.254/latest/meta-data/` (the cloud metadata service), `http://redis:6379/`, or `http://postgres.ferrum.svc:5432/` turns Ferrum into a proxy
into places the internet cannot reach. This is Server-Side Request Forgery, and for a webhook relay it is the single most important vulnerability to design out.

### The guard (`app/ssrf.py`)
A URL is rejected unless it is `http`/`https` with no embedded credentials and its host is **publicly routable**:

| Blocked | Examples |
|---|---|
| Loopback, private, link-local, CGNAT, unspecified, multicast | `127.0.0.1`, `10.0.0.5`, `192.168.1.1`, `172.16.0.1`, `169.254.169.254`, `100.64.0.1`, `0.0.0.0` |
| IPv6 equivalents and IPv4-mapped IPv6 | `[::1]`, `[::ffff:127.0.0.1]` |
| Internal hostnames | `localhost`, `*.local`, `*.internal`, `*.svc`, `*.cluster.local` |
| Anything that **resolves** to the above | a public-looking name pointing at `10.1.2.3` |
| Other schemes, userinfo | `ftp://`, `file:///etc/passwd`, `https://user:pw@…` |

It is checked **three times**: when the webhook is created, when its URL is updated, and again immediately before every delivery attempt. The last check
matters because DNS answers change: a name that resolved to a public address at registration can resolve to `10.0.0.5` a week later (DNS rebinding).
A target rejected at send time is dead-lettered immediately (retrying a forbidden target is pointless). Redirects are never followed, since a public URL could otherwise `302` to an internal one.

### Verified
- `tests/test_ssrf.py`: **16 blocked URL patterns** and the allowed public literal, hostname-resolves-to-private (mocked DNS), unresolvable host, and the API rejecting create/update with `422`.
- `tests/test_worker.py::test_blocked_target_is_dead_lettered_without_a_request`: a webhook changed to the metadata address after registration is dead-lettered and **no HTTP request is made**.
- Reproduce interactively: [quickstart §3.7](../quickstart.md#37-the-private-address-check).

### What this does not solve
- **The rebinding window.** The guard resolves the hostname, then the HTTP client resolves it again. An attacker controlling DNS can answer differently the second time. Closing it fully
  needs connecting to the already-validated IP, or forcing all egress through a filtering proxy or a network policy that only permits public destinations.
- Plain `http://` is allowed by default (`ALLOW_INSECURE_WEBHOOKS=false` requires HTTPS).
- A guard can be switched off (`ALLOW_PRIVATE_WEBHOOK_TARGETS=true`) for local experiments; the shipped Helm chart, manifests and compose default to **off = protected**, and CI fails if the rendered chart ever ships it enabled.

## Reproduce

```bash
ferrum-webhook-worker/.venv/bin/python -m pytest ferrum-webhook-worker/tests/test_worker.py -k "signing or verify or vector or blocked" -q
ferrum-webhook-gateway/.venv/bin/python -m pytest ferrum-webhook-gateway/tests/test_ssrf.py -q
cd ferrum-webhook-worker && .venv/bin/python scripts/sign_bench.py      # ~10 s
```
