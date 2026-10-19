# Security

What is protected, how, what is verified by tests, and what is explicitly **not** protected.

## Threat model

| Actor | Goal | Controls |
|---|---|---|
| Anonymous internet user | Use the API, exhaust resources, enumerate accounts | JWT on all data routes; per-IP bucket on `/register` and `/login`; Argon2 concurrency cap; identical response and timing for unknown email vs wrong password |
| Authenticated tenant A | Read or modify tenant B's data | `user_id` filter on every query; foreign ids answer `404` (existence is not confirmed); opaque `evt_` ids |
| Tenant | Make Ferrum attack internal services (SSRF) | URL guard at registration **and** again before each delivery; redirects are not followed |
| Tenant | Starve other tenants | Per-user token bucket; 256 KiB payload cap; bounded per-pod delivery concurrency |
| Network attacker | Forge or replay a webhook to a receiver | HMAC-SHA256 signature over id + timestamp + body; fresh timestamp per attempt |
| Script kiddie with a stolen JWT | Act as a user | Tokens expire after `JWT_TTL_SECONDS` (default 1 h). There is no revocation list |

## Authentication

- `POST /login` issues an HS256 JWT (`sub`, `iat`, `exp`). The service refuses to start without `JWT_SECRET` (≥ 32 characters).
- Decoding pins `algorithms=["HS256"]` and requires `exp` and `sub`. Tests cover `alg=none`, wrong key, expired and garbage tokens.
- Passwords use **Argon2id**, memory 19 MiB, 2 iterations, 1 lane (OWASP's minimum profile). Unknown emails still verify a dummy hash so `/login`
  does not reveal which emails exist. The memory cost was chosen from measurements: see [engineering/04](engineering/04-argon2-memory.md).
- Not implemented: refresh tokens, revocation, MFA, password reset, asymmetric signing keys.

## Webhook signing

- Each webhook has its own secret, `whsec_` + base64(32 random bytes), shown to its owner on create and on `GET /webhooks/{id}`.
- Signature = `v1,` + base64(HMAC-SHA256(key, f"{webhook-id}.{webhook-timestamp}.{raw body}")), key = base64-decoded secret
  ([Standard Webhooks](https://www.standardwebhooks.com/)).
- The body is serialised **once**, with compact separators, and exactly those bytes are signed and sent.
- `webhook-timestamp` is refreshed on every attempt; `webhook-id` (the event id) never changes. Receivers should reject timestamps older than about 5 minutes and compare in constant time.
- The format allows several space-separated signatures, which is the hook for zero-downtime secret rotation. There is no rotation endpoint yet.

Details and measurements: [engineering/07](engineering/07-webhook-security.md).

## SSRF guard

`app/ssrf.py` blocks, for every webhook URL:

- schemes other than `http`/`https`, URLs with embedded credentials;
- the hostnames `localhost`, `*.local`, `*.internal`, `*.svc`, `*.cluster.local`;
- any address that is not globally routable: loopback, RFC 1918, link-local (including the cloud metadata address `169.254.169.254`),
  CGNAT `100.64.0.0/10`, unspecified, multicast, IPv6 loopback/ULA/link-local, and IPv4-mapped IPv6 (`::ffff:127.0.0.1`);
- hostnames are resolved and **every** returned address must be public.

It runs on create, on URL update, and immediately before each POST, so a DNS change after registration is caught. A forbidden target is
dead-lettered without retries.

**Residual risks:**

1. *DNS rebinding window.* The guard resolves the name, then the HTTP client resolves it again. Fully closing this requires connecting to the pinned IP or forcing egress through a filtering proxy / network policy.
2. `ALLOW_INSECURE_WEBHOOKS` defaults to `true` (plain `http://` targets are allowed); set it to `false` to require HTTPS.
3. Names that do not resolve are accepted at registration (the receiver may not exist yet); they simply fail at delivery.
4. `ALLOW_PRIVATE_WEBHOOK_TARGETS=true` switches the guard off. It exists for local experiments; the Kubernetes and Helm defaults are `false`.

## Rate limiting and resource protection

| Control | Setting | Behaviour |
|---|---|---|
| Per-user token bucket | burst 100, 50/s | `429` + `Retry-After`. Atomic Lua script; uses Redis `TIME` so replicas agree on the clock. **Fails open** if Redis is down (an outage must not stop ingest) |
| Per-IP bucket on `/register`, `/login` | burst 20, 2/s | same. Behind an ingress, run uvicorn with `--proxy-headers` and configure trusted proxies so the real client IP is seen |
| Concurrent password hashes | 4 per process | bounds memory at 4 × 19 MiB |
| Payload size | 256 KiB | `413` |
| Database pool | 10 + 10, 5 s timeout | `503` + `Retry-After` instead of an unbounded wait |

## Containers and cluster

- Images run as a non-root user (uid 10001) with exec-form entrypoints and a `.dockerignore` excluding virtualenvs and `.env`.
- Pods declare requests, limits, probes and PodDisruptionBudgets. Secrets are referenced via `secretKeyRef`/`envFrom`; the DB password is not in any ConfigMap.
- The Helm chart never creates Secrets; it references existing ones.

## Limitations (known, not hidden)

| Item | State |
|---|---|
| Transport security | No TLS between components or at the edge; ingress/TLS termination is not part of this repository |
| Secrets at rest | Webhook signing secrets are plaintext in Postgres; Kubernetes Secrets are base64, not encrypted by this project |
| Credentials in version control | The dev manifests (`infra/k8s/secret/postgres-secret.yaml`) contain a placeholder password; `ferrum-secret.yaml` contains a placeholder JWT secret. The gateway repository's history contains `.env` files from early commits (now ignored). Rotate and rewrite history before publishing a repository |
| Redis | No authentication, no TLS |
| Network policy | None; pods can talk to each other freely |
| Observability endpoints | `/metrics` is unauthenticated on both services; Grafana and Prometheus are exposed through NodePorts in the dev manifests |
| JWT | Shared-secret HS256, no revocation |
| Supply chain | No image scanning or signing in CI |
| Multi-tenancy | A user is a tenant; there are no organisations or roles |

## Verification

- `tests/test_auth.py`: token attacks, enumeration resistance, per-IP limiter.
- `tests/test_webhooks_events.py::test_everything_is_scoped_by_user`: every endpoint, two tenants.
- `tests/test_ssrf.py`: 16 blocked patterns, rebinding via mocked DNS, API-level rejection.
- `infra/tests/smoke.py`: tenant isolation and signature validity against a running stack.
- Incidents found while hardening (an unauthenticated memory-exhaustion path, a glibc effect, a bootstrap-credentials bug) are written up in [engineering/04](engineering/04-argon2-memory.md) and [engineering/05](engineering/05-connection-pool-deadlock.md).
