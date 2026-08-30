#!/usr/bin/env bash
#
# cluster-logs — query VictoriaLogs with LogsQL, print terse greppable lines.
#
# Endpoint and credentials come entirely from the environment. Nothing about any
# particular cluster is baked in, which is what makes this safe to keep in a
# public repository.
set -euo pipefail

readonly PROG="${0##*/}"

die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

usage() {
  cat <<'USAGE'
Usage: cluster-logs [options] <logsql-query>

Query VictoriaLogs and print one tab-separated row per log line:

    <timestamp>    <namespace>/<pod>    <message>

Options:
  -s, --since DURATION   Time window as a LogsQL duration (default: 1h).
                         Skipped if the query already contains a _time: filter.
  -l, --limit N          Maximum lines to return (default: 100).
  -o, --output FORMAT    "text" (default) or "json" for raw VictoriaLogs objects.
  -h, --help             Show this help.

Environment:
  CLUSTER_LOGS_ENDPOINT      Required. Base URL that /select/logsql/query is
                             appended to. Either the Grafana datasource proxy:
                               https://grafana.example/api/datasources/proxy/uid/victorialogs
                             or VictoriaLogs directly:
                               https://logs.example

  Authentication — supply one of:
  CLUSTER_LOGS_TOKEN         A static bearer token (e.g. a Grafana service
                             account token). Takes precedence if set.
  AK_TOKEN_URL               Authentik token endpoint, with AK_CLIENT_ID and
  AK_CLIENT_ID               AK_CLIENT_SECRET. A short-lived token is minted per
  AK_CLIENT_SECRET           invocation, so no bearer token is ever at rest.

  CLUSTER_LOGS_AUTH_HEADER   Header carrying the token. Default "Authorization",
                             sent as "Bearer <token>". Set to "X-JWT-Assertion"
                             if Grafana's auth.jwt expects that header instead.

Examples:
  cluster-logs 'error'
  cluster-logs --since 15m --limit 20 'kubernetes.pod_namespace:media error'
  cluster-logs 'kubernetes.pod_name:immich* AND ~"5[0-9][0-9]"'
  cluster-logs --since 24h 'error' | awk -F'\t' '{print $2}' | sort | uniq -c | sort -rn
USAGE
}

since=1h
limit=100
output=text
query=

while [[ $# -gt 0 ]]; do
  case "$1" in
    -s|--since)  since="${2:?--since needs a duration}"; shift 2 ;;
    -l|--limit)  limit="${2:?--limit needs a number}"; shift 2 ;;
    -o|--output) output="${2:?--output needs a format}"; shift 2 ;;
    -h|--help)   usage; exit 0 ;;
    --)          shift; break ;;
    -*)          die "unknown option: $1 (try --help)" ;;
    *)           break ;;
  esac
done

[[ $# -gt 0 ]] || { usage >&2; exit 2; }
query="$*"

case "$output" in
  text|json) ;;
  *) die "--output must be 'text' or 'json', got '$output'" ;;
esac
[[ "$limit" =~ ^[0-9]+$ ]] || die "--limit must be a number, got '$limit'"

need curl
need jq

[[ -n "${CLUSTER_LOGS_ENDPOINT:-}" ]] \
  || die "CLUSTER_LOGS_ENDPOINT is not set — see --help for the endpoint and auth variables"

urlencode() { jq -rn --arg v "$1" '$v|@uri'; }

mint_token() {
  local body response token
  body="grant_type=client_credentials&scope=profile"
  body+="&client_id=$(urlencode "$AK_CLIENT_ID")"
  body+="&client_secret=$(urlencode "$AK_CLIENT_SECRET")"

  # The body goes over stdin rather than argv, so the client secret never shows
  # up in `ps` output.
  response=$(printf '%s' "$body" | curl -sS --fail-with-body -X POST "$AK_TOKEN_URL" \
    -H 'Content-Type: application/x-www-form-urlencoded' --data-binary @-) \
    || die "token request to $AK_TOKEN_URL failed: $response"

  token=$(printf '%s' "$response" | jq -r '.access_token // empty')
  [[ -n "$token" ]] || die "token endpoint returned no access_token: $response"
  printf '%s' "$token"
}

if [[ -n "${CLUSTER_LOGS_TOKEN:-}" ]]; then
  token="$CLUSTER_LOGS_TOKEN"
elif [[ -n "${AK_TOKEN_URL:-}" ]]; then
  [[ -n "${AK_CLIENT_ID:-}" ]]     || die "AK_TOKEN_URL is set but AK_CLIENT_ID is not"
  [[ -n "${AK_CLIENT_SECRET:-}" ]] || die "AK_TOKEN_URL is set but AK_CLIENT_SECRET is not"
  token=$(mint_token)
else
  die "no credentials: set CLUSTER_LOGS_TOKEN, or AK_TOKEN_URL with AK_CLIENT_ID and AK_CLIENT_SECRET"
fi

header_name="${CLUSTER_LOGS_AUTH_HEADER:-Authorization}"
if [[ "$header_name" == "Authorization" ]]; then
  header_value="Bearer $token"
else
  header_value="$token"
fi

# A bare word filter searches _msg, so an unscoped query over all of time is an
# easy way to ask for far more than anyone wants. Default the window unless the
# caller has expressed their own opinion about time.
if [[ "$query" != *"_time:"* ]]; then
  query="_time:${since} ${query}"
fi

url="${CLUSTER_LOGS_ENDPOINT%/}/select/logsql/query"

# The header is passed via a curl config file on stdin for the same reason the
# token request body was: -H would put the credential in argv.
run_query() {
  printf 'header = "%s: %s"\n' "$header_name" "$header_value" \
    | curl -sS --fail-with-body --max-time 120 -G "$url" --config - \
        --data-urlencode "query=${query}" \
        --data-urlencode "limit=${limit}"
}

if ! response=$(run_query); then
  printf '%s: query failed against %s\n' "$PROG" "$url" >&2
  printf '%s\n' "$response" >&2
  exit 1
fi

if [[ "$output" == json ]]; then
  printf '%s\n' "$response"
  exit 0
fi

# VictoriaLogs streams newline-delimited JSON. Collapse each object to the three
# things worth reading: when, where, what. Everything else (pod labels, stream
# ids, container metadata) is noise for a human or a model scanning output, and
# is still available via --output json.
printf '%s\n' "$response" | jq -r '
  def pick($k): if has($k) then .[$k] else null end;
  ( pick("kubernetes.pod_namespace") ) as $ns
  | ( pick("kubernetes.pod_name")
      // pick("host")
      // ( pick("_stream") | if . == "{}" then null else . end ) ) as $src
  | [ ( pick("_time") // "-" ),
      ( if $ns and $src then "\($ns)/\($src)" else ($src // "?") end ),
      ( pick("_msg") // "" ) ]
  | @tsv'
