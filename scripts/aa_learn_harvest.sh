#!/usr/bin/env bash
# Collect the audit records the workload produced under the learning profile,
# then unload the stub. Pairs with aa_learn_start.sh.
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
usage: aa_learn_harvest.sh --state DIR --out LOGFILE [--settle SECONDS] [--keep-loaded]
USAGE
  exit 2
}

STATE="" OUT="" SETTLE="3" KEEP_LOADED="false"
while [ $# -gt 0 ]; do
  case "$1" in
    --state) STATE="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --settle) SETTLE="$2"; shift 2 ;;
    --keep-loaded) KEEP_LOADED="true"; shift ;;
    -h|--help) usage ;;
    *) echo "aa_learn_harvest.sh: unknown argument '$1'" >&2; usage ;;
  esac
done
[ -n "$STATE" ] && [ -n "$OUT" ] || usage
[ -f "$STATE/profile" ] || {
  echo "aa_learn_harvest.sh: no learning state in $STATE; did aa_learn_start.sh run?" >&2
  exit 2; }

LEARN_PROFILE="$(cat "$STATE/profile")"
STUB="$(cat "$STATE/stub")"
MARKER="$(cat "$STATE/marker")"

unload() {
  if [ "$KEEP_LOADED" != "true" ] && [ -f "$STUB" ]; then
    sudo apparmor_parser -R "$STUB" >/dev/null 2>&1 || true
  fi
}
trap unload EXIT

# Audit records are emitted asynchronously; give the kernel a moment.
sleep "$SETTLE"

matches_in() {
  grep -c "profile=\"$LEARN_PROFILE" "$1" 2>/dev/null || true
}

# Sources are tried in order and the first that yields records wins. dmesg and
# `journalctl -k` read the same kernel ring buffer, so harvesting both would
# only duplicate every record.
: > "$OUT"
if MSGS="$(sudo dmesg 2>/dev/null)"; then
  if [ -n "$MARKER" ] && printf '%s\n' "$MSGS" | grep -qF -- "$MARKER"; then
    printf '%s\n' "$MSGS" | sed -n "/$MARKER/,\$p" > "$OUT"
  else
    printf '%s\n' "$MSGS" > "$OUT"
  fi
fi

if [ "$(matches_in "$OUT")" = "0" ] && command -v journalctl >/dev/null 2>&1; then
  # shellcheck disable=SC2024  # only the read needs sudo; $OUT is the runner's
  sudo journalctl -k --no-pager -o cat 2>/dev/null > "$OUT" || true
fi

# auditd, where present, keeps records the ring buffer may already have
# rotated out. $OUT belongs to the runner user, so only the read needs sudo.
if sudo test -r /var/log/audit/audit.log; then
  sudo grep -h 'apparmor=' /var/log/audit/audit.log 2>/dev/null \
    | grep -F "profile=\"$LEARN_PROFILE" >> "$OUT" || true
fi

MATCHED="$(matches_in "$OUT")"
echo "harvested $(wc -l < "$OUT") log lines, $MATCHED for $LEARN_PROFILE -> $OUT"

if [ "$MATCHED" = "0" ]; then
  echo "aa_learn_harvest.sh: no audit records for $LEARN_PROFILE." >&2
  echo "                     The workload did not run under the learning profile." >&2
  exit 4
fi
