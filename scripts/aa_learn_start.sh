#!/usr/bin/env bash
# Load a permissive complain-mode stub profile and record the state the
# harvest step needs. The caller then runs its workload under the profile
# whose name this prints; nothing here executes caller-supplied commands.
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
usage: aa_learn_start.sh --name NAME --state DIR [--template container|host] [--attach PATH]

  --name NAME        base name of the profile being learned
  --state DIR        directory to record learning state in
  --template         container (unattached) or host (attached to --attach)
  --attach PATH      binary the host stub attaches to
USAGE
  exit 2
}

NAME="" STATE="" TEMPLATE="container" ATTACH=""
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="$2"; shift 2 ;;
    --state) STATE="$2"; shift 2 ;;
    --template) TEMPLATE="$2"; shift 2 ;;
    --attach) ATTACH="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "aa_learn_start.sh: unknown argument '$1'" >&2; usage ;;
  esac
done
[ -n "$NAME" ] && [ -n "$STATE" ] || usage

command -v apparmor_parser >/dev/null 2>&1 || {
  echo "aa_learn_start.sh: apparmor_parser not found. Runtime learning needs an" >&2
  echo "                   AppArmor-enabled runner (ubuntu-*, not macos/windows)." >&2
  exit 3; }

if [ ! -d /sys/kernel/security/apparmor ]; then
  echo "aa_learn_start.sh: AppArmor is not enabled in this kernel." >&2
  echo "                   Use generator=spec, or an AppArmor-enabled runner." >&2
  exit 3
fi

mkdir -p "$STATE"
LEARN_PROFILE="aa-learn-$(printf '%s' "$NAME" | tr -c 'a-zA-Z0-9_.-' '-')"
STUB="$STATE/$LEARN_PROFILE"

# The stub allows nothing beyond abstractions/base and carries the complain
# flag, so every other access is permitted but logged as apparmor="ALLOWED".
# base is included here *and* in the generated profile, which is why leaving
# its accesses unlogged is safe.
{
  echo "include <tunables/global>"
  echo
  if [ "$TEMPLATE" = "host" ] && [ -n "$ATTACH" ]; then
    echo "profile $LEARN_PROFILE $ATTACH flags=(attach_disconnected,mediate_deleted,complain) {"
  else
    echo "profile $LEARN_PROFILE flags=(attach_disconnected,mediate_deleted,complain) {"
  fi
  echo "  include <abstractions/base>"
  echo "}"
} > "$STUB"

echo "::group::Loading learning profile $LEARN_PROFILE"
cat "$STUB"
sudo apparmor_parser -r -W "$STUB"
echo "::endgroup::"

# A marker in the kernel log bounds this run's records.
MARKER="aa-learn-marker-$$-$(od -An -N4 -tx4 /dev/urandom | tr -d ' ')"
sudo dmesg -n 7 >/dev/null 2>&1 || true
echo "$MARKER" | sudo tee /dev/kmsg >/dev/null 2>&1 || MARKER=""

printf '%s\n' "$LEARN_PROFILE" > "$STATE/profile"
printf '%s\n' "$STUB"          > "$STATE/stub"
printf '%s\n' "$MARKER"        > "$STATE/marker"

echo "learn_profile=$LEARN_PROFILE" >> "${GITHUB_OUTPUT:-/dev/null}"
echo "$LEARN_PROFILE"
