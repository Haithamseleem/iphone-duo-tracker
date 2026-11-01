#!/usr/bin/env bash
# Tests for runs.sh (run by the "Test chain script" workflow). A fake "gh" applies runs.sh's real --jq filters (with jq)
# to canned GitHub API answers, and a fake "sleep" moves each scenario on a step instead of waiting, so both the
# filters and the decisions are tested without touching GitHub.
set -u
here=$(cd "$(dirname "$0")" && pwd)
script="$here/runs.sh"
work=$(mktemp -d); bin="$work/bin"; mkdir -p "$bin"
t() { date -u -d "-$1 min" +%Y-%m-%dT%H:%M:%SZ; }

cat > "$bin/gh" <<'EOF'
#!/usr/bin/env bash
# Fake gh: "gh api <path> --jq <filter>" runs the filter over $FAKE/<file>; "gh run cancel <id>" is recorded.
if [ "$1" = "run" ] && [ "$2" = "cancel" ]; then echo "$3" >> "$FAKE/cancelled"; exit 0; fi
[ "$1" = "api" ] || { echo "fake gh: unexpected $*" >&2; exit 1; }
shift; path=''; filter='.'
while [ $# -gt 0 ]; do
  case "$1" in --jq) filter=$2; shift 2 ;; -X) shift 2 ;; *) [ -z "$path" ] && path=$1; shift ;; esac
