#!/usr/bin/env bash
# Land one approved branch on main by fast-forward and publish it on origin/main.
#
# Usage:
#   scripts/land.sh <branch>
#   scripts/land.sh HEAD        push a commit made on main itself (a retro change,
#                               a perf baseline, a milestone report)
#   scripts/land.sh --sync      only bring main up to origin/main (the loop's preflight)
#   scripts/land.sh --self-test
#
# This repo has one track and one loop, so main is simply checked out in the
# checkout the loop runs in. To land, the script switches this checkout to main
# if it is on something else, fast-forwards main to origin/main, fast-forwards it to
# <branch> (`git merge --ff-only`, never a merge commit), and pushes
# (`git push origin main:main`, plain, never forced). The checkout ends on main.
#
# Origin. With a remote `origin` (and LAND_NO_PUSH unset) it fetches first,
# retrying a failure 4 times after 2, 4, 8 and 16 s (LAND_BACKOFF). Main may be
# ahead of origin/main (a commit made by hand): it is pushed along. When origin
# rejects the push because someone landed first, the landing is taken back, main
# follows origin/main, and the exit is 4. A push that still fails after the
# retries takes the landing back and exits 9. LAND_NO_PUSH=1, or a repo without
# origin, keeps landing purely local.
#
# Exit codes:
#   0  landed (and pushed); prints `land: <branch> -> main <sha>`
#      (--sync: main contains origin/main, or there is no origin to sync with)
#   3  another worktree has main checked out (named on stderr); run the loop
#      there, or put that worktree on another branch
#   4  <branch> does not contain main (main moved, here or on origin): rebase
#      it onto main, re-run the gate, then run this again
#   8  main and origin/main have diverged; nothing moved; the owner sorts it out
#   9  origin unreachable: fetch or push still failing after the retries;
#      nothing published (HEAD: the commit stays on main; run this again)
#   1  <branch> does not exist, this checkout cannot switch to main (local
#      changes in the way), or git refused the update
set -euo pipefail

read -r -a BACKOFF <<< "${LAND_BACKOFF:-2 4 8 16}"

usage() { sed -n '2,37p' "$0" >&2; exit 64; }

use_origin() { [[ "${LAND_NO_PUSH:-}" != 1 ]] && git remote get-url origin >/dev/null 2>&1; }

check_holder() {
  local here holder
  here="$(git rev-parse --show-toplevel)"
  holder="$(git worktree list --porcelain | awk '/^worktree /{w=substr($0,10)} $0=="branch refs/heads/main"{print w}')"
  if [[ -n "$holder" && "$(cd "$holder" && pwd -P)" != "$(cd "$here" && pwd -P)" ]]; then
    echo "land: main is checked out at $holder; run the loop there, or put that worktree on another branch" >&2
    exit 3
  fi
}

on_main() {
  [[ "$(git branch --show-current)" == main ]] && return 0
  git switch -q main 2>/dev/null \
    || { echo "land: cannot switch this checkout to main (local changes in the way?)" >&2; exit 1; }
}

fetch_once() { git fetch -q origin "+refs/heads/main:refs/remotes/origin/main"; }

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

# Bring main (checked out here) up to origin/main. Ahead is fine; diverged is 8.
sync_main() {
  local om cur
  if ! fetch_origin; then
    echo "land: origin unreachable; main stays at $(git rev-parse --short main), nothing landed" >&2
    exit 9
  fi
  om="$(git rev-parse refs/remotes/origin/main)"
  cur="$(git rev-parse main)"
  [[ "$om" == "$cur" ]] && return 0
  if git merge-base --is-ancestor "$cur" "$om"; then
    if [[ "$(git branch --show-current)" == main ]]; then git merge -q --ff-only "$om"; else git fetch -q . "$om:refs/heads/main"; fi \
      || { echo "land: git refused to fast-forward main to origin/main (local changes in the way?)" >&2; exit 1; }
    echo "land: main fast-forwarded to origin/main $(git rev-parse --short main)" >&2
    return 0
  fi
  if git merge-base --is-ancestor "$om" "$cur"; then
    echo "land: main is $(git rev-list --count "$om..$cur") commit(s) ahead of origin/main; they are pushed with the next landing" >&2
    return 0
  fi
  echo "land: main and origin/main have diverged ($(git rev-parse --short main) vs $(git rev-parse --short "$om")); nothing moved" >&2
  exit 8
}

