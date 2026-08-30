# LogsQL reference

Working reference for querying VictoriaLogs. Fuller documentation lives at
<https://docs.victoriametrics.com/victorialogs/logsql/>.

A query is a set of **filters**, optionally followed by **pipes**.

## Filters

### Message filters

| Filter | Meaning |
|---|---|
| `error` | the word `error` appears in `_msg` |
| `"connection refused"` | that exact phrase |
| `err*` | a word starting with `err` |
| `"unexpected fail"*` | phrase-prefix |
| `*ampl*` | substring anywhere in a word |
| `~"5[0-9][0-9]"` | regexp |
| `i(error)` | case-insensitive |
| `="exact message"` | the field equals this value exactly |

A bare word searches `_msg` only. To search across every field, prefix with `*:`:

```
*:nginx
```

### Field filters

```
kubernetes.pod_namespace:media
log.level:error
log.level:"error message"
log.level:i("error")
log.level:in("error", "fatal")
kubernetes.pod_name:immich*
_msg:~"timeout|refused"
```

### Time filters

`_time:` accepts durations relative to now, absolute instants, and ranges:

```
_time:5m                            # last five minutes
_time:2.5d                          # last two and a half days
_time:2026-08-30Z                   # that whole day
_time:2026-08Z                      # that whole month
_time:[2026-08-01Z, 2026-09-01Z)    # explicit range, end exclusive
_time:>2026-08-25Z
```

`cluster-logs.sh` prepends `_time:<--since>` unless your query already contains
`_time:`, so pass a `_time:` filter yourself whenever you want an absolute range.

### Logical operators

`AND` is implicit between adjacent filters. `OR` and `NOT` are not.

```
error _time:5m                      # both — the space means AND
error AND _time:5m                  # identical, just explicit
(app:sonarr OR app:radarr) error
error NOT healthcheck
error -healthcheck                  # same as NOT
error !healthcheck                  # also the same
```

Parenthesise `OR` groups. `a OR b c` does not mean what it looks like.

Comments run to end of line with `#`:

```
_time:5m error # only the recent ones
```

## Pipes

Pipes post-process matches, left to right.

```
| stats count() total
| stats by (kubernetes.pod_namespace) count() n
| sort by (_time) desc
| limit 10
| top 10 by (kubernetes.pod_name)
| fields _time, _msg
| filter error_rate:>0.1
```

Useful shapes:

```
# error count per namespace over the last day
_time:24h error | stats by (kubernetes.pod_namespace) count() n | sort by (n) desc

# the ten noisiest pods
_time:1h * | top 10 by (kubernetes.pod_name)
```

Aggregating with `| stats` changes the response shape, so the script's
`text` output no longer applies. Use `-o json` for those queries.

## Fields in this cluster

Vector's aggregator sets these as stream fields, so they are the reliable ones
to filter on:

| Field | Meaning |
|---|---|
| `_time` | timestamp |
| `_msg` | the log message |
| `_stream` | the stream's label set |
| `kubernetes.pod_name` | pod |
| `kubernetes.container_name` | container |
| `kubernetes.pod_namespace` | namespace |
| `stream` | `stdout` / `stderr` |

Journald records come from a separate pipeline and carry `host` and unit
metadata rather than the `kubernetes.*` fields.

Vector parses JSON log bodies into a nested `log` object where it can, so
structured emitters expose `log.level`, `log.msg` and similar. Applications
logging plain text put everything in `_msg`.

When unsure what exists, ask VictoriaLogs rather than guessing — these endpoints
sit alongside `/select/logsql/query` on the same base URL:

```
/select/logsql/field_names          # every field name, with counts
/select/logsql/field_values         # values for one field
/select/logsql/streams              # distinct streams
/select/logsql/hits                 # counts bucketed over time
```
