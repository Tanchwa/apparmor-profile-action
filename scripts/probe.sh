#!/usr/bin/env bash
# Exercise a running workload over HTTP.
#
# Every value arrives as an argv element and nothing reaches a shell. URLs must
# be http(s). Headers and request bodies are never echoed, because a caller can
# legitimately put a signature or token in them and workflow inputs are not
# registered for log masking.
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
usage: probe.sh [options] [SPEC...]

  --ready URL            poll until this answers before probing
  --ready-timeout N      seconds to wait for readiness (default 60)
  --ready-expect STATUS  status that counts as ready (default any)
  --timeout N            per-request timeout in seconds (default 10)
  --header "Name: value" header sent with every request (repeatable)
  --body-file FILE       request body, sent for any method except GET/HEAD
  --fail-fast            stop at the first probe that fails

SPEC is one of:
  URL                    GET, expect 2xx
  METHOD URL             expect 2xx
  METHOD STATUS URL      expect exactly this status

STATUS is "any", a class such as 2xx/4xx, or an exact code such as 401.
A service whose only route is an authenticated POST is probed with its real
status, e.g. "POST 401 http://localhost:5000/webhook", so the handler runs
even though the request is meant to be rejected.
USAGE
  exit 2
}

READY="" READY_TIMEOUT=60 READY_EXPECT="any" TIMEOUT=10
BODY_FILE="" FAIL_FAST="false"
headers=() specs=()

while [ $# -gt 0 ]; do
  case "$1" in
    --ready) READY="$2"; shift 2 ;;
    --ready-timeout) READY_TIMEOUT="$2"; shift 2 ;;
    --ready-expect) READY_EXPECT="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --header) headers+=("$2"); shift 2 ;;
    --body-file) BODY_FILE="$2"; shift 2 ;;
    --fail-fast) FAIL_FAST="true"; shift ;;
    -h|--help) usage ;;
    --) shift; while [ $# -gt 0 ]; do specs+=("$1"); shift; done ;;
    -*) echo "probe.sh: unknown option '$1'" >&2; usage ;;
    *) specs+=("$1"); shift ;;
  esac
done

validate_url() {
  case "$1" in
    http://*|https://*) ;;
    *) echo "probe.sh: refusing non-http(s) URL '$1'" >&2; exit 2 ;;
  esac
}

# expected actual -> 0 when the response is the one we asked for
match_status() {
  case "$1" in
    any) [ "$2" != "000" ] ;;
    [1-5]xx) [ "${2#"${2%?}"}" != "" ] && [ "${2:0:1}" = "${1:0:1}" ] ;;
    *) [ "$1" = "$2" ] ;;
  esac
}

# method url -> prints the HTTP status, or 000 if nothing answered
request() {
  local method="$1" url="$2"
  local args=(-sS -o /dev/null -w '%{http_code}' --max-time "$TIMEOUT"
              -X "$method")
  local h
  for h in ${headers[@]+"${headers[@]}"}; do args+=(-H "$h"); done
  case "$method" in
    GET|HEAD) ;;
    *) [ -n "$BODY_FILE" ] && args+=(--data-binary "@$BODY_FILE") ;;
  esac
  # curl writes %{http_code} even when it fails, and exits non-zero. Appending
  # our own fallback would yield "000000", which is not the "000" that means
  # "nothing answered" -- a dead endpoint would then pass an "any" check.
  local code
  code="$(curl "${args[@]}" -- "$url" 2>/dev/null)" || true
  printf '%s' "${code:-000}"
}

if [ -n "$READY" ]; then
  validate_url "$READY"
  echo "waiting up to ${READY_TIMEOUT}s for $READY (expecting $READY_EXPECT)"
  deadline=$((SECONDS + READY_TIMEOUT))
  while :; do
    code="$(request GET "$READY")"
    if match_status "$READY_EXPECT" "$code"; then
      echo "ready (HTTP $code)"
      break
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      echo "probe.sh: $READY never became ready within ${READY_TIMEOUT}s (last status ${code})" >&2
      exit 1
    fi
    sleep 1
  done
fi

failures=0
for spec in ${specs[@]+"${specs[@]}"}; do
  # shellcheck disable=SC2206  # deliberate word split: "METHOD STATUS URL"
  parts=($spec)
  case "${#parts[@]}" in
    1) method=GET      expect=2xx           url="${parts[0]}" ;;
    2) method="${parts[0]}" expect=2xx      url="${parts[1]}" ;;
    3) method="${parts[0]}" expect="${parts[1]}" url="${parts[2]}" ;;
    *) echo "probe.sh: cannot parse probe '$spec'" >&2; exit 2 ;;
  esac

  case "$method" in
    [A-Z][A-Z]*) ;;
    *) echo "probe.sh: '$method' is not an HTTP method (use upper case)" >&2; exit 2 ;;
  esac
  validate_url "$url"

  code="$(request "$method" "$url")"
  if match_status "$expect" "$code"; then
    printf 'ok    %-6s %s -> %s\n' "$method" "$url" "$code"
  else
    printf '::warning::probe failed: %s %s -> %s (expected %s)\n' \
      "$method" "$url" "$code" "$expect"
    failures=$((failures + 1))
    [ "$FAIL_FAST" = "true" ] && break
  fi
done

if [ "$failures" -gt 0 ]; then
  echo "probe.sh: $failures probe(s) failed" >&2
  exit 1
fi
