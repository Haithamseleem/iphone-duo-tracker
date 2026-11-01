#!/usr/bin/env bash
# The Stock check chain's view of GitHub's run list, shared by check.yml and .github/actions/round so every step reads it
# the same way. Each other "Stock check" run is one line, "id event status created_at", and all counting is done here.
# A GitHub answer that isn't in that form is an error ("err"), never a count.
#
#   runs.sh wait     the "Wait for the previous check" loop; writes go=true/false to $GITHUB_OUTPUT
#   runs.sh ready    1 if a newer check has its machine and is waiting for this one (hand over now), else 0
#   runs.sh pending  how many newer checks are queued or running (started in the last 30 minutes), or err
#   runs.sh next     how many newer checks are running or were started in the last 10 minutes, or err
#
# Roles: a "fresh" check is one started by the chain or Run check now (not the schedule) in the last 30 minutes. A
# "restarter" is a scheduled start, or a check that waited over 30 minutes for a machine: it takes over only when no
# other check is running or on its way, so it can never run alongside the chain (28 Oct 21:57: a running check handed
# over to a scheduled start, which then stopped too). A check is hung when nothing happened in its job for 12 minutes
# (a working one starts a step at least every few minutes).
set -eo pipefail
me=$GITHUB_RUN_ID
repo=$GITHUB_REPOSITORY

ago() { date -u -d "-$1 min" +%Y-%m-%dT%H:%M:%SZ; }

# The other Stock check runs, one per line; returns 1 on a failed request or an odd answer.
list() {
  local out id ev st at
  out=$(gh api "repos/$repo/actions/workflows/check.yml/runs?per_page=30" \
    --jq ".workflow_runs[] | select(.display_title == \"Stock check\" and .id != $me) | [.id, .event, .status, .created_at] | map(tostring) | join(\" \")") || return 1
  while read -r id ev st at; do
    if [ -z "$id" ]; then continue; fi
    case "$id" in *[!0-9]*) echo "Unexpected answer from GitHub: $out" >&2; return 1 ;; esac
    echo "$id $ev $st $at"
  done <<< "$out"
}

# Latest time anything happened in a run's check job (job start, or any step starting or ending).
last_activity() {
  gh api "repos/$repo/actions/runs/$1/jobs" \
    --jq '[.jobs[] | select(.name == "check") | .started_at, (.steps[]? | .started_at, .completed_at) | select(. != null)] | max // ""'
}

# 1 if the run has checked out and is in its "Wait for the previous check" step, else 0.
waiting() {
  local n
  n=$(gh api "repos/$repo/actions/runs/$1/jobs" \
    --jq '[.jobs[] | select(.name == "check") | .steps[]? | select(.name == "Wait for the previous check" and .status == "in_progress")] | length') || n=0
  case "$n" in ''|*[!0-9]*|0) echo 0 ;; *) echo 1 ;; esac
}

fresh_run() { [ "$1" != "schedule" ] && [[ "$2" > "$(ago 30)" ]]; }

ready() {
  local lines id ev st at
  lines=$(list) || { echo 0; return; }
  while read -r id ev st at; do
    if [ -z "$id" ]; then continue; fi
    if [ "$id" -gt "$me" ] && [ "$st" = "in_progress" ] && fresh_run "$ev" "$at" && [ "$(waiting "$id")" = "1" ]; then echo 1; return; fi
  done <<< "$lines"
  echo 0
}

pending() {
  local lines id ev st at n=0
  lines=$(list) || { echo err; return; }
  while read -r id ev st at; do
    if [ -z "$id" ]; then continue; fi
    if [ "$id" -gt "$me" ] && [ "$st" != "completed" ] && fresh_run "$ev" "$at"; then n=$((n + 1)); fi
  done <<< "$lines"
  echo "$n"
}

next() {
  local lines id ev st at n=0 recent
  recent=$(ago 10)
  lines=$(list) || { echo err; return; }
  while read -r id ev st at; do
    if [ -z "$id" ]; then continue; fi
    if [ "$id" -gt "$me" ] && [ "$ev" != "schedule" ]; then
      if [ "$st" = "in_progress" ] || { [ "$st" != "completed" ] && [[ "$at" > "$recent" ]]; }; then n=$((n + 1)); fi
    fi
  done <<< "$lines"
  echo "$n"
}

go() { echo "go=$1" >> "$GITHUB_OUTPUT"; exit 0; }

wait_turn() {
  local mine restarter=0 i lines id ev st at hung last newer older others stale
  mine=$(gh api "repos/$repo/actions/runs/$me" --jq .created_at) || mine=''
  if [ "$GITHUB_EVENT_NAME" = "schedule" ] || { [ -n "$mine" ] && [[ ! "$mine" > "$(ago 30)" ]]; }; then restarter=1; fi
  for i in $(seq 1 150); do
    hung=$(ago 12)
    lines=$(list) || { sleep 10; continue; }
    newer=0; older=0; others=0; stale=''
    while read -r id ev st at; do
      if [ -z "$id" ]; then continue; fi
      if [ "$st" = "in_progress" ]; then
        if [ "$id" -gt "$me" ]; then
          if fresh_run "$ev" "$at"; then newer=$((newer + 1)); fi
          others=$((others + 1))
        else
          last=$(last_activity "$id") || last=''
          if [ -n "$last" ] && [[ "$last" < "$hung" ]]; then stale="$stale $id"
          else older=$((older + 1)); others=$((others + 1)); fi
        fi
      elif [ "$st" != "completed" ] && fresh_run "$ev" "$at"; then
        others=$((others + 1))
      fi
    done <<< "$lines"
    if [ "$i" = "1" ]; then echo "Other checks: newer $newer, older running $older, running or on its way $others, hung:${stale:- none}, restarter $restarter"; fi
    for id in $stale; do
      echo "Run $id has done nothing for 12 minutes: cancelling it."
      gh run cancel "$id" -R "$repo" || gh api -X POST "repos/$repo/actions/runs/$id/force-cancel" > /dev/null || true
    done
    if [ "$restarter" = "1" ]; then
      if [ "$others" != "0" ]; then echo "Another check is running or on its way, so the chain is alive."; go false; fi
      go true
    fi
    if [ "$newer" != "0" ]; then echo "A newer check is already running; it carries on."; go false; fi
    if [ "$older" = "0" ]; then go true; fi
    sleep 10
  done
  echo "The previous check is still running after about 25 minutes; this one stops."
  go false
}

case "${1:-}" in
  wait) wait_turn ;;
  ready) ready ;;
  pending) pending ;;
  next) next ;;
  *) echo "usage: runs.sh wait|ready|pending|next" >&2; exit 2 ;;
esac
