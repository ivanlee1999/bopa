#!/usr/bin/env bash
# Cross-app sync scenarios: bopa (Swift) and notable (Kotlin) driving their own engines through one
# real CouchDB, step by step, through every situation two devices can get into — see
# docs/couch-sync-vectors/interop-scenarios.json.
#
# Each step index is one invocation per device. Steps interleave, and a device's local content and
# sync state persist between them on disk, so "edit now, push two steps later" is a genuine offline
# edit rather than a simulation. Nothing is mocked: a failure means the two implementations really
# do disagree.
#
#   ./scripts/couch-scenarios.sh [couchdb-url]
#
# Needs a CouchDB with the `notes` database (docs/deploy/couchdb) and the notable checkout.
set -uo pipefail

COUCH_URL="${1:-${COUCH_URL:-http://127.0.0.1:5984}}"
COUCH_USER="${COUCH_USER:-sync}"
COUCH_PASSWORD="${COUCH_PASSWORD:-testsyncpw}"
NOTABLE_DIR="${NOTABLE_DIR:-/Users/ivan/workspace/eink/notable}"
BOPA_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCENARIO_FILE="${SCENARIO_FILE:-$BOPA_DIR/docs/couch-sync-vectors/interop-scenarios.json}"

# A fresh run id per run namespaces every document, so repeated runs share a database without
# colliding and a failed run's leftovers never poison the next one.
RUN_ID="${COUCH_SCENARIO_RUN:-$(date +%s)-$$}"
STATE_DIR="${COUCH_SCENARIO_STATE_DIR:-$(mktemp -d)}"

export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@21}"
export ANDROID_HOME="${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}"
export ANDROID_SDK_ROOT="$ANDROID_HOME"

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31m%s\033[0m\n' "$*"; }

# A database per run. Every device replays the change feed from zero, so sharing one database with
# past runs means every run re-reads every run before it — and each device's local store ends up
# holding the whole history rather than the scenario under test.
COUCH_DATABASE="${COUCH_DATABASE:-scenarios-$(printf '%s' "$RUN_ID" | tr -c 'a-z0-9' '-')}"

say "preflight: $COUCH_URL"
curl -fsS --user "$COUCH_USER:$COUCH_PASSWORD" "$COUCH_URL/_up" >/dev/null || {
  fail "cannot reach the server"; exit 1; }
curl -fsS --user "$COUCH_USER:$COUCH_PASSWORD" -X PUT "$COUCH_URL/$COUCH_DATABASE" >/dev/null || {
  fail "cannot create $COUCH_DATABASE"; exit 1; }
echo "database $COUCH_DATABASE"
STEPS=$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
print(max(len(s["steps"]) for s in d["scenarios"]))' "$SCENARIO_FILE")
echo "run $RUN_ID · $STEPS step indices · state in $STATE_DIR"

failures=()

# Documents written by neither app — a future schema, a corrupt body — injected straight into the
# database, because the point of those scenarios is input no client would produce.
inject_server_step() {
  local step=$1
  python3 - "$SCENARIO_FILE" "$step" "$RUN_ID" "$COUCH_URL" "$COUCH_DATABASE" \
    "$COUCH_USER" "$COUCH_PASSWORD" <<'PY'
import base64, json, sys, urllib.request, urllib.error

path, step, run, url, db, user, password = sys.argv[1:8]
step = int(step)
auth = base64.b64encode(f"{user}:{password}".encode()).decode()

def doc_id(scenario, logical):
    raw = f"{scenario}-{logical}-{run}"
    prefix = "notebook" if logical.startswith("nb") else "folder" if logical.startswith("fd") else "page"
    return f"{prefix}:{raw}"

def request(method, target, body=None):
    req = urllib.request.Request(target, method=method, data=body)
    req.add_header("Authorization", f"Basic {auth}")
    if body:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req) as response:
            return response.status, json.load(response)
    except urllib.error.HTTPError as error:
        return error.code, {}

for scenario in json.load(open(path))["scenarios"]:
    steps = scenario["steps"]
    if step >= len(steps) or steps[step].get("device") != "server":
        continue
    for op in steps[step]["do"]:
        if op["op"] != "putRaw":
            raise SystemExit(f"unsupported server op {op['op']}")
        target = f"{url}/{db}/{doc_id(scenario['name'], op['doc'])}"
        # Whatever revision is already there, so the injection lands rather than 409s.
        status, existing = request("GET", target)
        body = dict(op["json"])
        if status == 200 and "_rev" in existing:
            body["_rev"] = existing["_rev"]
        status, _ = request("PUT", target, json.dumps(body).encode())
        if status not in (200, 201):
            raise SystemExit(f"injecting {target} failed with {status}")
        print(f"  injected {doc_id(scenario['name'], op['doc'])}")
PY
}

