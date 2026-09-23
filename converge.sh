#!/usr/bin/env bash
# codex-converge - detached Claude <-> Codex convergence loop.
#
# Safety model: BOTH agents run strictly read-only.
#   - claude is invoked with --allowed-tools "Read Glob Grep" (no Write, Edit or Bash)
#   - codex  is invoked with -s read-only
# Neither agent can modify the user's project. Every file written by this loop
# is written by THIS SCRIPT, into the run directory under ~/.codex-converge.
#
# Persistent context (1.2.0, default on; --fresh-context turns it off): each agent keeps ONE
# conversation for the whole run. Claude: --session-id on its first call, --resume after.
# Codex: first call with --json to capture the thread id, then `codex exec resume` with
# sandbox_mode="read-only" forced on every resumed call (resume has no -s flag).
#
# The worker runs in its own session with stdio redirected to files, so it
# never needs a controlling terminal and survives SSH disconnect / logout.
#
#   converge.sh start --task "..." [--rounds N] [--dir DIR] [--author claude|codex]
#   converge.sh status [RUN] | watch [RUN] | show [RUN] | list | stop [RUN]

set -uo pipefail

VERSION="1.2.2"
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
STATE_ROOT="${CODEX_CONVERGE_HOME:-$HOME/.codex-converge}"
RUNS_DIR="$STATE_ROOT/runs"
DEFAULT_ROUNDS=4
CALL_TIMEOUT="${CODEX_CONVERGE_CALL_TIMEOUT:-1800}"

MARK_CHANGELOG="=== CHANGELOG ==="
MARK_DISSENT="=== DISSENT ==="

CHILD_PID=""

