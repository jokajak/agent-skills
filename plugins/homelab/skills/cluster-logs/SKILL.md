---
name: cluster-logs
description: Search Kubernetes and journald logs stored in VictoriaLogs using LogsQL. Use when investigating what a pod, container, node or namespace logged — errors, crashes, restart loops, failed requests, or recent activity in the home-ops cluster — or when the user asks to look at cluster logs, pod logs, or what went wrong with a service.
license: MIT
compatibility: Requires curl (>= 7.76 for --fail-with-body), jq, and network access to the cluster's Grafana or VictoriaLogs endpoint. Credentials are supplied through environment variables.
metadata:
  author: jokajak
  version: "0.1.0"
---

# Cluster logs

Queries VictoriaLogs, which holds every Kubernetes pod log and node journald log
shipped by Vector. `scripts/cluster-logs.sh` handles authentication and collapses
each result to one tab-separated line:

```
<timestamp>    <namespace>/<pod>    <message>
```

Journald lines show a hostname instead of `namespace/pod`.

## Usage

```
scripts/cluster-logs.sh [-s DURATION] [-l N] [-o text|json] <logsql-query>
```

- `-s, --since` — time window, default `1h`. Skipped if the query already
  contains a `_time:` filter.
- `-l, --limit` — maximum lines, default `100`.
- `-o, --output` — `text` (default) or `json` for the raw VictoriaLogs objects.

Because output is plain text, prefer composing with standard tools over asking
for more rows and reading them all. This keeps large result sets out of context:

```bash
# Which pods are erroring most, over a day?
scripts/cluster-logs.sh -s 24h -l 5000 'error' | cut -f2 | sort | uniq -c | sort -rn | head

# Just the tail of a noisy stream
scripts/cluster-logs.sh -s 30m 'kubernetes.pod_namespace:ai' | tail -20

# Count without reading
scripts/cluster-logs.sh -s 6h 'OOMKilled' | wc -l
```

## Writing the query

The argument is **LogsQL**, not PromQL and not Lucene. The essentials:

| Intent | Syntax |
|---|---|
| Word in the message | `error` |
| Exact phrase | `"connection refused"` |
| Field equals | `kubernetes.pod_namespace:media` |
| Prefix | `immich*` |
| Substring | `*timeout*` |
| Regexp | `~"5[0-9][0-9]"` |
| Case-insensitive | `i(error)` |
| Combine (AND is implicit) | `media error` |
| Or / not | `(a OR b)`, `error -healthcheck` |

Two mistakes are worth avoiding specifically:

- **`AND` is implicit but `OR` is not.** `a b` means both; `a OR b` needs the
  keyword and usually parentheses.
- **A bare word only searches `_msg`.** To search every field, use `*:nginx`.

Read [references/logsql.md](references/logsql.md) for pipes (`| stats`, `| sort`,
`| top`), time-range syntax, and the field names this cluster actually populates.
Read it before writing anything beyond a simple word-and-field filter — guessing
at LogsQL wastes a round trip.

## Setup

The script reads everything from the environment and has no built-in defaults,
so it carries no cluster details of its own.

| Variable | Purpose |
|---|---|
| `CLUSTER_LOGS_ENDPOINT` | Base URL that `/select/logsql/query` is appended to |
| `CLUSTER_LOGS_TOKEN` | A static bearer token, *or*… |
| `AK_TOKEN_URL`, `AK_CLIENT_ID`, `AK_CLIENT_SECRET` | Authentik client-credentials, minted per invocation |
| `CLUSTER_LOGS_AUTH_HEADER` | Override the header carrying the token (default `Authorization`) |

`CLUSTER_LOGS_ENDPOINT` is either the Grafana datasource proxy —
`https://grafana.<domain>/api/datasources/proxy/uid/victorialogs` — or
VictoriaLogs directly, `https://logs.<domain>`. Only the base differs; the script
appends the same path either way.

Prefer the Authentik variables over a static token. They mint a short-lived JWT
per invocation, so no bearer token is ever written to disk.

## When it fails

- **`401`/`403`** — the token was rejected. If Grafana's `auth.jwt` is
  configured for `X-JWT-Assertion` rather than a bearer token, set
  `CLUSTER_LOGS_AUTH_HEADER=X-JWT-Assertion`.
- **`404` on the Grafana proxy path** — Grafana's datasource proxy may not pass
  through to the VictoriaLogs backend plugin. Point `CLUSTER_LOGS_ENDPOINT` at
  VictoriaLogs directly instead.
- **Empty output, no error** — the query matched nothing. Widen `--since` before
  suspecting the plumbing; the default window is only an hour. Confirm field
  names with a `*:<value>` search, which searches all fields rather than `_msg`.
