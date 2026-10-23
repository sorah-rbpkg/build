#!/bin/bash
# Kills the debuild container once LOG has been quiet for longer than watchdog.json allows, or once kills.txt
# lists this job. Both files are re-read from main while the build runs.
set -uo pipefail
: "${JOB_ID:?}" "${GITHUB_RUN_ATTEMPT:?}" "${GITHUB_REPOSITORY:?}" "${GITHUB_WORKSPACE:?}" "${RUNNER_TEMP:?}"
log="${1:?}"

url="https://github.com/${GITHUB_REPOSITORY}.git"
repo="${RUNNER_TEMP}/watchdog.git"
git init -q --bare "$repo"

quiet="$(jq -er .quiet_seconds "${GITHUB_WORKSPACE}/watchdog.json")"
kills="$(cat "${GITHUB_WORKSPACE}/kills.txt")"
main=
checked=0

# Keeps the last values read when main is unreachable or its files are broken.
refresh() {
  local sha q k
  sha="$(git ls-remote "$url" refs/heads/main | cut -f1)" || return
  [[ -n "$sha" && "$sha" != "$main" ]] || return
  git -C "$repo" fetch -q --depth=1 "$url" "$sha" || return
  q="$(git -C "$repo" show "${sha}:watchdog.json" | jq -er .quiet_seconds)" || return
  k="$(git -C "$repo" show "${sha}:kills.txt")" || return
  [[ "$q" != "$quiet" ]] && echo "watchdog: quiet_seconds is ${q} on main at ${sha}"
  quiet="$q"
  kills="$k"
  main="$sha"
}

kill_build() {
  echo "::error::$1; killing the build"
  docker top debuild -o pid,ppid,etime,time,stat,wchan:24,args
  docker kill debuild
  exit
}

while sleep 10; do
  now="$(date +%s)"
  if (( now - checked >= 60 )); then
    checked="$now"
    refresh
    if sed -e 's/#.*//' -e 's/[[:space:]]*$//' <<< "$kills" | grep -qxF "${JOB_ID} ${GITHUB_RUN_ATTEMPT}"; then
      kill_build "kills.txt on main lists ${JOB_ID} ${GITHUB_RUN_ATTEMPT}"
    fi
  fi
  idle=$(( now - $(stat -c %Y "$log") ))
  (( idle >= quiet )) && kill_build "no output for ${idle}s"
done