log() { printf '[%s] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*"; }
die() { printf 'converge: %s\n' "$*" >&2; exit 1; }

# Descendant pids, deepest first. "ps -ef" puts PID in $2 and PPID in $3 on
# both Linux and Git Bash, which is the only overlap those two ps builds have.
descendants() {
  local root="$1" snap frontier next pid found=""
  snap="$(ps -ef 2>/dev/null | awk 'NR>1 {print $2" "$3}')"
  frontier="$root"
  while [ -n "$frontier" ]; do
    next=""
    for pid in $frontier; do
      local kids
      kids="$(printf '%s\n' "$snap" | awk -v p="$pid" '$2==p {print $1}')"
      [ -n "$kids" ] && next="$next $kids"
    done
    [ -n "$next" ] && found="$next $found"
    frontier="$next"
  done
  printf '%s' "$found"
}

# TERM the whole tree (children first), then KILL whatever survives.
kill_tree() {
  local root="$1" pid kids
  kids="$(descendants "$root")"
  for pid in $kids $root; do kill -TERM "$pid" 2>/dev/null; done
  sleep 2
  for pid in $kids $root; do
    if kill -0 "$pid" 2>/dev/null; then kill -KILL "$pid" 2>/dev/null; fi
  done
}

usage() {
  cat <<'U'
codex-converge - run a Claude <-> Codex review loop until they agree.

  converge.sh start --task "<task>" [options]
  converge.sh status [RUN]      state, round, verdict, last activity
  converge.sh watch  [RUN]      follow the log (Ctrl-C is safe, run keeps going)
  converge.sh show   [RUN]      print the current solution
  converge.sh list              all runs, newest first
  converge.sh stop   [RUN]      terminate a running loop

start options:
  --task "<text>"         the task (or --task-file FILE)
  --rounds N              max review rounds (default 4)
  --dir DIR               directory the agents READ for context (default: cwd)
  --author claude|codex   who writes; the other reviews (default claude)
  --codex-model M         codex model slug (default: ~/.codex/config.toml)
  --codex-effort E        codex reasoning effort: low|medium|high|xhigh|max
  --codex-tier T          codex service tier, e.g. fast|flex|default (default: ~/.codex/config.toml)
  --claude-model M        claude model for the claude side (default: CLI default)
  --foreground            run inline instead of detaching (debugging)
  --fresh-context         start every agent call with a new context (pre-1.2.0 behaviour)

Both agents run read-only. Nothing in --dir is ever modified. All output goes
to $HOME/.codex-converge/runs/<id>/ : solution.md, review-N.md, dissent.md,
changelog.md, loop.log.
U
}

latest_run() {
  ls -1t "$RUNS_DIR" 2>/dev/null | head -1
}

resolve_run() {
  local r="${1:-}"
  [ -z "$r" ] && r="$(latest_run)"
  [ -z "$r" ] && die "no runs found"
  [ -d "$RUNS_DIR/$r" ] || die "no such run: $r"
  printf '%s' "$RUNS_DIR/$r"
}

# Serialized with flock: cmd_start (PID/PGID) and the detached worker (STATUS)
# write this file concurrently, and an unlocked read-modify-write lost keys.
set_state() {
  local f="$1/state.env" k="$2" v="$3"
  touch "$f"
  (
    if command -v flock >/dev/null 2>&1; then flock 9; fi
    grep -v "^${k}=" "$f" > "$f.tmp" 2>/dev/null || true
    printf '%s=%s\n' "$k" "$v" >> "$f.tmp"
    mv "$f.tmp" "$f"
  ) 9>"$f.lock"
}

get_state() {
  grep "^${2}=" "$1/state.env" 2>/dev/null | tail -1 | cut -d= -f2-
}

cmd_start() {
  local task="" task_file="" rounds="$DEFAULT_ROUNDS" workdir="$PWD"
  local author="claude" foreground=0
  local codex_model="" codex_effort="" codex_tier="" claude_model="" persist=1

  while [ $# -gt 0 ]; do
    case "$1" in
      --task)       task="${2:-}"; shift 2 ;;
      --task-file)  task_file="${2:-}"; shift 2 ;;
      --rounds)     rounds="${2:-}"; shift 2 ;;
      --dir)        workdir="${2:-}"; shift 2 ;;
      --author)     author="${2:-}"; shift 2 ;;
      --codex-model)  codex_model="${2:-}"; shift 2 ;;
      --codex-effort) codex_effort="${2:-}"; shift 2 ;;
      --codex-tier)   codex_tier="${2:-}"; shift 2 ;;
      --claude-model) claude_model="${2:-}"; shift 2 ;;
      --foreground) foreground=1; shift ;;
      --fresh-context) persist=0; shift ;;
      -h|--help)    usage; exit 0 ;;
      *)            die "unknown option: $1" ;;
    esac
  done

  if [ -n "$task_file" ]; then
    [ -f "$task_file" ] || die "no such file: $task_file"
    task="$(cat "$task_file")"
  fi
  [ -n "$task" ] || die "--task or --task-file is required"
  case "$author" in claude|codex) ;; *) die "--author must be claude or codex" ;; esac
  case "$rounds" in ''|*[!0-9]*) die "--rounds must be a number" ;; esac
  [ -d "$workdir" ] || die "no such directory: $workdir"
  workdir="$(cd "$workdir" && pwd)"

  local claude_bin codex_bin
  claude_bin="$(command -v claude || true)"
  codex_bin="$(command -v codex || true)"
  [ -n "$claude_bin" ] || die "claude CLI not found on PATH"
  [ -n "$codex_bin" ] || die "codex CLI not found on PATH"

  local id run
  id="$(date +%Y%m%d-%H%M%S)-$$"
  run="$RUNS_DIR/$id"
  mkdir -p "$run" || die "cannot create $run"

  printf '%s\n' "$task" > "$run/task.txt"
  : > "$run/dissent.md"
  : > "$run/changelog.md"

  {
    echo "RUN_ID=$id"
    echo "WORKDIR=$workdir"
    echo "ROUNDS=$rounds"
    echo "AUTHOR=$author"
    echo "CLAUDE_BIN=$claude_bin"
    echo "CODEX_BIN=$codex_bin"
    echo "CODEX_MODEL=$codex_model"
    echo "CODEX_EFFORT=$codex_effort"
    echo "CODEX_TIER=$codex_tier"
    echo "CLAUDE_MODEL=$claude_model"
    echo "PERSIST=$persist"
    echo "STARTED=$(date +'%Y-%m-%dT%H:%M:%S')"
    echo "HOST=$(hostname)"
  } > "$run/meta.env"

  set_state "$run" STATUS starting
  set_state "$run" ROUND 0

  if [ "$foreground" = 1 ]; then
    worker "$run"
    return $?
  fi

  # Detach: new session (no controlling terminal) + stdio to files.
  if command -v setsid >/dev/null 2>&1; then
    setsid nohup "$SELF" _worker "$run" >> "$run/loop.log" 2>&1 < /dev/null &
  else
    nohup "$SELF" _worker "$run" >> "$run/loop.log" 2>&1 < /dev/null &
    disown 2>/dev/null || true
  fi
  local pid=$!
  set_state "$run" PID "$pid"
  set_state "$run" PGID "$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ' || echo "$pid")"

  local reviewer
  if [ "$author" = claude ]; then reviewer=codex; else reviewer=claude; fi

  echo "started run $id on $(hostname)"
  echo "  author   : $author      reviewer: $reviewer"
  echo "  rounds   : up to $rounds"
  [ -n "$codex_model$codex_effort$codex_tier" ] && echo "  codex    : model=${codex_model:-default} effort=${codex_effort:-default} tier=${codex_tier:-default}"
  [ -n "$claude_model" ] && echo "  claude   : model=$claude_model"
  echo "  context  : $([ "$persist" = 1 ] && echo 'persistent per agent (rounds 2+ resume the same session)' || echo 'fresh every call')"
  echo "  reads    : $workdir  (read-only, never modified)"
  echo "  artifacts: $run"
  echo
  echo "Detached - closing this shell or dropping SSH will not stop it."
  echo "  $SELF status"
  echo "  $SELF show"
  echo "  $SELF stop"
}

