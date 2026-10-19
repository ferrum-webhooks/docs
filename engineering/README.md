# Engineering notes

Eight short case studies from building Ferrum: a problem, what was tried, what was measured, what turned out to be wrong, and how to repeat it. Each starts with a two-sentence summary, so you can skim.

| # | Note | The question | The answer in one line |
|---|---|---|---|
| 01 | [Never lose an event](01-outbox.md) | How do you make "save it" and "queue it" happen together? | Save both in one database step. Ingest is now 5 database round trips, however many receivers there are. |
| 02 | [Surviving worker crashes](02-delivery-pipeline.md) | What if a worker dies mid-delivery? | Every crash point is covered. In a real test the delivery completed 2.6 s after the kill. |
| 03 | [Retries without waiting](03-retries.md) | How should a retry be scheduled? | Write the retry time in the database. No worker ever waits. |
| 04 | [The password that ate the memory](04-argon2-memory.md) | Why did logins crash the server? | Two settings cut memory from 806 MB to 106 MB. |
| 05 | [The freeze under load](05-connection-pool-deadlock.md) | Why did it stop at 200 users? | A circular wait. Before: 6 of 120 requests done in 57 s. After: 120 of 120 in 0.2 s. |
| 06 | [How fast is it?](06-ingest-performance.md) | What does it handle, and what helped? | 30% more throughput and half the delay; about 990 events/s with 4 processes. |
| 07 | [Trusting a message](07-webhook-security.md) | How does a receiver know it's genuine? | Signed messages, and a check that blocks private addresses. |
| 08 | [Following one event](08-tracing.md) | How do you debug one event's journey? | One timeline per event, for about 3% of speed. |

## Where the numbers come from

Every table comes from a script in [`infra/bench`](../../infra/bench) (or a service's `scripts/` folder); the command is at the end of each note, and the raw output is in [`../data`](../data).
Everything ran on one Apple M5 laptop with the load generator, database and receiver on the same machine, so absolute numbers are conservative. The comparisons between versions are the meaningful part.

## Lessons about measuring

These each cost at least one wasted run:

1. Keep the computer awake. A sleeping laptop produced "1000-second" delays.
2. Check that the program you're testing is the one that's running. A leftover process once answered for a new one, and another quietly did a worker's job.
3. Measure one thing at a time, then the whole.
4. Repeat each test and alternate the versions, because a single run varied by more than some of the improvements.
