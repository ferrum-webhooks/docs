# Ferrum documentation

Ferrum delivers webhooks reliably: you send it an event, it makes sure each registered receiver gets it, retrying when things fail and keeping a log of every attempt.

## Where to start

| I want to… | Read |
|---|---|
| run it and try it | [quickstart](quickstart.md) |
| understand how it works | [architecture](architecture.md) |
| read the stories behind the design, with numbers | [engineering notes](engineering/README.md) |
| use the API or write a receiver | [API](api.md) |
| run it in production-like conditions | [deployment](deployment.md), [configuration](configuration.md) |
| fix a problem | [operations](operations.md) |

## All documents

| Document | What it covers |
|---|---|
| [quickstart](quickstart.md) | install, start, and a guided tour |
| [architecture](architecture.md) | the parts, how an event flows, what is guaranteed, known limits |
| [data model](data-model.md) | the database tables and the life of a delivery |
| [API](api.md) | every endpoint, and what a receiver gets |
| [configuration](configuration.md) | every setting |
| [security](security.md) | what is protected and what isn't |
| [observability](observability.md) | logs, metrics, traces |
| [deployment](deployment.md) | Kubernetes, Helm, secrets, health checks |
| [operations](operations.md) | what to check and what to do when something breaks |
| [testing](testing.md) | the tests and how to run them |
| [decisions](decisions.md) | the main design choices and why |
| [engineering notes](engineering/README.md) | eight write-ups: what went wrong, what was measured |
| [data/](data) | the raw numbers behind the write-ups |