# Both roles are read-only. Output is captured to $3 by the caller.

# Agent calls run in the background and are waited on, so a TERM arriving
# mid-call interrupts the wait immediately instead of being queued behind a
# foreground child that may have 30 minutes left on its timeout.
# The prompt goes in on STDIN, never as a trailing argument: both
# --allowed-tools and --add-dir are variadic, so a trailing prompt gets
# swallowed as a tool or directory name and the call dies with
# "Input must be provided either through stdin or as a prompt argument".
RESUME_NOTE="[Continuing your earlier session in this loop: you already hold the context you read before.
Re-read only the files named below, which changed since your last turn; do not re-read unchanged
evidence unless the revision depends on it. Your earlier findings still stand unless you revise them.]"

# Portable UUID: Linux /proc, then uuidgen, python3, python, PowerShell (Git Bash on Windows).
new_uuid() {
  local u=""
  [ -r /proc/sys/kernel/random/uuid ] && u="$(cat /proc/sys/kernel/random/uuid 2>/dev/null)"
  [ -z "$u" ] && command -v uuidgen >/dev/null 2>&1 && u="$(uuidgen 2>/dev/null)"
  [ -z "$u" ] && command -v python3 >/dev/null 2>&1 && u="$(python3 -c 'import uuid;print(uuid.uuid4())' 2>/dev/null)"
  [ -z "$u" ] && command -v python >/dev/null 2>&1 && u="$(python -c 'import uuid;print(uuid.uuid4())' 2>/dev/null)"
  [ -z "$u" ] && command -v powershell.exe >/dev/null 2>&1 && u="$(powershell.exe -NoProfile -Command '[guid]::NewGuid().ToString()' 2>/dev/null)"
  printf '%s' "$u" | tr -d '\r\n' | tr 'A-Z' 'a-z'
}