run_ipad() {
  local step=$1 output status
  output=$(cd "$BOPA_DIR/NotableKit" && \
    BOPA_COUCH_URL="$COUCH_URL" BOPA_COUCH_USER="$COUCH_USER" \
    BOPA_COUCH_PASSWORD="$COUCH_PASSWORD" BOPA_COUCH_DATABASE="$COUCH_DATABASE" \
    COUCH_SCENARIO_FILE="$SCENARIO_FILE" COUCH_SCENARIO_STEP="$step" \
    COUCH_SCENARIO_STATE_DIR="$STATE_DIR" COUCH_SCENARIO_RUN="$RUN_ID" \
    swift test --filter CouchScenarioTests 2>&1)
  status=$?
  printf '%s\n' "$output" | grep -E "error:|XCTAssert|\[.*\] step" || true
  (( status == 0 )) && echo "  ipad ok"
  return $status
}

run_boox() {
  local step=$1 output status
  # Passed as project properties, not environment: app/build.gradle forwards them to the test JVM,
  # and a `-P` value belongs to this build. The environment a warm Gradle daemon reports belongs to
  # whichever build started it, so a per-step variable read that way is silently the wrong step —
  # and a scenario test that finds no step assumes itself away, which looks exactly like a pass.
  # `--rerun` (not `--rerun-tasks`) re-runs just this test task. Gradle does not track a test JVM's
  # environment as a task input, so without it every step after the first is UP-TO-DATE, does not
  # run, and leaves no receipt.
  output=$(cd "$NOTABLE_DIR" && ./gradlew --quiet :app:testDebugUnitTest --rerun \
    -PNOTABLE_COUCH_URL="$COUCH_URL" -PNOTABLE_COUCH_USER="$COUCH_USER" \
    -PNOTABLE_COUCH_PASSWORD="$COUCH_PASSWORD" -PNOTABLE_COUCH_DATABASE="$COUCH_DATABASE" \
    -PCOUCH_SCENARIO_FILE="$SCENARIO_FILE" -PCOUCH_SCENARIO_STEP="$step" \
    -PCOUCH_SCENARIO_STATE_DIR="$STATE_DIR" -PCOUCH_SCENARIO_RUN="$RUN_ID" \
    --tests 'com.ethran.notable.sync.couch.CouchScenarioTest' 2>&1)
  status=$?
  printf '%s\n' "$output" | grep -vE "^Running locally|^$" || true
  (( status == 0 )) && echo "  boox ok"
  return $status
}

# How many scenarios each device is supposed to act on at this step. A runner that skipped itself
# exits 0 and prints nothing, so "it passed" and "it never ran" look identical without this.
expected_for() {
  python3 -c '
import json,sys
step, device = int(sys.argv[2]), sys.argv[3]
scenarios = json.load(open(sys.argv[1]))["scenarios"]
print(sum(1 for s in scenarios
          if step < len(s["steps"]) and s["steps"][step].get("device") == device))' \
    "$SCENARIO_FILE" "$1" "$2"
}

check_receipt() {
  local step=$1 device=$2 expected actual
  expected=$(expected_for "$step" "$device")
  [ "$expected" = "0" ] && return 0
  actual=$(cat "$STATE_DIR/ran.$device.$step" 2>/dev/null || echo "none")
  if [ "$actual" != "$expected" ]; then
    fail "  $device ran $actual of $expected scenarios at step $step — it skipped itself"
    return 1
  fi
  return 0
}

for (( step = 0; step < STEPS; step++ )); do
  say "step $step"
  inject_server_step "$step" || failures+=("server injection at step $step")
  run_ipad "$step" || failures+=("ipad step $step")
  check_receipt "$step" ipad || failures+=("ipad did not run step $step")
  run_boox "$step" || failures+=("boox step $step")
  check_receipt "$step" boox || failures+=("boox did not run step $step")
done

say "result"
if (( ${#failures[@]} )); then
  fail "FAILED:"
  printf '  %s\n' "${failures[@]}"
  echo "kept for inspection — device state: $STATE_DIR, database: $COUCH_URL/$COUCH_DATABASE"
  exit 1
fi
printf '\033[1;32mAll scenarios converged:\033[0m both apps agreed at every step.\n'
curl -fsS --user "$COUCH_USER:$COUCH_PASSWORD" -X DELETE "$COUCH_URL/$COUCH_DATABASE" >/dev/null
rm -rf "$STATE_DIR"
