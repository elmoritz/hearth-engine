#!/usr/bin/env bash
# Land one approved branch on main by fast-forward, without checking main out,
# and publish it on origin/main. Ported from IdleVillage's scripts/land.sh
# (there: IV-522), without its code/art tracks: this repo has one track.
#
# Usage:
#   scripts/land.sh <branch>
#   scripts/land.sh HEAD        a commit made on the detached home (a retro change,
#                               a perf baseline, a milestone report)
#   scripts/land.sh --sync      only bring main up to origin/main (the loop's preflight)
#   scripts/land.sh --self-test
#
# Nobody keeps main checked out: the loop and the owner work on ticket branches
# or a detached HEAD at main. `git fetch . <branch>:main` moves main only as a
# fast-forward, and the ref update is atomic. The checkout this runs in follows
# main when it was on <branch> or detached at main's old tip: it ends detached
# at the new main, so the branch can be deleted.
#
# Origin. With a remote `origin` (and LAND_NO_PUSH unset), landing starts with
# `git fetch origin main`, retrying a failure 4 times after 2, 4, 8 and 16 s
# (LAND_BACKOFF), and fast-forwards main to origin/main. Main with commits
# origin/main lacks is refused (exit 8): only this script moves main, and it
# always pushes. After the local fast-forward it runs `git push origin
# main:main` (plain, never forced). When origin rejects it because someone
# landed first, main goes back to the origin tip and the exit is 4. A push that
# still fails after the retries puts main back and exits 9. LAND_NO_PUSH=1, or
# a repo without origin, keeps landing purely local.
#
# Exit codes:
#   0  landed (and pushed); prints `land: <branch> -> main <sha>`
#      (--sync: main equals origin/main, or there is no origin to sync with)
#   3  a worktree has main checked out (named on stderr); detach it there
#      (`git switch --detach main`), then run this again
#   4  <branch> does not contain main (main moved, here or on origin): rebase
#      it onto main, re-run the gate, then run this again
#   8  main has commits origin/main lacks; nothing moved; the owner pushes or
#      resets main, then run this again
#   9  origin unreachable: fetch or push still failing after the retries; main
#      is where origin/main was, nothing published
#   1  <branch> does not exist, or git refused the update
set -euo pipefail

read -r -a BACKOFF <<< "${LAND_BACKOFF:-2 4 8 16}"

usage() { sed -n '2,40p' "$0" >&2; exit 64; }

use_origin() { [[ "${LAND_NO_PUSH:-}" != 1 ]] && git remote get-url origin >/dev/null 2>&1; }

check_holder() {
  local holder
  holder="$(git worktree list --porcelain | awk '/^worktree /{w=substr($0,10)} $0=="branch refs/heads/main"{print w}')"
  if [[ -n "$holder" ]]; then
    echo "land: main is checked out at $holder; detach it there (git switch --detach main), then land again" >&2
    exit 3
  fi
}

fetch_once() { git fetch -q origin "+refs/heads/main:refs/remotes/origin/main"; }

# fetch_origin: fetch origin/main, retrying with the backoff; 1 when it still fails.
fetch_origin() {
  local delay
  for delay in "${BACKOFF[@]}" ""; do
    fetch_once && return 0
    [[ -n "$delay" ]] || break
    echo "land: fetching origin failed; retrying in ${delay}s" >&2
    sleep "$delay"
  done
  return 1
}

# follow_home <old>: a checkout detached at main's old tip follows main.
follow_home() {
  if [[ -z "$(git branch --show-current)" && "$(git rev-parse HEAD)" == "$1" ]]; then
    git switch -q --detach main 2>/dev/null \
      || echo "land: main moved, but this checkout stays at $(git rev-parse --short HEAD) (local changes); git switch --detach main when clean" >&2
  fi
}

# sync_main: fetch origin/main and fast-forward main to it; exits 8 or 9.
sync_main() {
  local om old
  if ! fetch_origin; then
    echo "land: origin unreachable; main stays at $(git rev-parse --short main), nothing landed" >&2
    exit 9
  fi
  om="$(git rev-parse refs/remotes/origin/main)"
  old="$(git rev-parse main)"
  [[ "$om" == "$old" ]] && return 0
  if git merge-base --is-ancestor "$old" "$om"; then
    git fetch -q . "refs/remotes/origin/main:refs/heads/main" \
      || { echo "land: git refused to fast-forward main to origin/main" >&2; exit 1; }
    follow_home "$old"
    echo "land: main fast-forwarded to origin/main $(git rev-parse --short main)" >&2
    return 0
  fi
  echo "land: main has $(git rev-list --count "$om..$old") commit(s) origin/main lacks ($(git log --format=%h "$om..$old" | tr '\n' ' ')); nothing lands until they are on origin: push them (git push origin main:main) or reset main to origin/main by hand, then run this again" >&2
  exit 8
}