call_claude() {  # call_claude RUNDIR PROMPT OUTFILE
  local run="$1" prompt="$2" out="$3" rc
  . "$run/meta.env"
  local -a claude_args=()
  [ -n "${CLAUDE_MODEL:-}" ] && claude_args+=(--model "$CLAUDE_MODEL")
  local sess_file="$run/.claude_session" new_sess=""
  if [ "${PERSIST:-0}" = 1 ] && [ -s "$sess_file" ]; then
    claude_args+=(--resume "$(cat "$sess_file")")
    prompt="$RESUME_NOTE"$'\n\n'"$prompt"
    log "claude: resuming session $(cat "$sess_file")"
  elif [ "${PERSIST:-0}" = 1 ]; then
    new_sess="$(new_uuid)"
    [ -n "$new_sess" ] || { log "claude: could not generate a session id; this call starts fresh"; }
    [ -n "$new_sess" ] && { claude_args+=(--session-id "$new_sess"); log "claude: new session $new_sess"; }
  fi
  printf '%s' "$prompt" > "$run/.prompt"
  timeout "$CALL_TIMEOUT" "$CLAUDE_BIN" -p \
    --allowed-tools "Read Glob Grep" \
    --add-dir "$WORKDIR" --add-dir "$run" \
    "${claude_args[@]}" \
    < "$run/.prompt" > "$out" 2>> "$run/loop.log" &
  CHILD_PID=$!
  wait "$CHILD_PID"; rc=$?
  CHILD_PID=""
  [ "$rc" = 0 ] && [ -n "$new_sess" ] && printf '%s\n' "$new_sess" > "$sess_file"
  return $rc
}

call_codex() {   # call_codex RUNDIR PROMPT OUTFILE
  local run="$1" prompt="$2" out="$3" rc
  . "$run/meta.env"
  printf '%s' "$prompt" > "$run/.prompt"
  local -a model_args=()
  [ -n "${CODEX_MODEL:-}" ] && model_args+=(-m "$CODEX_MODEL")
  [ -n "${CODEX_EFFORT:-}" ] && model_args+=(-c "model_reasoning_effort=\"$CODEX_EFFORT\"")
  [ -n "${CODEX_TIER:-}" ] && model_args+=(-c "service_tier=\"$CODEX_TIER\"")
  local sess_file="$run/.codex_session" events="$run/.codex-first-events.jsonl"
  if [ "${PERSIST:-0}" = 1 ] && [ -s "$sess_file" ]; then
    local sid; sid="$(cat "$sess_file")"
    printf '%s\n\n%s' "$RESUME_NOTE" "$prompt" > "$run/.prompt"
    log "codex: resuming session $sid (sandbox_mode=read-only forced)"
    timeout "$CALL_TIMEOUT" "$CODEX_BIN" exec resume "$sid" \
      --skip-git-repo-check -c 'sandbox_mode="read-only"' \
      "${model_args[@]}" \
      -o "$out" - \
      < "$run/.prompt" >> "$run/loop.log" 2>&1 &
  elif [ "${PERSIST:-0}" = 1 ]; then
    log "codex: new session (thread id captured from --json events)"
    timeout "$CALL_TIMEOUT" "$CODEX_BIN" exec \
      -C "$WORKDIR" -s read-only --skip-git-repo-check --json \
      "${model_args[@]}" \
      -o "$out" - \
      < "$run/.prompt" > "$events" 2>> "$run/loop.log" &
  else
    timeout "$CALL_TIMEOUT" "$CODEX_BIN" exec \
      -C "$WORKDIR" -s read-only --skip-git-repo-check \
      "${model_args[@]}" \
      -o "$out" - \
      < "$run/.prompt" >> "$run/loop.log" 2>&1 &
  fi
  CHILD_PID=$!
  wait "$CHILD_PID"; rc=$?
  CHILD_PID=""
  if [ "${PERSIST:-0}" = 1 ] && [ ! -s "$sess_file" ] && [ -s "$events" ]; then
    local tid
    tid="$(grep -m1 -o '"thread_id":"[^"]*"' "$events" | cut -d'"' -f4)"
    if [ -n "$tid" ]; then printf '%s\n' "$tid" > "$sess_file"; log "codex: session $tid"
    else log "codex: no thread id in events; later calls start fresh"; fi
  fi
  return $rc
}

call_role() {    # call_role RUNDIR ROLE PROMPT OUTFILE   (ROLE=author|reviewer)
  local run="$1" role="$2" prompt="$3" out="$4"
  . "$run/meta.env"
  local who
  if [ "$role" = author ]; then who="$AUTHOR"
  elif [ "$AUTHOR" = claude ]; then who=codex
  else who=claude
  fi
  if [ "$who" = claude ]; then
    call_claude "$run" "$prompt" "$out"
  else
    call_codex "$run" "$prompt" "$out"
  fi
}

# Split the author's reply into solution / changelog / dissent sections.
split_author_output() {  # split_author_output RAW SOLUTION CHANGELOG DISSENT ROUND
  local raw="$1" sol="$2" changelog="$3" dissent="$4" r="$5"

  if ! grep -qF "$MARK_CHANGELOG" "$raw"; then
    cp "$raw" "$sol"
    log "warning: author omitted section markers; treating whole reply as the solution"
    return 0
  fi

  awk -v m="$MARK_CHANGELOG" 'index($0,m){exit} {print}' "$raw" > "$sol"

  {
    echo
    echo "## Round $r"
    awk -v a="$MARK_CHANGELOG" -v b="$MARK_DISSENT" '
      index($0,a){f=1; next} index($0,b){f=0} f{print}
    ' "$raw"
  } >> "$changelog"

  if grep -qF "$MARK_DISSENT" "$raw"; then
    local body
    body="$(awk -v b="$MARK_DISSENT" 'index($0,b){f=1; next} f{print}' "$raw" | sed '/^[[:space:]]*$/d')"
    case "$(printf '%s' "$body" | tr 'A-Z' 'a-z')" in
      ''|none|'none.'|'(none)'|'n/a') ;;
      *) { echo; echo "## Round $r"; printf '%s\n' "$body"; } >> "$dissent" ;;
    esac
  fi
}