done
step=$(cat "$FAKE/step")
case "$path" in
  */workflows/check.yml/runs*) [ -f "$FAKE/fail" ] && exit 1
    f="$FAKE/runs.$step.json"; [ -f "$f" ] || f="$FAKE/runs.json" ;;
  */actions/runs/*/jobs) id=${path%/jobs}; id=${id##*/}; f="$FAKE/jobs.$id.json"; [ -f "$f" ] || f="$FAKE/nojobs.json" ;;
  */actions/runs/*/force-cancel) exit 0 ;;
  */actions/runs/*) f="$FAKE/me.json" ;;
  *) echo "fake gh: unexpected path $path" >&2; exit 1 ;;
esac
jq -r "$filter" < "$f"
EOF
cat > "$bin/sleep" <<'EOF'
#!/usr/bin/env bash
echo $(( $(cat "$FAKE/step") + 1 )) > "$FAKE/step"
EOF
chmod +x "$bin/gh" "$bin/sleep"

run() { printf '{"id":%s,"event":"%s","status":"%s","created_at":"%s","display_title":"%s"}' "$1" "$2" "$3" "$4" "${5:-Stock check}"; }
runs() { local IFS=,; printf '{"workflow_runs":[%s]}' "$*"; }
# A run's check job: its start, and its last step (name, status, started_at).
jobs() { printf '{"jobs":[{"name":"check","started_at":"%s","steps":[{"name":"Set up job","status":"completed","started_at":"%s","completed_at":"%s"},{"name":"%s","status":"%s","started_at":"%s","completed_at":null}]}]}' "$1" "$1" "$1" "$2" "$3" "$4"; }

new_case() {
  export FAKE="$work/case"; rm -rf "$FAKE"; mkdir -p "$FAKE"; echo 0 > "$FAKE/step"
  printf '{"created_at":"%s"}' "$(t 2)" > "$FAKE/me.json"; runs > "$FAKE/runs.json"; echo '{"jobs":[]}' > "$FAKE/nojobs.json"
}
pass=0; fail=0
check() { # name, event, command, expected
  export GITHUB_RUN_ID=1000 GITHUB_REPOSITORY=o/r GITHUB_EVENT_NAME=$2 GITHUB_OUTPUT="$FAKE/out"
  : > "$FAKE/out"
  local got; got=$(PATH="$bin:$PATH" bash "$script" "$3" 2>"$FAKE/err" | tail -1)
  if [ "$3" = "wait" ]; then got=$(sed -n 's/^go=//p' "$FAKE/out"); fi
  if [ "$got" = "$4" ]; then pass=$((pass + 1)); echo "ok   $1 -> $got"
  else fail=$((fail + 1)); echo "FAIL $1: wanted '$4', got '$got'"; sed 's/^/     /' "$FAKE/err"; fi
}
expect_cancel() { if grep -qx "$1" "$FAKE/cancelled" 2>/dev/null; then pass=$((pass + 1)); echo "ok   ...run $1 cancelled"; else fail=$((fail + 1)); echo "FAIL run $1 not cancelled"; fi; }
expect_no_cancel() { if [ ! -s "$FAKE/cancelled" ]; then pass=$((pass + 1)); echo "ok   ...nothing cancelled"; else fail=$((fail + 1)); echo "FAIL cancelled: $(cat "$FAKE/cancelled")"; fi; }

echo "== wait"
new_case; runs "$(run 990 workflow_dispatch in_progress "$(t 6)")" > "$FAKE/runs.0.json"; cp "$FAKE/runs.0.json" "$FAKE/runs.1.json"
runs "$(run 990 workflow_dispatch completed "$(t 6)")" > "$FAKE/runs.2.json"; jobs "$(t 5)" "Round 3" in_progress "$(t 1)" > "$FAKE/jobs.990.json"
check "fresh check waits for the older one, then goes" workflow_dispatch wait true
new_case; runs "$(run 1010 workflow_dispatch in_progress "$(t 1)")" > "$FAKE/runs.json"
check "fresh check stops for a newer fresh one" workflow_dispatch wait false
new_case; runs "$(run 1010 schedule in_progress "$(t 1)")" > "$FAKE/runs.json"
check "fresh check ignores a newer scheduled start" workflow_dispatch wait true
new_case; runs "$(run 1010 workflow_dispatch in_progress "$(t 1)" 'Test alerts')" > "$FAKE/runs.json"
check "test-alert runs don't count" workflow_dispatch wait true
new_case; runs "$(run 990 workflow_dispatch in_progress "$(t 30)")" > "$FAKE/runs.json"; jobs "$(t 29)" "Round 5" in_progress "$(t 20)" > "$FAKE/jobs.990.json"
check "older run idle for 20 minutes is hung" workflow_dispatch wait true; expect_cancel 990
new_case; runs "$(run 990 workflow_dispatch in_progress "$(t 45)")" > "$FAKE/runs.0.json"; runs "$(run 990 workflow_dispatch completed "$(t 45)")" > "$FAKE/runs.1.json"
jobs "$(t 30)" "Round 14" in_progress "$(t 1)" > "$FAKE/jobs.990.json"
check "older run created 45 min ago but busy is waited for" workflow_dispatch wait true; expect_no_cancel
new_case; runs "$(run 990 workflow_dispatch queued "$(t 5)")" > "$FAKE/runs.json"
check "scheduled start yields to a queued fresh check (finding 1)" schedule wait false
new_case; runs "$(run 990 workflow_dispatch in_progress "$(t 5)")" > "$FAKE/runs.json"; jobs "$(t 4)" "Round 2" in_progress "$(t 1)" > "$FAKE/jobs.990.json"
check "scheduled start stops while the chain runs" schedule wait false
new_case; runs "$(run 990 workflow_dispatch queued "$(t 50)")" > "$FAKE/runs.json"
check "scheduled start ignores a check stuck in the queue" schedule wait true
new_case
check "scheduled start restarts an idle chain" schedule wait true
new_case; printf '{"created_at":"%s"}' "$(t 40)" > "$FAKE/me.json"; runs "$(run 1010 schedule in_progress "$(t 3)")" > "$FAKE/runs.json"
check "check that waited 40 min for a machine yields to a running one" workflow_dispatch wait false
new_case; runs "$(run 990 schedule in_progress "$(t 3)")" > "$FAKE/runs.json"; jobs "$(t 2)" "Wait for the previous check" in_progress "$(t 2)" > "$FAKE/jobs.990.json"
runs > "$FAKE/runs.1.json"
check "fresh check waits for an older scheduled one to decide" workflow_dispatch wait true
new_case
check "empty run list -> go" workflow_dispatch wait true

echo "== ready"
new_case; runs "$(run 1010 workflow_dispatch in_progress "$(t 1)")" > "$FAKE/runs.json"; jobs "$(t 1)" "Wait for the previous check" in_progress "$(t 1)" > "$FAKE/jobs.1010.json"
check "newer fresh check is waiting -> hand over" workflow_dispatch ready 1
new_case; runs "$(run 1010 workflow_dispatch in_progress "$(t 1)")" > "$FAKE/runs.json"; jobs "$(t 1)" "Run actions/checkout@v4" in_progress "$(t 1)" > "$FAKE/jobs.1010.json"
check "newer check still checking out -> not yet (finding 3)" workflow_dispatch ready 0
new_case; runs "$(run 1010 schedule in_progress "$(t 1)")" > "$FAKE/runs.json"; jobs "$(t 1)" "Wait for the previous check" in_progress "$(t 1)" > "$FAKE/jobs.1010.json"
check "newer scheduled start never takes over" workflow_dispatch ready 0
new_case; runs "$(run 1010 workflow_dispatch in_progress "$(t 40)")" > "$FAKE/runs.json"; jobs "$(t 1)" "Wait for the previous check" in_progress "$(t 1)" > "$FAKE/jobs.1010.json"
check "newer check that waited 40 min (a restarter) doesn't count" workflow_dispatch ready 0
new_case; touch "$FAKE/fail"
check "GitHub error -> 0 (keep checking)" workflow_dispatch ready 0

echo "== pending"
new_case; runs "$(run 1010 workflow_dispatch queued "$(t 2)")" > "$FAKE/runs.json"
check "newer fresh check queued" workflow_dispatch pending 1
new_case; runs "$(run 1010 workflow_dispatch queued "$(t 45)")" > "$FAKE/runs.json"
check "check stuck in the queue doesn't count" workflow_dispatch pending 0
new_case; runs "$(run 1010 schedule queued "$(t 1)")" > "$FAKE/runs.json"
check "scheduled start doesn't count" workflow_dispatch pending 0
new_case; touch "$FAKE/fail"
check "GitHub error -> err" workflow_dispatch pending err

echo "== next"
new_case; runs "$(run 1010 workflow_dispatch in_progress "$(t 20)")" > "$FAKE/runs.json"
check "newer check running" workflow_dispatch next 1
new_case; runs "$(run 1010 workflow_dispatch queued "$(t 5)")" > "$FAKE/runs.json"
check "newer check queued 5 minutes ago" workflow_dispatch next 1
new_case; runs "$(run 1010 workflow_dispatch queued "$(t 20)")" > "$FAKE/runs.json"
check "newer check queued 20 minutes ago doesn't count" workflow_dispatch next 0
new_case; runs "$(run 1010 schedule in_progress "$(t 1)")" > "$FAKE/runs.json"
check "scheduled start doesn't count" workflow_dispatch next 0
new_case; echo '{"workflow_runs":[{"id":"x y","event":"a","status":"b","created_at":"c","display_title":"Stock check"}]}' > "$FAKE/runs.json"
check "odd answer -> err" workflow_dispatch next err

echo "passed $pass, failed $fail"
rm -rf "$work"
[ "$fail" = "0" ]
