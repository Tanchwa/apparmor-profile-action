#!/usr/bin/env bash
# A caller can interpolate a secret into docker_env / host_env. Reusable
# workflow *inputs* are not registered for log masking the way secrets.* are,
# so an action that echoes argv verbatim would print that secret to the build
# log. This runs the shipped steps with a stub executable and asserts the
# sentinel value never reaches stdout, while still reaching the command.
set -euo pipefail

cd "$(dirname "$0")/.."
PYTHON="${PYTHON:-python3}"
SENTINEL="s3cr3t-sentinel-do-not-log"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

# Stubs record argv to a file so the harness itself never prints the secret.
for name in docker timeout env sudo; do
  cat > "$tmp/bin/$name" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$tmp/argv.log"
STUB
  chmod +x "$tmp/bin/$name"
done

extract() {  # extract <action.yml> <step name> <dest>
  "$PYTHON" - "$1" "$2" "$3" <<'PY'
import sys, yaml
action, name, dest = sys.argv[1:4]
doc = yaml.safe_load(open(action))
step = next(s for s in doc["runs"]["steps"] if s["name"] == name)
open(dest, "w").write(step["run"])
PY
}

failures=0
check_stdout() {  # check_stdout <label> <captured output>
  if printf '%s' "$2" | grep -qF "$SENTINEL"; then
    echo "FAIL     $1: the sentinel value was echoed to the log"
    failures=$((failures + 1))
  else
    echo "ok       $1: env values are redacted in the log"
  fi
}

export PATH="$tmp/bin:$PATH"
export RUNNER_TEMP="$tmp" GITHUB_RUN_ID=1 GITHUB_RUN_ATTEMPT=1

# --- docker ----------------------------------------------------------------
extract _docker/action.yml "Run the container under the learning profile" "$tmp/docker.sh"
out="$(
  ACTION_PATH="$PWD/_docker" LEARN_PROFILE="aa-learn-t" IMAGE="img:t" \
  ENTRYPOINT="" CONTAINER_ARGS="" VOLUMES="" CONTAINER_USER="" WORKDIR="" NETWORK="" \
  PORTS="" CONTAINER_ENV="TOKEN=$SENTINEL" \
  DETACH=false READY_URL="" READY_TIMEOUT=1 PROBE_URLS="" PROBE_TIMEOUT=1 \
  RUN_TIMEOUT=5 STOP_TIMEOUT=1 ALLOW_FAILURE=true \
  bash "$tmp/docker.sh" 2>&1
)"
check_stdout "docker" "$out"

# --- host ------------------------------------------------------------------
extract _host/action.yml "Run the binary under the learning profile" "$tmp/host.sh"
out="$(
  ACTION_PATH="$PWD/_host" BINARY="/bin/echo" BINARY_ARGS="" \
  BINARY_ENV="TOKEN=$SENTINEL" WORKDIR="" RUN_AS="" \
  DETACH=false READY_URL="" READY_TIMEOUT=1 PROBE_URLS="" PROBE_TIMEOUT=1 \
  RUN_TIMEOUT=5 STOP_SIGNAL=TERM STOP_TIMEOUT=1 ALLOW_FAILURE=true \
  bash "$tmp/host.sh" 2>&1
)"
check_stdout "host" "$out"

# The real command must still receive the true value -- redaction is for the
# log only, never for what the workload actually gets.
if [ -f "$tmp/argv.log" ] && grep -qF "$SENTINEL" "$tmp/argv.log"; then
  echo "ok       the executed command still receives the real value"
else
  echo "FAIL     redaction altered what the command receives"
  failures=$((failures + 1))
fi

exit "$failures"