build_draft_prompt() {
  local workdir="$1" task="$2"
  cat <<P
You are the AUTHOR in a two-agent convergence loop.

TASK:
$task

You are READ-ONLY: you cannot write files, and you must not try. Print your
solution as your reply - the harness captures it.

Context directory (read whatever you need from it): $workdir

Print the complete solution in markdown. Be specific and complete: someone
should be able to act on it alone. End with a short "Assumptions" section.
Do not ask questions - make reasonable choices and record them as assumptions.

Then print these two sections, exactly these marker lines, nothing after:

$MARK_CHANGELOG
Initial draft.

$MARK_DISSENT
none
P
}

build_review_prompt() {
  local sol="$1" changelog="$2" dissent="$3" r="$4" max="$5" task="$6" workdir="$7"
  cat <<P
You are the REVIEWER in a two-agent convergence loop. Round $r of $max.

TASK THE SOLUTION MUST SATISFY:
$task

Read these files now:
  $sol        - the current solution under review
  $changelog  - what the author changed in previous rounds
  $dissent    - points the author formally disagreed with

Context directory (read-only): $workdir

Do NOT re-raise anything in $dissent unless you have new evidence - engage with
the author's reasoning instead. Do not re-raise points already resolved per the
changelog.

Review the solution. Rules:
- Tag every issue with exactly one of [BLOCKER], [MAJOR], [NIT].
  BLOCKER = wrong, unsafe, or does not satisfy the task.
  MAJOR   = a real defect worth fixing.
  NIT     = polish.
- Be concrete: name the specific section and say what breaks.
- Do NOT invent work to look thorough.
- If the solution is sound, say so plainly - approving is a valid outcome.

End your reply with exactly one line, nothing after it:
VERDICT: APPROVE
or
VERDICT: CHANGES_REQUIRED
P
}

