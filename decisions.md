# Design decisions

The main choices, in plain words. Each says what was chosen, why, and what it costs. The stories behind several of them are in the [engineering notes](engineering/README.md).

| # | Decision | Why | Cost |
|---|---|---|---|
| 1 | **Save the event and its "to send" note in one database step** (the outbox) | The first version saved the event, then queued it separately. A crash between the two silently lost events. | Delivery starts up to 0.2 s later, and a small extra table to maintain. [Note 01](engineering/01-outbox.md) |
| 2 | **Redis Streams as the queue, with "confirm only after it's recorded"** | A plain list forgets an item the moment a worker takes it. A stream keeps it until the worker confirms, so a crashed worker's job can be taken over. | Redis is not a permanent log; history lives in the database. [Note 02](engineering/02-delivery-pipeline.md) |
| 3 | **One row per (event, receiver), with every attempt logged separately** | One place for the current status, schedule and "who is working on it", plus a full history. | Migration dropped older per-attempt history. |
| 4 | **Retry times stored in the database, not in a sleeping worker** | Survives restarts; no worker is ever blocked; you can see what's waiting. | A retry fires up to about a second after it's due. [Note 03](engineering/03-retries.md) |
| 5 | **Follow the public "Standard Webhooks" signing format** | Receivers can use existing libraries; it includes replay protection and a stable message id for de-duplication. | Secrets must be readable by the worker, so they're stored in plain text in the database. [Note 07](engineering/07-webhook-security.md) |
| 6 | **Login tokens (JWT), no API keys yet** | The original brief asked for JWT. | No revocation; long-lived machine access would be better served by API keys. |
| 7 | **One user = one tenant; another user's items answer "not found"** | Simple isolation that doesn't reveal what exists. | No teams or roles yet. |
| 8 | **Check customer URLs for private addresses, twice** (when saved and before every send) | A customer could point Ferrum at its own internal network. DNS can change after saving. | A short window between the check and the connection remains open. [Note 07](engineering/07-webhook-security.md) |
| 9 | **Database migrations run once per release, not at every start** | Several copies starting together would collide; a failed migration should stop the rollout. | Releases only go forward; the old version can't run on the new schema. |
| 10 | **Separate "alive" from "ready" health checks** | A database hiccup should take a pod out of rotation, not restart it. The API doesn't need Redis to accept events, so Redis isn't part of its readiness. | |
| 11 | **Keep the synchronous Python stack and scale with more processes** | Simple code; the API waits on the database, not the CPU. | One process tops out around 550 requests/s. [Note 06](engineering/06-ingest-performance.md) |
| 12 | **Each request releases its database connection itself, and a busy server says "503, try again" within 5 s** | Waiting until the end of the request caused a freeze under load. | One extra tiny round trip on read requests. [Note 05](engineering/05-connection-pool-deadlock.md) |
| 13 | **Password hashing: smaller memory setting, at most 4 at once, tuned memory allocator** | 50 simultaneous logins crashed a small server. | Slightly weaker than the library default (still the recommended minimum). [Note 04](engineering/04-argon2-memory.md) |
| 14 | **The Helm chart installs only the app and never creates secrets** | Passwords in charts leak into release history; databases and apps have different lifecycles. | You create the secrets first (`create-secrets.sh`). |
| 15 | **Tests use a real Redis and Postgres; the test database must have "test" in its name** | The guarantees depend on features fakes don't have, and the tests wipe their tables. | Slower and needs both installed. [Testing](testing.md) |
| 16 | **Three small files are copied between the API and the worker** | Avoids a shared package for now. | They can drift apart; extract a shared package before adding a third service. |
