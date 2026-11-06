#!/usr/bin/env bash
# Exercise a running workload over HTTP. Every URL is passed to curl as an
# argv element and must be http(s), so none of it reaches a shell.
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
usage: probe.sh [--ready URL] [--ready-timeout N] [--timeout N] [--fail-fast] [URL...]

  --ready URL          poll until this returns 2xx/3xx before probing
  --ready-timeout N    seconds to wait for readiness (default 60)
  --timeout N          per-request timeout in seconds (default 10)
  --fail-fast          stop at the first probe that fails
USAGE
  exit 2
}

READY="" READY_TIMEOUT=60 TIMEOUT=10 FAIL_FAST="false"
urls=()
while [ $# -gt 0 ]; do
  case "$1" in
    --ready) READY="$2"; shift 2 ;;
    --ready-timeout) READY_TIMEOUT="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --fail-fast) FAIL_FAST="true"; shift ;;
    -h|--help) usage ;;
    --) shift; while [ $# -gt 0 ]; do urls+=("$1"); shift; done ;;
    -*) echo "probe.sh: unknown option '$1'" >&2; usage ;;
    *) urls+=("$1"); shift ;;
  esac
done

validate() {
  case "$1" in
    http://*|https://*) ;;
    *) echo "probe.sh: refusing non-http(s) URL '$1'" >&2; exit 2 ;;
  esac
}

if [ -n "$READY" ]; then
  validate "$READY"
  echo "waiting up to ${READY_TIMEOUT}s for $READY"
  deadline=$((SECONDS + READY_TIMEOUT))
  until curl -fsS --max-time "$TIMEOUT" -o /dev/null -- "$READY"; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      echo "probe.sh: $READY never became ready within ${READY_TIMEOUT}s" >&2
      exit 1
    fi
    sleep 1
  done
  echo "ready"
fi

failures=0
for url in ${urls[@]+"${urls[@]}"}; do
  validate "$url"
  if curl -fsS --max-time "$TIMEOUT" -o /dev/null -- "$url"; then
    echo "ok    $url"
  else
    echo "::warning::probe failed: $url"
    failures=$((failures + 1))
    [ "$FAIL_FAST" = "true" ] && break
  fi
done

if [ "$failures" -gt 0 ]; then
  echo "probe.sh: $failures probe(s) failed" >&2
  exit 1
fi