build_revise_prompt() {
  local sol="$1" review="$2" r="$3" max="$4" task="$5" workdir="$6"
  cat <<P
You are the AUTHOR in a two-agent convergence loop. Round $r of $max.

TASK:
$task

Read these files now:
  $sol     - your current solution
  $review  - the reviewer's latest review

Context directory (read-only): $workdir

You are READ-ONLY: you cannot write files. Print the revised work as your
reply - the harness captures it and updates $sol for you.

For each [BLOCKER] and [MAJOR] in the review, do exactly one of:
  - fix it in the solution you print, or
  - refuse it, and say so in the DISSENT section below with your reasoning.
Never silently ignore one. Handle [NIT]s only if trivial.

Do not weaken correct work just to satisfy the reviewer. Agreement reached by
capitulating on a point you believe is right is a failure, not a success.

Print the COMPLETE revised solution first (not a diff, not just the changed
parts). Then print these two sections, exactly these marker lines:

$MARK_CHANGELOG
<what you changed this round, and what you rejected and why>

$MARK_DISSENT
<points you refused to concede, with your evidence - or the single word: none>
P
}

worker() {
  local run="$1"
  . "$run/meta.env"
  cd "$WORKDIR" || { set_state "$run" STATUS failed; die "cannot cd $WORKDIR"; }

  local sol="$run/solution.md"
  local dissent="$run/dissent.md"
  local changelog="$run/changelog.md"
  local raw="$run/.author-raw"
  local task; task="$(cat "$run/task.txt")"
  local reviewer
  if [ "$AUTHOR" = claude ]; then reviewer=codex; else reviewer=claude; fi

  # On TERM, take the in-flight agent process down with us.
  trap 'log "terminated by signal"; [ -n "$CHILD_PID" ] && kill_tree "$CHILD_PID"; set_state "$run" STATUS stopped; exit 143' TERM INT

  set_state "$run" STATUS running
  log "run $RUN_ID on $HOST : author=$AUTHOR reviewer=$reviewer rounds=$ROUNDS"
  log "context dir (read-only)=$WORKDIR"

  log "=== drafting ==="
  if ! call_role "$run" author "$(build_draft_prompt "$WORKDIR" "$task")" "$raw"; then
    log "author call failed or timed out while drafting"
    set_state "$run" STATUS failed
    exit 1
  fi
  if [ ! -s "$raw" ]; then
    log "author returned nothing"
    set_state "$run" STATUS failed
    exit 1
  fi
  split_author_output "$raw" "$sol" "$changelog" "$dissent" 0
  log "draft written ($(wc -l < "$sol") lines)"

  local prev_sum="" cur_sum="" stalls=0 r=1
  while [ "$r" -le "$ROUNDS" ]; do
    set_state "$run" ROUND "$r"
    local review="$run/review-$r.md"

    log "=== round $r/$ROUNDS : $reviewer reviewing ==="
    if ! call_role "$run" reviewer \
        "$(build_review_prompt "$sol" "$changelog" "$dissent" "$r" "$ROUNDS" "$task" "$WORKDIR")" \
        "$review"; then
      log "reviewer call failed or timed out"
      set_state "$run" STATUS failed
      exit 1
    fi
    log "review saved: $review"

    if grep -qE '^VERDICT:[[:space:]]*APPROVE' "$review"; then
      log "=== converged: $reviewer approved at round $r ==="
      set_state "$run" VERDICT approve
      set_state "$run" STATUS converged
      exit 0
    fi
    if ! grep -qE '^VERDICT:' "$review"; then
      log "warning: reviewer emitted no VERDICT line; treating as CHANGES_REQUIRED"
    fi
    set_state "$run" VERDICT changes-required

    log "=== round $r/$ROUNDS : $AUTHOR revising ==="
    prev_sum="$(cksum < "$sol")"
    if ! call_role "$run" author \
        "$(build_revise_prompt "$sol" "$review" "$r" "$ROUNDS" "$task" "$WORKDIR")" \
        "$raw"; then
      log "author call failed or timed out"
      set_state "$run" STATUS failed
      exit 1
    fi
    if [ ! -s "$raw" ]; then
      log "author returned nothing this round"
      set_state "$run" STATUS failed
      exit 1
    fi
    split_author_output "$raw" "$sol" "$changelog" "$dissent" "$r"
    cur_sum="$(cksum < "$sol")"

    if [ "$cur_sum" = "$prev_sum" ]; then
      stalls=$((stalls + 1))
      log "solution unchanged this round (stall $stalls/2)"
      if [ "$stalls" -ge 2 ]; then
        log "=== stalled: two rounds with no change and no approval ==="
        set_state "$run" STATUS stalled
        exit 0
      fi
    else
      stalls=0
    fi

    r=$((r + 1))
  done

  log "=== round cap reached ($ROUNDS) without approval ==="
  set_state "$run" STATUS max-rounds
  exit 0
}

