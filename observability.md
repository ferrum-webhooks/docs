# Observability

Three signals, one correlation key. **Metrics** say that something is wrong, **traces** say where, **logs** say what.
Every log line carries `request_id` and `trace_id`; every trace carries `ferrum.event_id`.

## 1. Logs
- JSON to stdout (`python-json-logger`), fields: `asctime, levelname, name, message, request_id, event_id, trace_id` + context (`service`, `delivery_id`, `status_code`, `latency`…).
- Gateway: one `request completed` line per request (method, path, status, latency). Worker: `delivery_success|retry_scheduled|dead_letter|skipped|cancelled`, `stream_messages_reclaimed`, `poison_message_dropped`, `consumer_*`, `shutdown_*`.
- Health/metrics endpoints are excluded from tracing but still logged at INFO by the gateway (they are noisy; filter on `path`).
- `request_id` is generated per gateway request, returned as `X-Request-ID`, stored on the outbox row and carried to the worker, so a customer-reported id finds both sides.

Useful queries (any log store; shown with `jq` on `kubectl logs`):
```bash
kubectl logs -n ferrum -l app=worker --since=10m | jq -c 'select(.message|startswith("delivery_")) | {message,event_id,attempt,status_code,error}'
kubectl logs -n ferrum -l app=gateway --since=10m | jq -c 'select(.status_code>=500)'
```

## 2. Metrics (Prometheus, scraped every 5 s from `gateway:8000/metrics` and `worker:8001/metrics`)

| Metric | Type | Meaning / use |
|---|---|---|
| `gateway_requests_total` | counter | all API requests (not labelled by route or status yet) |
| `gateway_request_latency_seconds` | histogram | API latency (SLO: p95 < 200 ms ingest) |
| `worker_events_processed_total` | counter | stream messages picked up |
| `worker_delivery_success_total` / `worker_delivery_failure_total` | counter | per attempt. Success rate = success / (success+failure) |
| `worker_delivery_latency_seconds` | histogram | endpoint response time (success only) |
| `worker_queue_delay_seconds` | histogram | event created → first attempt. **The** "is the pipeline keeping up" metric |
| `worker_end_to_end_latency_seconds` | histogram | event created → successful delivery |
| `worker_retry_attempts_total`, `worker_dlq_events_total` | counter | retries scheduled / dead letters |
| `worker_outbox_published_total` | counter | relay throughput |
| `worker_stream_reclaimed_total` | counter | `XAUTOCLAIM` takeovers = crashed/stalled workers |
| `worker_duplicate_messages_skipped_total` | counter | claim rejected a duplicate (expected small) |

Starter alert expressions (PromQL):
```promql
histogram_quantile(0.95, sum(rate(worker_queue_delay_seconds_bucket[5m])) by (le)) > 10         # pipeline falling behind
rate(worker_dlq_events_total[10m]) > 0                                                          # something is dead-lettering
rate(worker_stream_reclaimed_total[10m]) > 0                                                    # workers dying / stalling
histogram_quantile(0.95, sum(rate(gateway_request_latency_seconds_bucket[5m])) by (le)) > 0.2   # ingest SLO
```
Not exported yet: stream lag (`XINFO GROUPS`), outbox backlog, rate-limit 429 counts, per-status request counters.

## 3. Traces (OpenTelemetry → Jaeger)

### What a trace contains
```
POST /events                                   (ferrum-gateway)   ferrum.event_id, ferrum.deliveries
 ├─ EVALSHA                                    rate-limit script
 ├─ INSERT/SELECT …                            ingest transaction (one span per statement)
 └─ delivery.attempt  (attempt 1)              (ferrum-worker)    ferrum.delivery_id, ferrum.outcome
     ├─ UPDATE/SELECT …                        claim, load
     ├─ webhook.post                           server.address, http.response.status_code, ERROR if failed
     └─ INSERT delivery_attempts / UPDATE deliveries
 … (gap = the backoff; the retry is a *new* delivery.attempt in the SAME trace)
 └─ delivery.attempt  (attempt 2) …
```
The link is a W3C `traceparent` stored on `deliveries` and `outbox`, copied into the stream message, and used as the
parent context by the worker. Retries and replays reuse the delivery's traceparent (a replay re-stamps it with the replay request's context).

The outbound HTTP call to the customer is a **manual** span, not auto-instrumented `requests`: that would inject `traceparent` into requests to third parties and leak internal trace ids.

### Using it (debugging with traces, not logs)
1. Get an id: from the customer (`event_id`), or `X-Request-ID`, or a `trace_id` in a log line.
2. Open Jaeger (`kubectl port-forward -n ferrum svc/jaeger 16686:16686` → http://localhost:16686, service `ferrum-gateway`, tag `ferrum.event_id=evt_…`).
3. Read it: wide gap between `POST /events` and the first `delivery.attempt` = queue delay (relay/stream/consumer); long `webhook.post` = slow receiver; many red `webhook.post` = receiver failing; many gaps = backoff; a `delivery.attempt` with `ferrum.outcome=skipped|busy` = duplicate/contended message.

### Configuration
| Env | Default | |
|---|---|---|
| `OTEL_EXPORTER_OTLP_ENDPOINT` | unset | e.g. `http://jaeger:4318`. Unset → spans are created (trace ids in logs, propagation works) but nothing is exported |
| `OTEL_TRACES_SAMPLER_RATIO` | 1.0 (code), **0.1** in k8s config | Head sampling, parent-based, so a trace is kept or dropped as a whole |

> **Operational lesson.** At 100% sampling under load the in-memory Jaeger was OOM-killed and the gateway paid CPU for every DB span.
> Head sampling cannot "always keep errors"; that needs tail sampling in an OpenTelemetry Collector.
> Jaeger all-in-one is in-memory: traces vanish on restart. Use only for development.

Auto-instrumented: FastAPI (excluding `/healthz`, `/readyz`, `/metrics`), SQLAlchemy (per statement), Redis. Tests in
`tests/test_worker.py::test_one_trace_from_ingest_through_retry` and `…/test_webhooks_events.py::test_ingest_records_traceparent_for_the_worker`.

## 4. Dashboards
Grafana is deployed with a Prometheus datasource (`infra/k8s/config/grafana-datasource-config.yaml`). Dashboards are built by hand in the UI (NodePort 30300); none are provisioned as code yet.