# undo_land <before> <after>: put main back on the origin tip it left.
undo_land() {
  if ! git update-ref refs/heads/main "$1" "$2" 2>/dev/null; then
    echo "land: main moved on here before the push and stays ahead of origin/main; push it (git push origin main:main) by hand, then run this again" >&2
    exit 8
  fi
}

# push_main <before> <after>: publish main; on rejection or lasting failure
# undo the land and exit 4 or 9.
push_main() {
  local delay
  for delay in "${BACKOFF[@]}" ""; do
    git push -q origin "refs/heads/main:refs/heads/main" && return 0
    if fetch_once; then
      # Already there (the other loop on this Mac pushed main with it): done.
      git merge-base --is-ancestor main refs/remotes/origin/main && return 0
      if ! git merge-base --is-ancestor refs/remotes/origin/main main; then
        undo_land "$1" "$2"
        sync_main
        echo "land: origin/main moved (someone else landed first); main is back at origin/main $(git rev-parse --short main), nothing pushed; rebase onto main, re-run its checks, then land again" >&2
        exit 4
      fi
    fi
    [[ -n "$delay" ]] || break
    echo "land: pushing main to origin failed; retrying in ${delay}s" >&2
    sleep "$delay"
  done
  undo_land "$1" "$2"
  echo "land: could not push main to origin; main is back at $(git rev-parse --short main), nothing landed" >&2
  exit 9
}

sync_only() {
  check_holder
  if ! use_origin; then
    echo "land: no origin to sync with (or LAND_NO_PUSH=1); main stays at $(git rev-parse --short main)"
    return 0
  fi
  sync_main
  echo "land: main = origin/main $(git rev-parse --short main)"
}