# $1: main's tip before the landing, or empty for HEAD (nothing to take back).
take_back() { [[ -z "$1" ]] || git reset -q --keep "$1" || echo "land: could not take the landing back; main is at $(git rev-parse --short main)" >&2; }

push_main() {
  local old="$1" delay
  for delay in "${BACKOFF[@]}" ""; do
    git push -q origin "refs/heads/main:refs/heads/main" 2>/dev/null && return 0
    if fetch_once; then
      git merge-base --is-ancestor main refs/remotes/origin/main && return 0
      if ! git merge-base --is-ancestor refs/remotes/origin/main main; then
        if [[ -z "$old" ]]; then
          echo "land: origin/main moved; main and origin/main have diverged, nothing pushed" >&2
          exit 8
        fi
        take_back "$old"
        sync_main
        echo "land: origin/main moved (someone landed first); main is at $(git rev-parse --short main), nothing pushed; rebase onto main, re-run the gate, then land again" >&2
        exit 4
      fi
    fi
    [[ -n "$delay" ]] || break
    echo "land: pushing main to origin failed; retrying in ${delay}s" >&2
    sleep "$delay"
  done
  take_back "$old"
  echo "land: could not push main to origin; main is at $(git rev-parse --short main), nothing published" >&2
  exit 9
}

