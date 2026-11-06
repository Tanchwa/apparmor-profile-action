#!/usr/bin/env bash
# Exercise probe.sh against a local server that returns whatever status the
# path asks for, so the status-matching grammar is covered without a network.
set -euo pipefail

cd "$(dirname "$0")/.."
PYTHON="${PYTHON:-python3}"
tmp="$(mktemp -d)"
failures=0

# shellcheck disable=SC2329  # invoked via trap
cleanup() {
  [ -n "${server_pid:-}" ] && kill "$server_pid" 2>/dev/null
  rm -rf "$tmp"
}
trap cleanup EXIT

cat > "$tmp/server.py" <<'PY'
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer


class H(BaseHTTPRequestHandler):
    def _go(self):
        # /status/<code> returns that code; anything else is 200.
        parts = self.path.strip("/").split("/")
        code = int(parts[1]) if len(parts) == 2 and parts[0] == "status" else 200
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        # Record what arrived so the harness can assert on it.
        with open(sys.argv[2], "a") as fh:
            fh.write("%s %s hdr=%s body=%s\n" % (
                self.command, self.path,
                self.headers.get("X-Probe-Test", "-"), body.decode() or "-"))
        self.send_response(code)
        self.end_headers()

    do_GET = do_POST = do_PUT = do_DELETE = do_HEAD = _go

    def log_message(self, *a):
        pass


HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY

port=8731
"$PYTHON" "$tmp/server.py" "$port" "$tmp/seen.log" &
server_pid=$!
base="http://127.0.0.1:$port"

# Wait for the server before asserting anything about probe.sh.
for _ in $(seq 50); do
  curl -s -o /dev/null "$base/status/200" 2>/dev/null && break
  sleep 0.1
done

expect() {  # expect <label> <expected exit> <args...>
  local label="$1" want="$2"; shift 2
  local got=0
  ./scripts/probe.sh "$@" >/dev/null 2>&1 || got=$?
  if [ "$got" = "$want" ]; then
    echo "ok       probe/$label"
  else
    echo "FAIL     probe/$label (exit $got, wanted $want)"
    failures=$((failures + 1))
  fi
}

expect "bare-url-2xx"        0 "$base/status/200"
expect "bare-url-404-fails"  1 "$base/status/404"
expect "explicit-404-passes" 0 "GET 404 $base/status/404"
expect "class-4xx"           0 "GET 4xx $base/status/418"
expect "class-mismatch"      1 "GET 2xx $base/status/503"
expect "any-status"          0 "GET any $base/status/500"
expect "post-method"         0 "POST $base/status/200"
expect "exact-code-401"      0 "POST 401 $base/status/401"
expect "non-http-refused"    2 "ftp://example.invalid/x"
expect "lowercase-method"    2 "post $base/status/200"
expect "unparseable"         2 "A B C D"

# Readiness: "any" must accept a non-2xx answer, a code must not.
expect "ready-any"      0 --ready "$base/status/405" --ready-expect any --ready-timeout 3
expect "ready-exact"    0 --ready "$base/status/200" --ready-expect 200 --ready-timeout 3
expect "ready-mismatch" 1 --ready "$base/status/405" --ready-expect 2xx --ready-timeout 2
expect "ready-dead"     1 --ready "http://127.0.0.1:1/x" --ready-timeout 2

# Headers and a body must reach the server...
: > "$tmp/seen.log"
printf '%s' '{"hello":"world"}' > "$tmp/body.json"
out="$(./scripts/probe.sh --header "X-Probe-Test: sentinel-hdr" \
         --body-file "$tmp/body.json" "POST $base/status/200" 2>&1)"
if grep -q 'hdr=sentinel-hdr' "$tmp/seen.log" && grep -q 'body={"hello":"world"}' "$tmp/seen.log"; then
  echo "ok       probe/header-and-body-delivered"
else
  echo "FAIL     probe/header-and-body-delivered"
  cat "$tmp/seen.log"
  failures=$((failures + 1))
fi

# ...but must never be echoed: either can carry a signature or token.
if printf '%s' "$out" | grep -qE 'sentinel-hdr|hello'; then
  echo "FAIL     probe/header-and-body-not-logged"
  failures=$((failures + 1))
else
  echo "ok       probe/header-and-body-not-logged"
fi

# A GET must not carry the body even when one is configured.
: > "$tmp/seen.log"
./scripts/probe.sh --body-file "$tmp/body.json" "$base/status/200" >/dev/null 2>&1
if grep -q 'body=-' "$tmp/seen.log"; then
  echo "ok       probe/get-sends-no-body"
else
  echo "FAIL     probe/get-sends-no-body"
  failures=$((failures + 1))
fi

exit "$failures"