main() {
  case "${1:-}" in
    --self-test) self_test; return ;;
    --sync) [[ $# -eq 1 ]] || usage; sync_only; return ;;
  esac
  [[ $# -eq 1 ]] || usage
  local branch="$1" tip old head src follow=0 push=0 rc
  if [[ "$branch" == HEAD ]]; then src=HEAD; else src="refs/heads/$branch"; fi
  git rev-parse -q --verify "$src^{commit}" >/dev/null \
    || { echo "land: no branch '$branch'" >&2; exit 1; }

  check_holder
  if use_origin; then push=1; sync_main; fi
  if ! git merge-base --is-ancestor main "$src"; then
    echo "land: $branch does not contain main; rebase it onto main, re-run its checks, then land again" >&2
    exit 4
  fi

  old="$(git rev-parse main)"
  head="$(git rev-parse HEAD)"
  if [[ "$(git branch --show-current)" == "$branch" ]] \
     || { [[ -z "$(git branch --show-current)" ]] && [[ "$head" == "$old" ]]; }; then
    follow=1
  fi
  if ! git fetch -q . "$src:refs/heads/main"; then
    # The other loop landed between the check and the update: same as main moved.
    if ! git merge-base --is-ancestor main "$src"; then
      echo "land: main moved while landing $branch; rebase it onto main, re-run its checks, then land again" >&2
      exit 4
    fi
    echo "land: git refused to fast-forward main to $branch" >&2
    exit 1
  fi
  if (( push )); then
    push_main "$old" "$(git rev-parse main)"
    echo "land: pushed main to origin" >&2
  fi
  tip="$(git rev-parse --short main)"
  if (( follow )); then
    # main has moved already, so a checkout that can't follow (local edits in
    # files the land changed) is reported, not treated as a failed land.
    git switch -q --detach main 2>/dev/null \
      || echo "land: landed, but this checkout stays at $(git rev-parse --short HEAD) (local changes); git switch --detach main when clean" >&2
  fi
  echo "land: $branch -> main $tip"
}

self_test() {
  local tmp repo pass=0 rc self
  self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  tmp="$(mktemp -d)"
  repo="$tmp/repo"
  g() { git -C "$repo" -c user.email=t@t -c user.name=t "$@"; }
  git init -q -b main "$repo"
  g commit -q --allow-empty -m base
  g switch -q -c feat/HE-1-a && g commit -q --allow-empty -m a1
  run() { (cd "$repo" && bash "$self" "$@") >/dev/null 2>&1; }

  # main checked out (here): refused, main unchanged
  g switch -q main
  run feat/HE-1-a && rc=0 || rc=$?
  [[ $rc == 3 && "$(g rev-parse main)" != "$(g rev-parse feat/HE-1-a)" ]] && pass=$((pass+1)) || echo "FAIL held"

  # main checked out in another worktree: refused too
  g switch -q --detach main
  g worktree add -q "$tmp/other" main
  run feat/HE-1-a && rc=0 || rc=$?
  [[ $rc == 3 ]] && pass=$((pass+1)) || echo "FAIL held elsewhere"
  g worktree remove "$tmp/other"

  # on the branch, nobody holds main: lands, leaves the checkout detached at main
  g switch -q feat/HE-1-a
  run feat/HE-1-a && rc=0 || rc=$?
  [[ $rc == 0 && "$(g rev-parse main)" == "$(g rev-parse feat/HE-1-a)" \
     && -z "$(g branch --show-current)" && "$(g rev-parse HEAD)" == "$(g rev-parse main)" ]] \
    && pass=$((pass+1)) || echo "FAIL land"

  # main moved past the branch's base: exit 4, main unchanged
  g switch -q -c feat/HE-2-b "$(g rev-list --max-parents=0 main)"
  g commit -q --allow-empty -m b1
  local before; before="$(g rev-parse main)"
  run feat/HE-2-b && rc=0 || rc=$?
  [[ $rc == 4 && "$(g rev-parse main)" == "$before" ]] && pass=$((pass+1)) || echo "FAIL moved"

  # detached at main (a loop's home): lands, and HEAD follows main
  g rebase -q main feat/HE-2-b
  g switch -q --detach main
  run feat/HE-2-b && rc=0 || rc=$?
  [[ $rc == 0 && "$(g rev-parse main)" == "$(g rev-parse feat/HE-2-b)" && "$(g rev-parse HEAD)" == "$(g rev-parse main)" ]] \
    && pass=$((pass+1)) || echo "FAIL detached home"

  # detached anywhere else: lands, HEAD stays put
  g switch -q -c feat/HE-3-c main && g commit -q --allow-empty -m c1
  g switch -q --detach main~1
  local head; head="$(g rev-parse HEAD)"
  run feat/HE-3-c && rc=0 || rc=$?
  [[ $rc == 0 && "$(g rev-parse main)" == "$(g rev-parse feat/HE-3-c)" && "$(g rev-parse HEAD)" == "$head" ]] \
    && pass=$((pass+1)) || echo "FAIL detached elsewhere"

  # a commit on the detached home lands with HEAD
  g switch -q --detach main && g commit -q --allow-empty -m rebaseline
  run HEAD && rc=0 || rc=$?
  [[ $rc == 0 && "$(g rev-parse main)" == "$(g rev-parse HEAD)" && -z "$(g branch --show-current)" ]] \
    && pass=$((pass+1)) || echo "FAIL head"

  # lost race: the other loop lands between the check and the update -> exit 4, main is theirs
  g switch -q -c feat/HE-4-d main && g commit -q --allow-empty -m d1
  g switch -q --detach main
  local rival; rival="$(g commit-tree -p main -m rival "$(g rev-parse 'main^{tree}')")"
  mkdir -p "$tmp/bin"
  local realgit; realgit="$(command -v git)"
  printf '#!/usr/bin/env bash\nif [[ "$1" == fetch ]]; then "%s" update-ref refs/heads/main %s; fi\nexec "%s" "$@"\n' \
    "$realgit" "$rival" "$realgit" > "$tmp/bin/git"
  chmod +x "$tmp/bin/git"
  (cd "$repo" && PATH="$tmp/bin:$PATH" bash "$self" feat/HE-4-d) >/dev/null 2>&1 && rc=0 || rc=$?
  [[ $rc == 4 && "$(g rev-parse main)" == "$rival" ]] && pass=$((pass+1)) || echo "FAIL race"

  # dirty home that can't follow: still exit 0, main moved, HEAD stays
  g switch -q --detach main
  printf a > "$repo/f" && g add f && g commit -q -m f1
  g branch -q -f main HEAD
  g switch -q -c feat/HE-5-e && printf b > "$repo/f" && g commit -q -am f2
  g switch -q --detach main
  local home; home="$(g rev-parse HEAD)"
  printf dirty > "$repo/f"
  run feat/HE-5-e && rc=0 || rc=$?
  [[ $rc == 0 && "$(g rev-parse main)" == "$(g rev-parse feat/HE-5-e)" && "$(g rev-parse HEAD)" == "$home" ]] \
    && pass=$((pass+1)) || echo "FAIL dirty home"
  g checkout -q -- f

  # no such branch: exit 1
  run feat/HE-9-none && rc=0 || rc=$?
  [[ $rc == 1 ]] && pass=$((pass+1)) || echo "FAIL missing"

  # --sync without origin: nothing to do, exit 0
  run --sync && rc=0 || rc=$?
  [[ $rc == 0 ]] && pass=$((pass+1)) || echo "FAIL sync local"

  # Two Macs: a bare origin and clones a and b, each detached at main.
  local origin="$tmp/origin.git" a="$tmp/a" b="$tmp/b"
  git init -q --bare -b main "$origin"
  git clone -q "$repo" "$a" 2>/dev/null
  git -C "$a" remote set-url origin "$origin"
  ga() { git -C "$a" -c user.email=t@t -c user.name=t "$@"; }
  gb() { git -C "$b" -c user.email=t@t -c user.name=t "$@"; }
  gor() { git -C "$origin" "$@"; }
  ga push -q origin "$(g rev-parse main):refs/heads/main"
  ga fetch -q origin && ga switch -q --detach origin/main && ga branch -q -f main origin/main
  git clone -q "$origin" "$b" 2>/dev/null && gb switch -q --detach main
  runin() { local d="$1"; shift; (cd "$d" && LAND_BACKOFF="0 0 0 0" bash "$self" "$@") >/dev/null 2>&1; }

  # a lands a branch: main moves here and on origin, the checkout follows
  ga switch -q -c feat/HE-20-p main && ga commit -q --allow-empty -m p1
  runin "$a" feat/HE-20-p && rc=0 || rc=$?
  [[ $rc == 0 && "$(gor rev-parse main)" == "$(ga rev-parse feat/HE-20-p)" \
     && "$(ga rev-parse main)" == "$(ga rev-parse feat/HE-20-p)" && "$(ga rev-parse HEAD)" == "$(ga rev-parse main)" ]] \
    && pass=$((pass+1)) || echo "FAIL push lands"

  # b, behind origin, lands a branch from its old main: main fast-forwards to
  # origin/main (the home with it), the branch lacks it: exit 4, nothing pushed
  gb switch -q -c feat/HE-21-q main && gb commit -q --allow-empty -m q1
  local otip; otip="$(gor rev-parse main)"
  runin "$b" feat/HE-21-q && rc=0 || rc=$?
  [[ $rc == 4 && "$(gor rev-parse main)" == "$otip" && "$(gb rev-parse main)" == "$otip" ]] \
    && pass=$((pass+1)) || echo "FAIL origin moved before"

  # --sync: a's home behind origin follows main to origin/main
  gb rebase -q main feat/HE-21-q
  runin "$b" feat/HE-21-q && rc=0 || rc=$?
  [[ $rc == 0 && "$(gor rev-parse main)" == "$(gb rev-parse feat/HE-21-q)" ]] && pass=$((pass+1)) || echo "FAIL rebased lands"
  runin "$a" --sync && rc=0 || rc=$?
  [[ $rc == 0 && "$(ga rev-parse main)" == "$(gor rev-parse main)" && "$(ga rev-parse HEAD)" == "$(ga rev-parse main)" ]] \
    && pass=$((pass+1)) || echo "FAIL sync"

  # lost race on origin: the other Mac pushes between a's fetch and push ->
  # exit 4, origin keeps theirs, a's main is at their tip, a stays on its branch
  ga switch -q -c feat/HE-22-r main && ga commit -q --allow-empty -m r1
  local rival2
  rival2="$(GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
    gor commit-tree -p main -m rival "$(gor rev-parse 'main^{tree}')")"
  printf '#!/usr/bin/env bash\nif [[ "$1" == push && ! -e "%s/raced" ]]; then touch "%s/raced"; "%s" -C "%s" update-ref refs/heads/main %s; fi\nexec "%s" "$@"\n' \
    "$tmp" "$tmp" "$realgit" "$origin" "$rival2" "$realgit" > "$tmp/bin/git"
  (cd "$a" && PATH="$tmp/bin:$PATH" LAND_BACKOFF="0 0 0 0" bash "$self" feat/HE-22-r) >/dev/null 2>&1 && rc=0 || rc=$?
  [[ $rc == 4 && "$(gor rev-parse main)" == "$rival2" && "$(ga rev-parse main)" == "$rival2" \
     && "$(ga branch --show-current)" == feat/HE-22-r ]] && pass=$((pass+1)) || echo "FAIL push race"

  # main ahead of origin (a commit on main nobody pushed): refused, exit 8
  ga switch -q --detach main && ga commit -q --allow-empty -m byhand && ga branch -q -f main HEAD
  local byhand; byhand="$(ga rev-parse main)"
  ga rebase -q main feat/HE-22-r
  otip="$(gor rev-parse main)"
  runin "$a" feat/HE-22-r && rc=0 || rc=$?
  [[ $rc == 8 && "$(gor rev-parse main)" == "$otip" && "$(ga rev-parse main)" == "$byhand" ]] \
    && pass=$((pass+1)) || echo "FAIL ahead"
  ga branch -q -f main origin/main && ga rebase -q --onto main "$byhand" feat/HE-22-r
  ga switch -q --detach main

  # network: fetch fails twice, then works -> lands and pushes (3 fetches of origin)
  printf '#!/usr/bin/env bash\nif [[ "$1" == fetch && " $* " == *" origin "* ]]; then n=$(( $(cat "%s/n" 2>/dev/null || echo 0) + 1 )); echo $n > "%s/n"; if (( n <= ${STUB_FAILS:-0} )); then echo "fatal: unable to access origin" >&2; exit 128; fi; fi\nif [[ "$1" == push && -n "${STUB_PUSH_DOWN:-}" ]]; then echo "fatal: unable to access origin" >&2; exit 128; fi\nexec "%s" "$@"\n' \
    "$tmp" "$tmp" "$realgit" > "$tmp/bin/git"
  rm -f "$tmp/n"
  (cd "$a" && PATH="$tmp/bin:$PATH" STUB_FAILS=2 LAND_BACKOFF="0 0 0 0" bash "$self" feat/HE-22-r) >/dev/null 2>&1 && rc=0 || rc=$?
  [[ $rc == 0 && "$(cat "$tmp/n")" == 3 && "$(gor rev-parse main)" == "$(ga rev-parse feat/HE-22-r)" ]] \
    && pass=$((pass+1)) || echo "FAIL fetch retry"

  # network down: every fetch fails -> exit 9, main and origin unchanged
  ga switch -q -c feat/HE-23-s main && ga commit -q --allow-empty -m s1
  otip="$(gor rev-parse main)"; rm -f "$tmp/n"
  (cd "$a" && PATH="$tmp/bin:$PATH" STUB_FAILS=99 LAND_BACKOFF="0 0 0 0" bash "$self" feat/HE-23-s) >/dev/null 2>&1 && rc=0 || rc=$?
  [[ $rc == 9 && "$(cat "$tmp/n")" == 5 && "$(ga rev-parse main)" == "$otip" && "$(gor rev-parse main)" == "$otip" ]] \
    && pass=$((pass+1)) || echo "FAIL fetch down"

  # push keeps failing after the local fast-forward -> exit 9, main back at origin/main
  rm -f "$tmp/n"
  (cd "$a" && PATH="$tmp/bin:$PATH" STUB_PUSH_DOWN=1 LAND_BACKOFF="0 0 0 0" bash "$self" feat/HE-23-s) >/dev/null 2>&1 && rc=0 || rc=$?
  [[ $rc == 9 && "$(ga rev-parse main)" == "$otip" && "$(gor rev-parse main)" == "$otip" \
     && "$(ga branch --show-current)" == feat/HE-23-s ]] && pass=$((pass+1)) || echo "FAIL push down"

  # LAND_NO_PUSH=1: lands locally only
  (cd "$a" && LAND_NO_PUSH=1 bash "$self" feat/HE-23-s) >/dev/null 2>&1 && rc=0 || rc=$?
  [[ $rc == 0 && "$(ga rev-parse main)" == "$(ga rev-parse feat/HE-23-s)" && "$(gor rev-parse main)" == "$otip" ]] \
    && pass=$((pass+1)) || echo "FAIL no push"

  rm -rf "$tmp"
  echo "land self-test: $pass/21 passed"
  [[ $pass == 21 ]]
}

main "$@"
