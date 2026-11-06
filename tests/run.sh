#!/usr/bin/env bash
# Golden-file tests for the profile generators. Run from the repo root.
# Refresh the expectations with: UPDATE_GOLDEN=1 tests/run.sh
set -euo pipefail

cd "$(dirname "$0")/.."
PYTHON="${PYTHON:-python3}"
UPDATE_GOLDEN="${UPDATE_GOLDEN:-}"
failures=0

check() {
  local label="$1" golden="$2" actual="$3"
  if [ -n "$UPDATE_GOLDEN" ]; then
    cp "$actual" "$golden"
    echo "updated  $label"
    return
  fi
  if diff -u "$golden" "$actual" > /tmp/aa-test-diff.$$ 2>&1; then
    echo "ok       $label"
  else
    echo "FAIL     $label"
    cat /tmp/aa-test-diff.$$
    failures=$((failures + 1))
  fi
  rm -f /tmp/aa-test-diff.$$
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# --- runtime generator ------------------------------------------------------
"$PYTHON" scripts/aa_from_logs.py tests/fixtures/audit.log \
  --profile aa-learn-myapp --name myapp --template container \
  --exclude '^/proc/\*/status$' -o "$tmp/container.profile" 2>/dev/null
check "runtime/container" tests/golden/container.profile "$tmp/container.profile"

"$PYTHON" scripts/aa_from_logs.py tests/fixtures/audit.log \
  --profile aa-learn-myapp --name myapp --template host \
  --attach /usr/bin/myapp --abi 3.0 --mode complain --no-generalize \
  -o "$tmp/host.profile" 2>/dev/null
check "runtime/host" tests/golden/host.profile "$tmp/host.profile"

# --- spec generator ---------------------------------------------------------
"$PYTHON" scripts/aa_from_spec.py tests/fixtures/minimal.spec.yaml \
  -o "$tmp/minimal.profile" 2>/dev/null
check "spec/minimal" tests/golden/minimal.profile "$tmp/minimal.profile"

"$PYTHON" scripts/aa_from_spec.py examples/apparmor.spec.yaml \
  -o "$tmp/example.profile" 2>/dev/null
check "spec/example" tests/golden/example.profile "$tmp/example.profile"

# --- failure modes ----------------------------------------------------------
if "$PYTHON" scripts/aa_from_logs.py tests/fixtures/audit.log \
     --profile aa-learn-nothing --name nothing -o /dev/null 2>/dev/null; then
  echo "FAIL     runtime/empty-match should exit non-zero"
  failures=$((failures + 1))
else
  echo "ok       runtime/empty-match"
fi

# A learned profile must never silently drop a capability the workload used.
if grep -q 'capability net_bind_service,' tests/golden/container.profile; then
  echo "ok       runtime/capabilities-preserved"
else
  echo "FAIL     runtime/capabilities-preserved"
  failures=$((failures + 1))
fi

# deny must not widen: "deny write" cannot take reads with it.
if grep -q 'deny "/etc/\*\*" w,' tests/golden/minimal.profile; then
  echo "ok       spec/deny-write-is-write-only"
else
  echo "FAIL     spec/deny-write-is-write-only"
  failures=$((failures + 1))
fi

# --- workflow wiring --------------------------------------------------------
if "$PYTHON" tests/check_wiring.py; then
  :
else
  failures=$((failures + 1))
fi

# --- no input may reach a shell ---------------------------------------------
# The sub-actions bake in their own commands. A `bash -c "$SOMETHING"` or an
# eval creeping back in would reopen the arbitrary-execution hole that the
# structured inputs exist to close.
if grep -rnE 'bash -c "\$|eval |sh -c "\$' _*/action.yml \
     .github/workflows/apparmor-profile.yml 2>/dev/null; then
  echo "FAIL     shell-execution of an input variable found above"
  failures=$((failures + 1))
else
  echo "ok       no input is executed as shell"
fi

# --- secrets must not reach the build log -----------------------------------
if ! PYTHON="$PYTHON" bash tests/check_no_secret_echo.sh; then
  failures=$((failures + 1))
fi

# --- parse with the real parser, when one is available ----------------------
if command -v apparmor_parser >/dev/null 2>&1; then
  for profile in tests/golden/*.profile; do
    if sudo apparmor_parser -Q -K "$profile" 2>/dev/null; then
      echo "ok       parse/$(basename "$profile")"
    else
      echo "FAIL     parse/$(basename "$profile")"
      failures=$((failures + 1))
    fi
  done
else
  echo "skip     apparmor_parser not available; syntax not checked against the real parser"
fi

if [ "$failures" -gt 0 ]; then
  echo
  echo "$failures test(s) failed"
  exit 1
fi
echo
echo "all tests passed"
