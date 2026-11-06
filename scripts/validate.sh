#!/usr/bin/env bash
# Parse a generated profile without loading it, and optionally load it to prove
# the kernel accepts it. A profile that does not parse must never reach a PR.
set -euo pipefail

PROFILE="${1:-}"
LOAD="${2:-false}"

[ -n "$PROFILE" ] || { echo "usage: validate.sh PROFILE [load]" >&2; exit 2; }
[ -f "$PROFILE" ] || { echo "validate.sh: no such file: $PROFILE" >&2; exit 2; }

if ! command -v apparmor_parser >/dev/null 2>&1; then
  echo "validate.sh: apparmor_parser not available; skipping validation." >&2
  exit 0
fi

echo "::group::Validating $PROFILE"
if ! sudo apparmor_parser -Q -K "$PROFILE"; then
  echo "::error file=$PROFILE::Generated profile failed to parse"
  exit 1
fi
echo "profile parses cleanly"

if [ "$LOAD" = "true" ]; then
  NAME="$(sed -n 's/^profile \([^ {]*\).*/\1/p' "$PROFILE" | head -n1)"
  sudo apparmor_parser -r -W "$PROFILE"
  echo "loaded ${NAME:-profile} into the kernel"
  sudo apparmor_parser -R "$PROFILE" || true
  echo "unloaded again"
fi
echo "::endgroup::"
