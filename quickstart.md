# Quickstart

Run Ferrum on your computer and try it out. About 15 minutes. The commands below were all run against this code; the outputs are saved in [`data/verification`](data/verification/quickstart_scenarios.txt).

## What you need

Python 3.9 to 3.11, PostgreSQL and Redis installed (for example with Homebrew), and `curl` and `jq`. The three repositories (`ferrum-webhook-gateway`, `ferrum-webhook-worker`, `infra`) must sit side by side in one folder.

## 1. Install

```bash
(cd ferrum-webhook-gateway && python3 -m venv .venv && .venv/bin/pip install -q -r requirements.txt)
(cd ferrum-webhook-worker  && python3 -m venv .venv && .venv/bin/pip install -q -r requirements.txt)
```

## 2. Start

```bash
infra/local/stack.sh up
```
This starts its own private PostgreSQL and Redis on spare ports (it never touches ones you already run), applies the database setup, and starts the API (port 8100), a worker, and a small test receiver. Check it:

```bash
ferrum-webhook-worker/.venv/bin/python infra/tests/smoke.py --base http://127.0.0.1:8100
```
You should see 13 `PASS` lines. Other commands: `stack.sh status`, `down` (stop), `reset` (stop and delete data). Logs are in `/tmp/ferrum-bench/log/`.

## 3. A guided tour

Use two terminals. **Terminal B** plays the customer's server; **terminal A** is you.

### 3.1 Create an account and a webhook (terminal A)

```bash
GW=http://127.0.0.1:8100; J='content-type: application/json'
curl -s -XPOST $GW/register -H "$J" -d '{"email":"me@example.com","password":"correct-horse-battery"}'
T=$(curl -s -XPOST $GW/login -H "$J" -d '{"email":"me@example.com","password":"correct-horse-battery"}' | jq -r .access_token)
AUTH="Authorization: Bearer $T"
curl -s -XPOST $GW/webhooks -H "$AUTH" -H "$J" -d '{"url":"http://127.0.0.1:9100/hook","event_type":"order.created"}' | tee /tmp/webhook.json
```
Copy the `secret` from the output; it is used to sign every message.

### 3.2 Receive a signed message (terminal B, then A)

```bash
# terminal B: prints each delivery and checks its signature
WEBHOOK_SECRET=<the secret> PORT=9100 python3 infra/tests/echo_receiver.py
```
```bash
# terminal A: send an event
curl -s -XPOST $GW/events -H "$AUTH" -H "$J" -d '{"event_type":"order.created","payload":{"order_id":42}}'
```
Terminal B prints the message with `signature=VALID`. See the log Ferrum kept: `curl -s $GW/deliveries/<event_id> -H "$AUTH" | jq`.

### 3.3 Make the receiver fail

Restart terminal B with the first two requests failing: `FAIL_FIRST=2 WEBHOOK_SECRET=<secret> PORT=9100 python3 infra/tests/echo_receiver.py`, then send another event.
You'll see the first attempt fail, a second about 6 seconds later, a third about 11 seconds after that, which succeeds. Every attempt carries the same message id, so a receiver can tell it's the same event.

To see a delivery give up, use `FAIL_FIRST=100` and wait about 75 seconds: it becomes `dead_letter`. Fix the receiver, then re-send it:
```bash
curl -s "$GW/deliveries?status=dead_letter" -H "$AUTH" | jq '.[].event_id'
curl -s -XPOST $GW/retry/<event_id> -H "$AUTH"
```

### 3.4 Sending the same request twice

```bash
for i in 1 2 3; do curl -s -o /dev/null -w "%{http_code} " -XPOST $GW/events -H "$AUTH" -H "$J" -H 'Idempotency-Key: order-42' -d '{"event_type":"order.created","payload":{"order_id":42}}'; done; echo
```
You get `202 200 200`: one event, however many times you press send. The same key with a different body is refused (`422`).

### 3.5 Crash the worker mid-delivery

```bash
# terminal B: hold ONLY the first request for 30 s, so the delivery is "in flight"
DELAY=30 DELAY_FIRST=1 WEBHOOK_SECRET=<the secret> PORT=9100 python3 infra/tests/echo_receiver.py

# terminal A: short timers so recovery takes seconds, not minutes
LEASE_SECONDS=3 RECLAIM_IDLE_MS=4000 RECLAIM_INTERVAL_SECONDS=2 infra/local/stack.sh restart worker
curl -s -XPOST $GW/events -H "$AUTH" -H "$J" -d '{"event_type":"order.created","payload":{"n":3}}' | jq -r .event_id
sleep 2; infra/local/stack.sh kill9 worker          # simulate a crash
LEASE_SECONDS=3 RECLAIM_IDLE_MS=4000 RECLAIM_INTERVAL_SECONDS=2 infra/local/stack.sh restart worker
```
A new worker notices the abandoned job and finishes it. In the recorded run it completed 2.6 seconds after the crash, and the receiver saw exactly two attempts (the abandoned one and the finished one). With the normal settings this takes about a minute and a half.

### 3.6 Rate limit

```bash
RATE_LIMIT_CAPACITY=5 RATE_LIMIT_REFILL_PER_SEC=1 infra/local/stack.sh restart gateway
T=$(curl -s -XPOST $GW/login -H "$J" -d '{"email":"me@example.com","password":"correct-horse-battery"}' | jq -r .access_token); AUTH="Authorization: Bearer $T"
for i in $(seq 8); do curl -s -o /dev/null -w "%{http_code} " $GW/webhooks -H "$AUTH"; done; echo       # 200 x5, then 429 429 429
infra/local/stack.sh restart gateway
```

### 3.7 The private-address check

The local setup allows local addresses (its test receiver is one). Turn the check on and try some addresses Ferrum must refuse:

```bash
ALLOW_PRIVATE_WEBHOOK_TARGETS=false infra/local/stack.sh restart gateway
T=$(curl -s -XPOST $GW/login -H "$J" -d '{"email":"me@example.com","password":"correct-horse-battery"}' | jq -r .access_token); AUTH="Authorization: Bearer $T"
for u in http://169.254.169.254/ http://127.0.0.1:6379/ http://10.0.0.5/ http://localhost/; do
  curl -s -XPOST $GW/webhooks -H "$AUTH" -H "$J" -d "{\"url\":\"$u\",\"event_type\":\"x\"}" | jq -c .detail; done
infra/local/stack.sh restart gateway
```

### 3.8 Look inside

```bash
infra/local/stack.sh psql -c "select status, count(*) from deliveries group by 1"
curl -s $GW/metrics | grep '^gateway_'
```

## 4. Stop

`infra/local/stack.sh down`

## Troubleshooting

| Problem | Fix |
|---|---|
| `port … is held by another process` | `infra/local/stack.sh doctor --kill`, then `up` again |
| `422 Webhook URL rejected` | the private-address check is on; use a public URL, or leave `ALLOW_PRIVATE_WEBHOOK_TARGETS` at its local default |
| Events stay `pending` | the worker or Redis isn't running: `infra/local/stack.sh status` |
| `bad interpreter` when running `.venv/bin/pytest` | use `.venv/bin/python -m pytest` |

For Kubernetes, see [deployment](deployment.md). For load tests, see the [infra README](../infra/README.md).
