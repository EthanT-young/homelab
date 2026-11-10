#!/usr/bin/env bash
# Pull-based deployer: keeps every opted-in repo under $BASE in sync with
# origin/main and applies what changed. Run by homelab-deploy.timer every minute.
#
#   - Repos: $BASE itself (homelab) plus every $BASE/*/ git repo. A repo is only
#     deployed if it has a `.deploy` marker that exists on this server and is NOT
#     tracked by git (gitignored), so no upstream repo can opt itself in.
#   - The incoming commit is validated in a scratch copy BEFORE the server's
#     files change: `docker compose config` for changed projects, and
#     `caddy validate` (with the Caddy image that commit pins) for Caddy changes.
#   - Project repos (everything but homelab) must also pass compose_policy.py:
#     no privileged mode, host namespaces, bind mounts outside the repo,
#     docker.sock and so on, unless compose-policy.json allows it. It runs on
#     the scratch copy and again in the real checkout right before `up`.
#   - Then fast-forward and `docker compose up -d --build --remove-orphans` for
#     changed projects, plus a Caddy hot reload.
#   - Never overwrites server-side work: uncommitted edits or commits that are
#     not on GitHub make the repo be skipped (and the run counts as failed).
#   - A repo seen for the first time is deployed in full.
#   - On failure: retried every run; after 3 failures of the same commit, only
#     every 15 minutes. No automatic rollback.
#   - Heartbeat: if DEPLOY_PUSH_URL is set (~/.config/homelab-deploy/env), every
#     fully healthy run pings it. Any failure, skip or open alert withholds it.
#   - Alerts that need a human (e.g. a compose file was deleted, so its
#     containers are still running) are written to $STATE_DIR/attention and
#     withhold the heartbeat until that file is deleted.
#
# Everything lives inside functions and main() is called on the last line, so
# bash parses the whole file before running it; the script can update itself.

main() {
  set -uo pipefail
  export GIT_TERMINAL_PROMPT=0
  # Never run hooks or fsmonitor from a checkout's .git: a project's container
  # must not be able to get code run as this user through git.
  export GIT_CONFIG_COUNT=2 \
    GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null \
    GIT_CONFIG_KEY_1=core.fsmonitor GIT_CONFIG_VALUE_1=false

  BASE="${DEPLOY_BASE:-/home/ethan/docker}"
  STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/homelab-deploy"
  ENV_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/homelab-deploy/env"
  BRANCH=main
  CADDY_CONTAINER=caddy
  CADDY_PROJECT=caddy          # homelab-relative folder of the Caddy compose project
  local want_user="${DEPLOY_USER:-ethan}"

  if [[ "$(id -un)" != "$want_user" ]]; then
    echo "deploy.sh must run as $want_user (running as $(id -un)); refusing." >&2
    return 2
  fi

  mkdir -p "$STATE_DIR/tmp"

  # One run at a time; a second run waits for the first to finish.
  exec 9>"$STATE_DIR/lock"
  flock 9

  DEPLOY_PUSH_URL=""
  # shellcheck disable=SC1090
  [[ -r "$ENV_FILE" ]] && source "$ENV_FILE"

  local failed=0 repo
  local -a repos=()

  # Project repos first, homelab last: a new service is up before its Caddy route goes live.
  for repo in "$BASE"/*/; do
    repo="${repo%/}"
    [[ -d "$repo/.git" ]] && repos+=("$repo")
  done
  [[ -d "$BASE/.git" ]] && repos+=("$BASE")

  for repo in "${repos[@]}"; do
    [[ -f "$repo/.deploy" ]] || continue
    if git -C "$repo" ls-files --error-unmatch .deploy >/dev/null 2>&1; then
      log "$(basename "$repo")" "SKIPPED: .deploy is tracked by git; the opt-in marker must be server-local (gitignored)"
      failed=1
      continue
    fi
    deploy_repo "$repo" || failed=1
  done

  if [[ -s "$STATE_DIR/attention" ]]; then
    log "-" "attention needed (delete $STATE_DIR/attention once handled):"
    sed 's/^/    /' "$STATE_DIR/attention"
    failed=1
  fi

  if (( failed == 0 )) && [[ -n "$DEPLOY_PUSH_URL" ]]; then
    curl -fsS -m 10 -o /dev/null "${DEPLOY_PUSH_URL%%\?*}?status=up&msg=OK&ping=" \
      || log "-" "warning: heartbeat ping failed"
  fi
  return "$failed"
}

log() { echo "[$1] ${*:2}"; }

attention() { echo "$(date -Is) [$1] ${*:2}" >> "$STATE_DIR/attention"; log "$1" "ATTENTION: ${*:2}"; }

write_atomic() { printf '%s\n' "$2" > "$1.tmp" && mv -f "$1.tmp" "$1"; }

# Nearest directory at or above $1 (stopping at root $2) holding a compose file.
compose_dir_for() {
  local dir="$1" root="$2" f
  while :; do
    for f in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
      [[ -f "$dir/$f" ]] && { echo "$dir"; return 0; }
    done
    [[ "$dir" == "$root" ]] && return 1
    dir="$(dirname "$dir")"
  done
}

# The compose file in $1, in the order compose itself prefers. Fails if there is
# more than one (compose would quietly pick one) or an override file (`-f`
# would quietly ignore it).
compose_file_in() {
  local dir="$1" f found=()
  for f in compose.yaml compose.yml docker-compose.yaml docker-compose.yml; do
    [[ -f "$dir/$f" ]] && found+=("$dir/$f")
  done
  for f in compose.override.yaml compose.override.yml docker-compose.override.yaml docker-compose.override.yml; do
    [[ -e "$dir/$f" ]] && return 1
  done
  (( ${#found[@]} == 1 )) || return 1
  echo "${found[0]}"
}

# Compose project name for a folder ("$repo/." for a compose file at the repo
# root), normalized the way compose does it.
project_name_for() {
  local dir="$1"
  while [[ "$dir" == */. || "$dir" == */ ]]; do dir="${dir%.}"; dir="${dir%/}"; done
  basename "$dir" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9_-'
}