main() {
  case "${1:-}" in
    --self-test) self_test; return ;;
    --sync)
      [[ $# -eq 1 ]] || usage
      check_holder
      if use_origin; then sync_main; fi
      echo "land: main $(git rev-parse --short main)"
      return ;;
  esac
  [[ $# -eq 1 && "$1" != -* ]] || usage
  local branch="$1" src="" old=""
  check_holder
  if [[ "$branch" == HEAD ]]; then
    [[ "$(git branch --show-current)" == main ]] \
      || { echo "land: HEAD lands a commit made on main; this checkout is not on main" >&2; exit 1; }
  else
    src="refs/heads/$branch"
    git rev-parse -q --verify "$src^{commit}" >/dev/null || { echo "land: no branch '$branch'" >&2; exit 1; }
    on_main
  fi
  if use_origin; then sync_main; fi
  if [[ -n "$src" ]]; then
    if ! git merge-base --is-ancestor main "$src"; then
      echo "land: $branch does not contain main; rebase it onto main, re-run the gate, then land again" >&2
      exit 4
    fi
    old="$(git rev-parse main)"
    git merge -q --ff-only "$src" \
      || { echo "land: git refused to fast-forward main to $branch (local changes in the way?)" >&2; exit 1; }
  fi
  if use_origin; then
    push_main "$old"
    echo "land: pushed main to origin" >&2
  fi
  echo "land: $branch -> main $(git rev-parse --short main)"
}

self_test() {
  local tmp pass=0 total=0 rc self realgit
  self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  realgit="$(command -v git)"
  tmp="$(mktemp -d)"
  local origin="$tmp/origin.git" a="$tmp/a" b="$tmp/b"
  ok() { total=$((total+1)); if "$@"; then pass=$((pass+1)); else echo "FAIL $CASE"; fi; }
  ga() { git -C "$a" -c user.email=t@t -c user.name=t "$@"; }
  gb() { git -C "$b" -c user.email=t@t -c user.name=t "$@"; }
  gor() { git -C "$origin" "$@"; }
  runin() { local d="$1"; shift; (cd "$d" && LAND_BACKOFF="0 0 0 0" bash "$self" "$@") >/dev/null 2>&1; }
  eq() { [[ "$1" == "$2" ]]; }

  git init -q --bare -b main "$origin"
  git init -q -b main "$a"
  ga commit -q --allow-empty -m base
  ga remote add origin "$origin" && ga push -q origin main
  git clone -q "$origin" "$b" 2>/dev/null

  CASE="lands a branch from main, pushes, deletable"
  ga switch -q -c feat/HE-1-a && ga commit -q --allow-empty -m a1 && ga switch -q main
  runin "$a" feat/HE-1-a && rc=0 || rc=$?
  ok eq "$rc|$(ga rev-parse main)|$(gor rev-parse main)|$(ga branch --show-current)" "0|$(ga rev-parse feat/HE-1-a)|$(ga rev-parse feat/HE-1-a)|main"

  CASE="lands from the branch itself, ends on main"
  ga switch -q -c feat/HE-2-b && ga commit -q --allow-empty -m b1
  runin "$a" feat/HE-2-b && rc=0 || rc=$?
  ok eq "$rc|$(gor rev-parse main)|$(ga branch --show-current)" "0|$(ga rev-parse feat/HE-2-b)|main"

  CASE="missing branch"
  runin "$a" feat/HE-9-none && rc=0 || rc=$?
  ok eq "$rc" 1

  CASE="usage"
  runin "$a" --bogus && rc=0 || rc=$?
  ok eq "$rc" 64

  CASE="branch behind origin: main follows origin, exit 4"
  gb switch -q -c feat/HE-3-c && gb commit -q --allow-empty -m c1 && gb switch -q main
  runin "$b" feat/HE-3-c && rc=0 || rc=$?
  ok eq "$rc|$(gb rev-parse main)" "4|$(gor rev-parse main)"

  CASE="rebased branch lands"
  gb rebase -q main feat/HE-3-c && gb switch -q main
  runin "$b" feat/HE-3-c && rc=0 || rc=$?
  ok eq "$rc|$(gor rev-parse main)" "0|$(gb rev-parse feat/HE-3-c)"

  CASE="--sync fast-forwards main"
  runin "$a" --sync && rc=0 || rc=$?
  ok eq "$rc|$(ga rev-parse main)" "0|$(gor rev-parse main)"

  CASE="--sync from a ticket branch moves main, stays on the branch"
  gb switch -q main && gb commit -q --allow-empty -m s1 && gb push -q origin main
  ga switch -q -c feat/HE-7-g
  runin "$a" --sync && rc=0 || rc=$?
  ok eq "$rc|$(ga rev-parse main)|$(ga branch --show-current)" "0|$(gor rev-parse main)|feat/HE-7-g"
  ga switch -q main && ga branch -q -D feat/HE-7-g

  CASE="HEAD pushes a commit made on main"
  ga commit -q --allow-empty -m retro
  runin "$a" HEAD && rc=0 || rc=$?
  ok eq "$rc|$(gor rev-parse main)" "0|$(ga rev-parse main)"

  CASE="HEAD off main is refused"
  ga switch -q -c feat/HE-4-d && ga commit -q --allow-empty -m d1
  runin "$a" HEAD && rc=0 || rc=$?
  ok eq "$rc" 1

  CASE="main ahead by hand is pushed with the landing"
  ga switch -q main && ga commit -q --allow-empty -m byhand && ga rebase -q main feat/HE-4-d && ga switch -q main
  runin "$a" feat/HE-4-d && rc=0 || rc=$?
  ok eq "$rc|$(gor rev-parse main)" "0|$(ga rev-parse feat/HE-4-d)"

  CASE="main held by another worktree: exit 3, nothing moves"
  ga switch -q -c feat/HE-5-e && ga commit -q --allow-empty -m e1
  ga worktree add -q "$tmp/other" main
  local before; before="$(ga rev-parse main)"
  runin "$a" feat/HE-5-e && rc=0 || rc=$?
  ok eq "$rc|$(ga rev-parse main)" "3|$before"
  ga worktree remove "$tmp/other"

  CASE="diverged: exit 8"
  gb switch -q main && gb commit -q --allow-empty -m rogue
  runin "$b" --sync && rc=0 || rc=$?
  ok eq "$rc" 8
  gb reset -q --hard origin/main

  mkdir -p "$tmp/bin"
  CASE="push race: landing taken back, main at the rival, exit 4"
  local rival otip
  rival="$(GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
    gor commit-tree -p main -m rival "$(gor rev-parse 'main^{tree}')")"
  printf '#!/usr/bin/env bash\nif [[ "$1" == push && ! -e "%s/raced" ]]; then touch "%s/raced"; "%s" -C "%s" update-ref refs/heads/main %s; fi\nexec "%s" "$@"\n' \
    "$tmp" "$tmp" "$realgit" "$origin" "$rival" "$realgit" > "$tmp/bin/git"
  chmod +x "$tmp/bin/git"
  (cd "$a" && PATH="$tmp/bin:$PATH" LAND_BACKOFF="0 0 0 0" bash "$self" feat/HE-5-e) >/dev/null 2>&1 && rc=0 || rc=$?
  ok eq "$rc|$(ga rev-parse main)|$(gor rev-parse main)" "4|$rival|$rival"

  printf '#!/usr/bin/env bash\nif [[ "$1" == fetch && " $* " == *" origin "* ]]; then n=$(( $(cat "%s/n" 2>/dev/null || echo 0) + 1 )); echo $n > "%s/n"; if (( n <= ${STUB_FAILS:-0} )); then exit 128; fi; fi\nif [[ "$1" == push && -n "${STUB_PUSH_DOWN:-}" ]]; then exit 128; fi\nexec "%s" "$@"\n' \
    "$tmp" "$tmp" "$realgit" > "$tmp/bin/git"
  ga rebase -q main feat/HE-5-e && ga switch -q main

  CASE="fetch fails twice, then lands"
  rm -f "$tmp/n"
  (cd "$a" && PATH="$tmp/bin:$PATH" STUB_FAILS=2 LAND_BACKOFF="0 0 0 0" bash "$self" feat/HE-5-e) >/dev/null 2>&1 && rc=0 || rc=$?
  ok eq "$rc|$(cat "$tmp/n")|$(gor rev-parse main)" "0|3|$(ga rev-parse feat/HE-5-e)"

  CASE="origin down: exit 9, nothing moves"
  ga switch -q -c feat/HE-6-f && ga commit -q --allow-empty -m f1 && ga switch -q main
  otip="$(gor rev-parse main)"; rm -f "$tmp/n"
  (cd "$a" && PATH="$tmp/bin:$PATH" STUB_FAILS=99 LAND_BACKOFF="0 0 0 0" bash "$self" feat/HE-6-f) >/dev/null 2>&1 && rc=0 || rc=$?
  ok eq "$rc|$(ga rev-parse main)|$(gor rev-parse main)" "9|$otip|$otip"

  CASE="push down: landing taken back, exit 9"
  rm -f "$tmp/n"
  (cd "$a" && PATH="$tmp/bin:$PATH" STUB_PUSH_DOWN=1 LAND_BACKOFF="0 0 0 0" bash "$self" feat/HE-6-f) >/dev/null 2>&1 && rc=0 || rc=$?
  ok eq "$rc|$(ga rev-parse main)|$(gor rev-parse main)" "9|$otip|$otip"

  CASE="LAND_NO_PUSH lands locally only"
  (cd "$a" && LAND_NO_PUSH=1 bash "$self" feat/HE-6-f) >/dev/null 2>&1 && rc=0 || rc=$?
  ok eq "$rc|$(ga rev-parse main)|$(gor rev-parse main)" "0|$(ga rev-parse feat/HE-6-f)|$otip"

  rm -rf "$tmp"
  echo "land self-test: $pass/$total passed"
  [[ $pass == "$total" ]]
}

main "$@"