cmd_status() {
  local run; run="$(resolve_run "${1:-}")"
  . "$run/meta.env"
  local st ro vd pid alive="no"
  st="$(get_state "$run" STATUS)"
  ro="$(get_state "$run" ROUND)"
  vd="$(get_state "$run" VERDICT)"
  pid="$(get_state "$run" PID)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then alive="yes"; fi

  echo "run      : $RUN_ID  ($HOST)"
  echo "status   : ${st:-unknown}    process alive: $alive"
  echo "round    : ${ro:-0} of $ROUNDS    last verdict: ${vd:-none}"
  echo "author   : $AUTHOR    context dir: $WORKDIR"
  echo "started  : $STARTED"
  echo "artifacts: $run"
  [ -f "$run/solution.md" ] && echo "solution : $(wc -l < "$run/solution.md") lines"
  [ -s "$run/dissent.md" ] && echo "dissent  : unresolved disagreements recorded - read $run/dissent.md"
  echo "--- last 15 log lines ---"
  tail -15 "$run/loop.log" 2>/dev/null
}

cmd_list() {
  if [ ! -d "$RUNS_DIR" ]; then echo "no runs yet"; return 0; fi
  printf '%-26s %-14s %-6s %s\n' RUN STATUS ROUND CONTEXT_DIR
  local d r
  for d in $(ls -1t "$RUNS_DIR" 2>/dev/null); do
    r="$RUNS_DIR/$d"
    [ -f "$r/meta.env" ] || continue
    printf '%-26s %-14s %-6s %s\n' "$d" "$(get_state "$r" STATUS)" \
      "$(get_state "$r" ROUND)" "$(grep '^WORKDIR=' "$r/meta.env" | cut -d= -f2-)"
  done
}

cmd_watch() {
  local run; run="$(resolve_run "${1:-}")"
  echo "following $run/loop.log - Ctrl-C only stops watching, not the run"
  tail -f "$run/loop.log"
}

cmd_show() {
  local run; run="$(resolve_run "${1:-}")"
  [ -f "$run/solution.md" ] || die "no solution yet in $run"
  cat "$run/solution.md"
}

cmd_stop() {
  local run; run="$(resolve_run "${1:-}")"
  local pgid pid
  pgid="$(get_state "$run" PGID)"
  pid="$(get_state "$run" PID)"

  if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
    echo "no live process for that run"
    set_state "$run" STATUS stopped
    return 0
  fi

  # Process group first (works where setsid made one), then walk the tree to
  # catch the agent CLI itself - killing only the worker leaves it running.
  [ -n "$pgid" ] && kill -TERM "-$pgid" 2>/dev/null
  kill_tree "$pid"

  # Give the OS a moment to reap before declaring failure.
  local i=0
  while [ "$i" -lt 6 ] && kill -0 "$pid" 2>/dev/null; do
    sleep 1
    i=$((i + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    echo "warning: pid $pid still alive after SIGKILL - check it by hand"
  else
    echo "stopped run $(basename "$run") (pid $pid and descendants)"
  fi
  set_state "$run" STATUS stopped
}

mkdir -p "$RUNS_DIR" 2>/dev/null || true
cmd="${1:-help}"
if [ $# -gt 0 ]; then shift; fi
case "$cmd" in
  start)   cmd_start "$@" ;;
  status)  cmd_status "$@" ;;
  list)    cmd_list "$@" ;;
  watch)   cmd_watch "$@" ;;
  show)    cmd_show "$@" ;;
  stop)    cmd_stop "$@" ;;
  _worker) worker "$@" ;;
  version) echo "codex-converge $VERSION" ;;
  help|-h|--help) usage ;;
  *) usage; exit 1 ;;
esac