# Every `docker compose` call for a project repo goes through here, so the
# policy check sees exactly what `up` will do: a fixed project name and compose
# file (a committed .env can't swap them via COMPOSE_PROJECT_NAME/COMPOSE_FILE),
# and none of the deployer's environment for the file to interpolate.
# $1 timeout in seconds, $2 folder, $3 project name, $4 compose file.
project_compose() {
  local secs="$1" dir="$2" project="$3" file="$4"; shift 4
  (cd "$dir" && timeout "$secs" env -i PATH="$PATH" HOME="$HOME" \
     docker compose -p "$project" -f "$file" "$@")
}

# compose_policy.py on one project repo. $1 repo name, $2 repo root to confine
# paths to (scratch copy or real checkout), $3 project folder in that root,
# $4 the real checkout's path, $5 scratch dir.
policy_check() {
  local rname="$1" root="$2" dir="$3" real="$4" scratch="$5" file out project w
  # Only a compose file at the repo root, and the project is named after the
  # server's folder for the repo. A subfolder name comes from the repo's own
  # commits, so `ai-stack/compose.yaml` would otherwise run as homelab's
  # ai-stack project (and --remove-orphans would delete its containers).
  if [[ "$(cd "$dir" && pwd -P)" != "$(cd "$root" && pwd -P)" ]]; then
    echo "policy: compose files are only allowed at the repo root"
    return 1
  fi
  project="$(project_name_for "$real")"
  if [[ ! "$project" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
    echo "policy: bad compose project name '$project'"
    return 1
  fi
  # Containers already labelled with this project must belong to this checkout.
  local owners
  if ! owners="$(timeout 60 docker ps -a --filter "label=com.docker.compose.project=$project" \
                   --format '{{.Label "com.docker.compose.project.working_dir"}}')"; then
    echo "policy: could not list containers to check who owns project '$project'"
    return 1
  fi
  while IFS= read -r w; do
    if [[ -n "$w" && "$w" != "$real" ]]; then
      echo "policy: compose project '$project' already belongs to $w"
      return 1
    fi
  done <<< "$owners"
  if ! file="$(compose_file_in "$dir")"; then
    echo "policy: expected exactly one compose file, and no override file, at the repo root"
    return 1
  fi
  if ! out="$(project_compose 120 "$dir" "$project" "$file" config --format json 2>&1 >"$scratch/config.json")" \
     || ! out+="$(project_compose 120 "$dir" "$project" "$file" config --format json --no-interpolate 2>&1 >"$scratch/raw.json")"; then
    echo "invalid compose config: $out"
    return 1
  fi
  timeout 60 python3 -I "$BASE/deploy/compose_policy.py" "$BASE/deploy/compose-policy.json" \
    "$rname" "$root" "$file" "$project" "$scratch/config.json" "$scratch/raw.json"
}

deploy_repo() {
  local repo="$1" name
  name="$(basename "$repo")"
  [[ "$repo" == "$BASE" ]] && name=homelab
  local work
  work="$(mktemp -d "$STATE_DIR/tmp/$name.XXXXXX")"
  _deploy_repo "$repo" "$name" "$work"
  local rc=$?
  rm -rf "$work"
  return "$rc"
}

_deploy_repo() {
  local repo="$1" name="$2" work="$3"
  local state="$STATE_DIR/$name.deployed" failfile="$STATE_DIR/$name.failed"
  local fetchfail="$STATE_DIR/$name.fetchfail" out
  cd "$repo" || return 1

  local cur
  cur="$(git symbolic-ref --short -q HEAD)"
  if [[ "$cur" != "$BRANCH" ]]; then
    log "$name" "SKIPPED: on branch '${cur:-detached HEAD}', not $BRANCH"
    return 1
  fi

  # Fetch. A single network blip is only a warning; 3 in a row is a failure.
  if ! out="$(timeout 60 git fetch --quiet origin "$BRANCH" 2>&1)"; then
    local n=$(( $(cat "$fetchfail" 2>/dev/null || echo 0) + 1 ))
    write_atomic "$fetchfail" "$n"
    log "$name" "warning: git fetch failed ($n in a row): $out"
    (( n >= 3 )) && return 1
    # Only treat a blip as harmless if the last known state was healthy.
    local d=""; [[ -s "$state" ]] && d="$(<"$state")"
    [[ -e "$failfile" || "$(git rev-parse HEAD)" != "$d" \
       || "$(git rev-parse -q --verify "origin/$BRANCH")" != "$d" ]] && return 1
    return 0
  fi
  rm -f "$fetchfail"

  local head target deployed=""
  head="$(git rev-parse HEAD)"
  target="$(git rev-parse "origin/$BRANCH")"
  [[ -s "$state" ]] && deployed="$(<"$state")"

  # Never deploy server-only commits, and never move past them.
  if [[ "$head" != "$target" ]] && ! git merge-base --is-ancestor "$head" "$target"; then
    if git merge-base --is-ancestor "$target" "$head"; then
      log "$name" "SKIPPED: server has commits that are not on GitHub; push them (or reset to origin/$BRANCH)"
    else
      log "$name" "SKIPPED: server history and origin/$BRANCH have diverged; resolve by hand"
    fi
    return 1
  fi

  [[ "$deployed" == "$target" ]] && { rm -f "$failfile"; return 0; }

  if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
    log "$name" "SKIPPED: uncommitted edits on the server; commit+push or discard them"
    git status --short --untracked-files=no | sed 's/^/    /'
    return 1
  fi

  # Back off after 3 failures of the same commit: retry every 15 min, not every minute.
  local fsha="" fcount=0 ftime=0 now
  now="$(date +%s)"
  [[ -s "$failfile" ]] && read -r fsha fcount ftime < "$failfile"
  if [[ "$fsha" == "$target" ]] && (( fcount >= 3 && now - ftime < 900 )); then
    return 1
  fi

  if _apply "$repo" "$name" "$work" "$head" "$target" "$deployed"; then
    write_atomic "$state" "$target"
    rm -f "$failfile"
    log "$name" "deployed ${target:0:7}"
    return 0
  fi
  [[ "$fsha" == "$target" ]] || fcount=0
  write_atomic "$failfile" "$target $((fcount + 1)) $now"
  log "$name" "deploy of ${target:0:7} failed (attempt $((fcount + 1))); will retry"
  return 1
}

_apply() {
  local repo="$1" name="$2" work="$3" head="$4" target="$5" deployed="$6"
  local tree="$work/tree" out p path dir

  # Scratch copy of the incoming commit; everything is validated against it.
  mkdir -p "$tree"
  if ! git archive "$target" | tar -x -C "$tree"; then
    log "$name" "error: could not export ${target:0:7}"
    return 1
  fi

  local -a changed=()
  if [[ -n "$deployed" ]] && git cat-file -e "$deployed^{commit}" 2>/dev/null; then
    mapfile -d '' -t changed < <(git diff --name-only --no-renames -z "$deployed" "$target")
  else
    [[ -n "$deployed" ]] && log "$name" "warning: last deployed commit ${deployed:0:7} not found"
    log "$name" "first deploy of this repo: applying everything"
    mapfile -d '' -t changed < <(git ls-tree -r --name-only -z "$target")
  fi

  # Map changed paths to compose projects (folders relative to the repo root).
  local -A projects=()
  local -a notes=()
  for path in "${changed[@]}"; do
    dir="$(dirname "$tree/$path")"
    while [[ ! -d "$dir" ]]; do dir="$(dirname "$dir")"; done
    if dir="$(compose_dir_for "$dir" "$tree")"; then
      p="${dir#"$tree"}"; p="${p#/}"
      projects["${p:-.}"]=1
    fi
    if [[ "$path" =~ (^|/)(docker-)?compose\.ya?ml$ && ! -e "$tree/$path" ]]; then
      notes+=("$path was deleted; its containers are still running. Stop them by hand: docker compose -p $(basename "$(dirname "$repo/$path")") down")
    fi
  done

  local caddy=0
  [[ "$repo" == "$BASE" && -n "${projects[$CADDY_PROJECT]:-}" ]] && caddy=1

  # 1. Validate the incoming commit before touching the server's files.
  local ok=1
  for p in "${!projects[@]}"; do
    if [[ "$repo" == "$BASE" ]]; then
      if ! out="$(cd "$tree/$p" && timeout 120 docker compose config -q 2>&1)"; then
        log "$name" "error: invalid compose config in $p: $out"
        ok=0
      fi
    else
      # The scratch copy lacks the checkout's server-local .env, which the
      # compose file may interpolate from; `up` will see it, so the check must too.
      # Only when the incoming commit has no .env of its own (if it does, the
      # check sees that one), and never through a symlink.
      if [[ -f "$repo/$p/.env" && ! -L "$repo/$p/.env" ]] \
         && [[ ! -e "$tree/$p/.env" && ! -L "$tree/$p/.env" ]]; then
        cp --no-dereference -- "$repo/$p/.env" "$tree/$p/.env"
      fi
      if ! out="$(policy_check "$name" "$tree" "$tree/$p" "$repo" "$work" 2>&1)"; then
        log "$name" "error: ${target:0:7} failed the compose check:"
        echo "$out" | sed 's/^/    /'
        # A project commit can land a minute before the homelab policy change it
        # needs (homelab deploys last), so only raise an alert on the third try.
        local prior=0
        [[ "${fsha:-}" == "$target" ]] && prior="${fcount:-0}"
        local msg="${target:0:7} refused by the compose policy (see journalctl -u homelab-deploy); fix the repo or deploy/compose-policy.json"
        if (( prior >= 2 )); then
          grep -qF -- "[$name] $msg" "$STATE_DIR/attention" 2>/dev/null || attention "$name" "$msg"
        fi
        ok=0
      fi
    fi
  done
  if (( caddy && ok )); then
    local image
    image="$(cd "$tree/$CADDY_PROJECT" && timeout 120 docker compose config --images 2>/dev/null | head -n1)"
    if [[ -z "$image" ]] || ! out="$(timeout 600 docker run --rm --network none \
          -v "$tree/$CADDY_PROJECT/conf:/etc/caddy:ro" "$image" \
          caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile 2>&1)"; then
      log "$name" "error: Caddyfile in ${target:0:7} failed validation:"
      echo "$out" | tail -n 8 | sed 's/^/    /'
      ok=0
    fi
  fi
  (( ok )) || return 1

  # 2. Move the server's files to the validated commit.
  if [[ "$head" != "$target" ]]; then
    if ! out="$(git merge --ff-only --no-overwrite-ignore "$target" 2>&1)"; then
      log "$name" "error: fast-forward failed: $out"
      return 1
    fi
    log "$name" "updated to ${target:0:7}: $(git log -1 --format=%s "$target")"
  fi
  local note
  for note in "${notes[@]}"; do
    grep -qF -- "[$name] $note" "$STATE_DIR/attention" 2>/dev/null || attention "$name" "$note"
  done

  # 3. Apply. `up -d` only recreates services whose config or image changed.
  for p in "${!projects[@]}"; do
    log "$name" "applying $p"
    if [[ "$repo" == "$BASE" ]]; then
      if ! (cd "$repo/$p" && timeout 1200 docker compose up -d --build --pull missing --remove-orphans); then
        log "$name" "error: docker compose up failed in $p"
        ok=0
      fi
      continue
    fi
    # Check again in the real checkout: its server-local .env, data folders and
    # symlinks are what `up` will actually see.
    local project file
    if ! out="$(policy_check "$name" "$repo" "$repo/$p" "$repo" "$work" 2>&1)"; then
      log "$name" "error: ${target:0:7} failed the compose check in the checkout; not starting it:"
      echo "$out" | sed 's/^/    /'
      local msg="${target:0:7} failed the compose check in the checkout; its containers were not changed"
      grep -qF -- "[$name] $msg" "$STATE_DIR/attention" 2>/dev/null || attention "$name" "$msg"
      ok=0
      continue
    fi
    project="$(project_name_for "$repo")"
    file="$(compose_file_in "$repo/$p")"
    if ! project_compose 1200 "$repo/$p" "$project" "$file" up -d --build --pull missing --remove-orphans; then
      log "$name" "error: docker compose up failed in $p"
      ok=0
    fi
  done
  if (( caddy )); then
    local i
    for i in 1 2 3 4 5; do
      if out="$(timeout 60 docker exec "$CADDY_CONTAINER" caddy reload --config /etc/caddy/Caddyfile 2>&1)"; then
        log "$name" "caddy reloaded"
        break
      fi
      (( i == 5 )) && { log "$name" "error: caddy reload failed: $out"; ok=0; }
      sleep 3
    done
  fi
  (( ok ))
}

main "$@"
exit $?
