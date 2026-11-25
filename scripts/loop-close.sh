#!/usr/bin/env bash
# Close one approved ticket for /ticket:auto (*Close*), in one call.
#
# Usage:
#   scripts/loop-close.sh <N> <branch>
#   scripts/loop-close.sh --self-test
#
# Expects .build/tickets/HE-<N>-agent-review.md. Steps, each checked: post the
# section, land the branch on main by fast-forward (scripts/land.sh, which
# pushes main), move the ticket to in-review, then either close it as shipped
# and delete the branch, or, when .build/tickets/HE-<N>-awaiting.md exists
# (reference images without an approval record, device ids nobody has measured),
# post that as `Awaiting owner` and leave the ticket in review. Run again on a
# ticket already in review and it resumes after the landing.
#
# Exit codes:
#   0   shipped
#   10  landed, in review, waiting for the owner (proof rule 1, or device ids)
#   3   another worktree has main checked out: free it there, then run again
#   4   the branch does not contain main: rebase per auto.md, then run again
#   8   main and origin/main have diverged: log `halt main-diverged`, wrap up
#   9   origin unreachable: log `halt origin-unreachable`, wrap up
#   1   a scripts/tickets or git step failed; its output is above
set -euo pipefail

main() {
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TICKETS="${LOOP_TICKETS:-$repo_root/scripts/tickets}"
LAND="${LOOP_LAND:-$repo_root/scripts/land.sh}"
if [[ "${1:-}" == "--self-test" ]]; then self_test; return; fi
[[ $# -eq 2 ]] || { sed -n '2,23p' "$0" >&2; exit 64; }
n="$1"; branch="$2"
cd "${LOOP_ROOT:-$repo_root}"
log=".build/auto-loop/run.log"
review=".build/tickets/HE-$n-agent-review.md"
awaiting=".build/tickets/HE-$n-awaiting.md"
mkdir -p .build/auto-loop
say() { echo "$(date -u +%FT%TZ) HE-$n $*" >> "$log"; }
[[ -f "$review" ]] || { echo "loop-close: missing $review" >&2; exit 1; }

state="$("$TICKETS" show "$n" | sed -n '2p')"
if [[ "$state" != *"in-review"* ]]; then
  "$TICKETS" section "$n" --heading "Agent review" --file "$review" --event "agent review"
  set +e
  "$LAND" "$branch"
  landed=$?
  set -e
  case "$landed" in
    0) ;;
    3|4|8|9) echo "loop-close: land.sh exit $landed; nothing landed" >&2; exit "$landed" ;;
    *) echo "loop-close: landing $branch failed" >&2; exit 1 ;;
  esac
  "$TICKETS" move "$n" in-review
fi

if git show-ref --verify --quiet "refs/heads/$branch" && git merge-base --is-ancestor "$branch" main; then
  git branch -q -D "$branch"
fi
if [[ -f "$awaiting" ]]; then
  "$TICKETS" section "$n" --heading "Awaiting owner" --file "$awaiting" --event "awaiting owner"
  say "landed-unapproved $(git rev-parse --short main)"
  echo "loop-close: HE-$n landed, in review, awaiting the owner"
  exit 10
fi
"$TICKETS" close "$n" --as shipped
say "shipped $(git rev-parse --short main)"
echo "loop-close: HE-$n shipped"
}

self_test() {
  local tmp pass=0 rc self
  self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  tmp="$(mktemp -d)"
  git init -q -b main "$tmp/repo"
  g() { git -C "$tmp/repo" -c user.email=t@t -c user.name=t "$@"; }
  g commit -q --allow-empty -m base
  g switch -q -c feat/HE-7-a && g commit -q --allow-empty -m a1 && g switch -q main
  mkdir -p "$tmp/repo/.build/tickets"
  # stub tickets: records calls, reports the stage from a file
  cat > "$tmp/tickets" <<'T'
#!/usr/bin/env bash
echo "$*" >> "$STUB_DIR/calls"
case "$1" in
  show) echo "#$2 t"; echo "stage $(cat "$STUB_DIR/stage" 2>/dev/null || echo in-progress) · x" ;;
  move) echo "$3" > "$STUB_DIR/stage" ;;
  close) [[ -z "${STUB_CLOSE_FAILS:-}" ]] || exit 2 ;;
esac
T
  chmod +x "$tmp/tickets"
  run() { (cd "$tmp/repo" && STUB_DIR="$tmp" LOOP_ROOT="$tmp/repo" LOOP_TICKETS="$tmp/tickets" LAND_NO_PUSH=1 bash "$self" "$@") >/dev/null 2>&1; }

  run 7 feat/HE-7-a && rc=0 || rc=$?
  [[ $rc == 1 ]] && pass=$((pass+1)) || echo "FAIL missing review"

  echo "Round 1: APPROVE" > "$tmp/repo/.build/tickets/HE-7-agent-review.md"
  echo "refs" > "$tmp/repo/.build/tickets/HE-7-awaiting.md"
  local tip; tip="$(g rev-parse feat/HE-7-a)"
  run 7 feat/HE-7-a && rc=0 || rc=$?
  [[ $rc == 10 && "$(g rev-parse main)" == "$tip" && "$(cat "$tmp/stage")" == in-review ]] \
    && grep -q "Awaiting owner" "$tmp/calls" && ! grep -q "^close" "$tmp/calls" \
    && grep -q "HE-7 landed-unapproved" "$tmp/repo/.build/auto-loop/run.log" \
    && ! g show-ref --verify --quiet refs/heads/feat/HE-7-a \
    && pass=$((pass+1)) || echo "FAIL awaiting"

  rm "$tmp/repo/.build/tickets/HE-7-awaiting.md"; : > "$tmp/calls"
  run 7 feat/HE-7-a && rc=0 || rc=$?
  [[ $rc == 0 ]] && grep -q "^close 7 --as shipped" "$tmp/calls" && ! grep -q "Agent review" "$tmp/calls" \
    && grep -q "HE-7 shipped" "$tmp/repo/.build/auto-loop/run.log" \
    && pass=$((pass+1)) || echo "FAIL resume and ship"

  rm -f "$tmp/stage"; : > "$tmp/calls"
  g switch -q -c feat/HE-8-b "$(g rev-list --max-parents=0 main)" && g commit -q --allow-empty -m b1 && g switch -q main
  echo "Round 1: APPROVE" > "$tmp/repo/.build/tickets/HE-8-agent-review.md"
  run 8 feat/HE-8-b && rc=0 || rc=$?
  [[ $rc == 4 ]] && ! grep -q "^move" "$tmp/calls" && pass=$((pass+1)) || echo "FAIL main moved"

  g rebase -q main feat/HE-8-b && g switch -q main
  (cd "$tmp/repo" && STUB_CLOSE_FAILS=1 STUB_DIR="$tmp" LOOP_ROOT="$tmp/repo" LOOP_TICKETS="$tmp/tickets" LAND_NO_PUSH=1 bash "$self" 8 feat/HE-8-b) >/dev/null 2>&1 && rc=0 || rc=$?
  [[ $rc != 0 && $rc != 10 && "$(cat "$tmp/stage")" == in-review ]] && pass=$((pass+1)) || echo "FAIL close failure"

  rm -rf "$tmp"
  echo "loop-close self-test: $pass/5 passed"
  [[ $pass == 5 ]]
}

main "$@"
