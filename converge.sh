#!/usr/bin/env bash
# codex-converge - detached Claude <-> Codex convergence loop.
#
# Safety model: EVERY agent runs strictly read-only.
#   - claude is invoked with --allowed-tools "Read Glob Grep" (no Write, Edit or Bash) and
#     --strict-mcp-config (1.4.0: no MCP servers load, so no connector tool can be reached even if
#     a project's settings allow it).
#     With subagents (1.4.0) it gets --tools "Read,Glob,Grep,Agent" (nothing else exists in the
#     process), --disallowed-tools "Bash Write Edit NotebookEdit", and one custom subagent
#     ("reader") whose own tool list is Read, Glob, Grep - it cannot spawn further subagents.
#   - codex  is invoked with -s read-only (resume: sandbox_mode="read-only" forced).
#     With subagents: agents.max_threads / max_concurrent_threads_per_session = N, max_depth = 1.
# No agent can modify the user's project. Every file written by this loop
# is written by THIS SCRIPT, into the run directory under ~/.codex-converge.
#
# Persistent context (1.2.0, default on; --fresh-context turns it off): each agent keeps ONE
# conversation for the whole run. Claude: --session-id on its first call, --resume after.
# Codex: first call with --json to capture the thread id, then `codex exec resume` with
# sandbox_mode="read-only" forced on every resumed call (resume has no -s flag).
# 1.4.0: session files are per agent id (.claude_session.A, .codex_session.R2, ...).
#
# Reviewer panel (1.4.0): one author (id A) and 1..6 reviewers (R1..RK) that review in
# parallel. Converged = every reviewer returned a review this round AND every one approved.
#
# The worker runs in its own session with stdio redirected to files, so it
# never needs a controlling terminal and survives SSH disconnect / logout.
#
#   converge.sh start --task "..." [--rounds N] [--dir DIR] [--author claude|codex] [--reviewer SPEC]...
#   converge.sh status [RUN] | watch [RUN] | show [RUN] | list | stop [RUN]

set -uo pipefail

VERSION="1.4.0"
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
STATE_ROOT="${CODEX_CONVERGE_HOME:-$HOME/.codex-converge}"
RUNS_DIR="$STATE_ROOT/runs"
DEFAULT_ROUNDS=4
MAX_REVIEWERS=6
CALL_TIMEOUT="${CODEX_CONVERGE_CALL_TIMEOUT:-1800}"

# Whether a live test showed codex subagents inherit the read-only sandbox. Empty = unverified,
# and `start` warns whenever a codex agent gets subagents.
CODEX_SUBAGENT_SANDBOX_VERIFIED="codex-cli 0.155.1, 2026-09-24: a sub-agent's apply_patch was rejected by the read-only sandbox"

MARK_CHANGELOG="=== CHANGELOG ==="
MARK_DISSENT="=== DISSENT ==="

# The only subagent the claude side may use. model=inherit: same model as its parent.
READER_AGENT_JSON='{"reader":{"description":"Read-only evidence gatherer. Reads and searches files and returns findings with file paths and line numbers. Cannot modify anything.","prompt":"You are a read-only evidence gatherer inside a review loop. Use Read, Glob and Grep to answer exactly the question you were given. Cite file paths and line numbers. Never attempt to modify anything.","tools":["Read","Glob","Grep"],"model":"inherit"}}'

CHILD_PIDS=""

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
  converge.sh status [RUN]      state, round, per-reviewer verdicts, last activity
  converge.sh watch  [RUN]      follow the log (Ctrl-C is safe, run keeps going)
  converge.sh show   [RUN]      print the current solution
  converge.sh list              all runs, newest first
  converge.sh stop   [RUN]      terminate a running loop

start options:
  --task "<text>"         the task (or --task-file FILE)
  --rounds N              max review rounds (default 4)
  --dir DIR               directory the agents READ for context (default: cwd)
  --author claude|codex   who writes (default claude); without --reviewer the other CLI reviews
  --reviewer SPEC         add a reviewer to the panel (repeatable, max 6). SPEC is comma-separated
                          key=value: cli=claude|codex (required), model=, effort=, tier= (codex),
                          subagents=N, focus=<text> (focus must be LAST; it takes the rest).
                          Omitted fields fall back to the side-wide flags below.
  --codex-model M         codex model slug (default: ~/.codex/config.toml)
  --codex-effort E        codex reasoning effort: low|medium|high|xhigh|max
  --codex-tier T          codex service tier, e.g. fast|flex|default (default: ~/.codex/config.toml)
  --claude-model M        claude model for the claude side (default: CLI default)
  --claude-effort E       claude effort: low|medium|high|xhigh|max (default: the calling agent's
                          effort, from $CLAUDE_EFFORT when started inside Claude Code)
  --claude-subagents N    let each claude agent use up to N parallel read-only subagents
                          (prompt-enforced cap; 0 = none, same as unset)
  --codex-subagents N     cap each codex agent at N parallel subagents (hard cap via config);
                          0 = disable codex multi_agent; unset = leave ~/.codex/config.toml alone
  --subagents N           shorthand for both (per-side flags win)
  --foreground            run inline instead of detaching (debugging)
  --fresh-context         start every agent call with a new context (pre-1.2.0 behaviour)

All agents run read-only. Nothing in --dir is ever modified. All output goes
to $HOME/.codex-converge/runs/<id>/ : solution.md, review-N-R<k>.md, dissent.md,
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

# Serialized with flock: cmd_start (PID/PGID), the detached worker (STATUS) and
# parallel reviewers write this file concurrently; an unlocked read-modify-write lost keys.
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

is_count() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# Agent field lookup from a sourced meta.env: agent_field ID FIELD (FIELD = CLI|MODEL|EFFORT|TIER|SUBS|FOCUS)
agent_field() { local v="${1}_${2}"; printf '%s' "${!v:-}"; }

agent_label() {  # agent_label ID  -> "R1 codex/gpt-6-astra/high [focus: numerics]"
  local id="$1" cli model effort focus s
  cli="$(agent_field "$id" CLI)"; model="$(agent_field "$id" MODEL)"
  effort="$(agent_field "$id" EFFORT)"; focus="$(agent_field "$id" FOCUS)"
  s="$id $cli/${model:-default}/${effort:-default}"
  [ -n "$focus" ] && s="$s [focus: $focus]"
  printf '%s' "$s"
}

cmd_start() {
  local task="" task_file="" rounds="$DEFAULT_ROUNDS" workdir="$PWD"
  local author="claude" foreground=0
  local codex_model="" codex_effort="" codex_tier="" claude_model="" claude_effort="${CLAUDE_EFFORT:-}" persist=1
  local claude_subs="" codex_subs="" both_subs=""
  local -a reviewer_specs=()

  while [ $# -gt 0 ]; do
    case "$1" in
      --task)       task="${2:-}"; shift 2 ;;
      --task-file)  task_file="${2:-}"; shift 2 ;;
      --rounds)     rounds="${2:-}"; shift 2 ;;
      --dir)        workdir="${2:-}"; shift 2 ;;
      --author)     author="${2:-}"; shift 2 ;;
      --reviewer)   reviewer_specs+=("${2:-}"); shift 2 ;;
      --codex-model)  codex_model="${2:-}"; shift 2 ;;
      --codex-effort) codex_effort="${2:-}"; shift 2 ;;
      --codex-tier)   codex_tier="${2:-}"; shift 2 ;;
      --claude-model) claude_model="${2:-}"; shift 2 ;;
      --claude-effort) claude_effort="${2:-}"; shift 2 ;;
      --claude-subagents) claude_subs="${2:-}"; is_count "$claude_subs" || die "--claude-subagents needs a number"; shift 2 ;;
      --codex-subagents)  codex_subs="${2:-}";  is_count "$codex_subs"  || die "--codex-subagents needs a number"; shift 2 ;;
      --subagents)        both_subs="${2:-}";   is_count "$both_subs"   || die "--subagents needs a number"; shift 2 ;;
      --foreground) foreground=1; shift ;;
      --fresh-context) persist=0; shift ;;
      -h|--help)    usage; exit 0 ;;
      *)            die "unknown option: $1" ;;
    esac
  done
  case "$claude_effort" in ""|low|medium|high|xhigh|max) ;; *) die "bad --claude-effort / CLAUDE_EFFORT: $claude_effort" ;; esac
  [ -z "$claude_subs" ] && claude_subs="$both_subs"
  [ -z "$codex_subs" ] && codex_subs="$both_subs"

  if [ -n "$task_file" ]; then
    [ -f "$task_file" ] || die "no such file: $task_file"
    task="$(cat "$task_file")"
  fi
  [ -n "$task" ] || die "--task or --task-file is required"
  case "$author" in claude|codex) ;; *) die "--author must be claude or codex" ;; esac
  case "$rounds" in ''|*[!0-9]*) die "--rounds must be a number" ;; esac
  [ -d "$workdir" ] || die "no such directory: $workdir"
  workdir="$(cd "$workdir" && pwd)"

  # Default panel: one reviewer, the other CLI (the pre-1.4.0 loop).
  if [ "${#reviewer_specs[@]}" -eq 0 ]; then
    if [ "$author" = claude ]; then reviewer_specs=("cli=codex"); else reviewer_specs=("cli=claude"); fi
  fi
  local nrev="${#reviewer_specs[@]}"
  [ "$nrev" -le "$MAX_REVIEWERS" ] || die "at most $MAX_REVIEWERS reviewers (got $nrev)"
  [ "$nrev" -gt 3 ] && echo "converge: warning: $nrev reviewers - past ~3 the author's answers to each review get thinner" >&2

  # Resolve every agent to concrete fields: ID_CLI ID_MODEL ID_EFFORT ID_TIER ID_SUBS ID_FOCUS.
  local -a agent_lines=()
  side_defaults() {  # side_defaults CLI -> sets d_model d_effort d_tier d_subs
    if [ "$1" = claude ]; then d_model="$claude_model"; d_effort="$claude_effort"; d_tier=""; d_subs="$claude_subs"
    else d_model="$codex_model"; d_effort="$codex_effort"; d_tier="$codex_tier"; d_subs="$codex_subs"; fi
  }
  emit_agent() {  # emit_agent ID CLI MODEL EFFORT TIER SUBS FOCUS
    local f n=0
    for f in CLI MODEL EFFORT TIER SUBS FOCUS; do
      n=$((n + 1))
      agent_lines+=("$(printf '%s_%s=%q' "$1" "$f" "${@:$((n + 1)):1}")")
    done
  }
  local d_model d_effort d_tier d_subs
  side_defaults "$author"
  emit_agent A "$author" "$d_model" "$d_effort" "$d_tier" "$d_subs" ""

  local k=0 spec
  for spec in "${reviewer_specs[@]}"; do
    k=$((k + 1))
    local rest="$spec" field key val cli="" model="" effort="" tier="" subs="" focus=""
    local set_model=0 set_effort=0 set_tier=0 set_subs=0
    while [ -n "$rest" ]; do
      rest="${rest#"${rest%%[![:space:]]*}"}"
      case "$rest" in focus=*) focus="${rest#focus=}"; break ;; esac
      field="${rest%%,*}"
      if [ "$field" = "$rest" ]; then rest=""; else rest="${rest#*,}"; fi
      field="${field%"${field##*[![:space:]]}"}"
      [ -z "$field" ] && continue
      key="${field%%=*}"; val="${field#*=}"
      [ "$key" = "$field" ] && die "--reviewer $k: field needs key=value: '$field'"
      case "$key" in
        cli)       cli="$val" ;;
        model)     model="$val"; set_model=1 ;;
        effort)    effort="$val"; set_effort=1 ;;
        tier)      tier="$val"; set_tier=1 ;;
        subagents) subs="$val"; set_subs=1; is_count "$subs" || die "--reviewer $k: subagents needs a number" ;;
        *)         die "--reviewer $k: unknown field '$key' (cli, model, effort, tier, subagents, focus)" ;;
      esac
    done
    case "$cli" in claude|codex) ;; *) die "--reviewer $k: cli=claude or cli=codex is required" ;; esac
    side_defaults "$cli"
    [ "$set_model" = 1 ]  || model="$d_model"
    [ "$set_effort" = 1 ] || effort="$d_effort"
    [ "$set_tier" = 1 ]   || tier="$d_tier"
    [ "$set_subs" = 1 ]   || subs="$d_subs"
    if [ "$cli" = claude ]; then
      case "$effort" in ""|low|medium|high|xhigh|max) ;; *) die "--reviewer $k: bad claude effort: $effort" ;; esac
      [ -n "$tier" ] && die "--reviewer $k: tier= applies to codex only"
    fi
    emit_agent "R$k" "$cli" "$model" "$effort" "$tier" "$subs" "$focus"
  done

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
    echo "VERSION=$VERSION"
    echo "WORKDIR=$workdir"
    echo "ROUNDS=$rounds"
    echo "AUTHOR=$author"
    echo "CLAUDE_BIN=$claude_bin"
    echo "CODEX_BIN=$codex_bin"
    echo "CODEX_MODEL=$codex_model"
    echo "CODEX_EFFORT=$codex_effort"
    echo "CODEX_TIER=$codex_tier"
    echo "CLAUDE_MODEL=$claude_model"
    echo "CLAUDE_EFFORT_LEVEL=$claude_effort"
    echo "CLAUDE_SUBAGENTS=$claude_subs"
    echo "CODEX_SUBAGENTS=$codex_subs"
    echo "PERSIST=$persist"
    echo "REVIEWERS=$nrev"
    printf '%s\n' "${agent_lines[@]}"
    echo "STARTED=$(date +'%Y-%m-%dT%H:%M:%S')"
    echo "HOST=$(hostname)"
  } > "$run/meta.env"

  set_state "$run" STATUS starting
  set_state "$run" ROUND 0

  # Summary, from the meta.env just written so it shows exactly what the worker will use.
  (
    . "$run/meta.env"
    echo "run $id on $(hostname)"
    echo "  author   : $(agent_label A)$(subs_desc A)"
    for i in $(seq 1 "$REVIEWERS"); do echo "  reviewer : $(agent_label "R$i")$(subs_desc "R$i")"; done
    echo "  rounds   : up to $ROUNDS"
    echo "  context  : $([ "$PERSIST" = 1 ] && echo 'persistent per agent (rounds 2+ resume the same session)' || echo 'fresh every call')"
    echo "  parallel : author phase <= $(phase_width A)  review phase <= $(phase_width $(seq -f 'R%g' 1 "$REVIEWERS")) agent processes at once"
    warn=0
    for i in A $(seq -f 'R%g' 1 "$REVIEWERS"); do
      [ "$(agent_field "$i" CLI)" = codex ] && is_count "$(agent_field "$i" SUBS)" && [ "$(agent_field "$i" SUBS)" -gt 0 ] && warn=1
    done
    if [ "$warn" = 1 ] && [ -z "$CODEX_SUBAGENT_SANDBOX_VERIFIED" ]; then
      echo "  WARNING  : codex subagents are on, and it is NOT verified that they inherit -s read-only."
    elif [ "$warn" = 1 ]; then
      echo "  sandbox  : codex subagent read-only inheritance verified ($CODEX_SUBAGENT_SANDBOX_VERIFIED)"
    fi
    echo "  reads    : $WORKDIR  (read-only, never modified)"
    echo "  artifacts: $run"
  ) | tee -a "$run/loop.log"

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

  echo
  echo "Detached - closing this shell or dropping SSH will not stop it."
  echo "  $SELF status"
  echo "  $SELF show"
  echo "  $SELF stop"
}

subs_desc() {  # " subagents<=N" / " subagents=off" / "" (needs sourced meta.env)
  local s cli; s="$(agent_field "$1" SUBS)"; cli="$(agent_field "$1" CLI)"
  if [ -z "$s" ]; then
    [ "$cli" = codex ] && printf ' subagents=config-default'
  elif [ "$s" = 0 ]; then printf ' subagents=off'
  else printf ' subagents<=%s%s' "$s" "$([ "$cli" = claude ] && echo ' (prompt cap)')"
  fi
}

phase_width() {  # worst-case processes for a set of agent ids running at once
  local total=0 open="" id s cli
  for id in "$@"; do
    s="$(agent_field "$id" SUBS)"; cli="$(agent_field "$id" CLI)"
    total=$((total + 1))
    if is_count "$s"; then total=$((total + s))
    elif [ "$cli" = codex ]; then open=" + codex config default"
    fi
  done
  printf '%s%s' "$total" "$open"
}

# The prompt goes in on STDIN, never as a trailing argument: both
# --allowed-tools and --add-dir are variadic, so a trailing prompt gets
# swallowed as a tool or directory name and the call dies with
# "Input must be provided either through stdin or as a prompt argument".
RESUME_NOTE="[Continuing your earlier session in this loop: you already hold the context you read before.
Re-read only the files named below, which changed since your last turn; do not re-read unchanged
evidence unless the revision depends on it. Your earlier findings still stand unless you revise them.]"

subagent_note() {  # subagent_note CLI N
  local how
  if [ "$1" = claude ]; then how="the Agent tool with subagent_type \"reader\" (read-only: Read, Glob, Grep)"
  else how="sub-agents (they inherit your read-only sandbox)"; fi
  cat <<N
[Parallelism: you may run up to $2 subagents at once, via $how, to gather
independent evidence in parallel when that is faster than reading it yourself. Subagents start with
EMPTY context: spawn them only for reading you have not already done, and in resumed rounds rely on
what you already hold. Give each one a precise, self-contained question. Write your final reply
yourself - never delegate it.]
N
}

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

# agent_call RUN ID PROMPT OUTFILE - one read-only agent call, run SYNCHRONOUSLY.
# Callers always run it in the background and wait on it (see spawn_agent), so a TERM
# arriving mid-call interrupts the wait at once, and reviewers can run in parallel.
# Every agent has its own prompt file, session file and events file, keyed by ID.
agent_call() {
  local run="$1" id="$2" prompt="$3" out="$4" rc
  . "$run/meta.env"
  local cli model effort tier subs
  cli="$(agent_field "$id" CLI)"; model="$(agent_field "$id" MODEL)"
  effort="$(agent_field "$id" EFFORT)"; tier="$(agent_field "$id" TIER)"; subs="$(agent_field "$id" SUBS)"
  local pfile="$run/.prompt.$id"
  local sess_file="$run/.${cli}_session.$id"
  local resuming=0
  [ "${PERSIST:-0}" = 1 ] && [ -s "$sess_file" ] && resuming=1

  {
    [ "$resuming" = 1 ] && printf '%s\n\n' "$RESUME_NOTE"
    is_count "$subs" && [ "$subs" -gt 0 ] && { subagent_note "$cli" "$subs"; echo; }
    printf '%s' "$prompt"
  } > "$pfile"

  if [ "$cli" = claude ]; then
    local -a a=()
    [ -n "$model" ] && a+=(--model "$model")
    [ -n "$effort" ] && a+=(--effort "$effort")
    if is_count "$subs" && [ "$subs" -gt 0 ]; then
      a+=(--tools "Read,Glob,Grep,Agent" --allowed-tools "Read Glob Grep Agent"
          --disallowed-tools "Bash Write Edit NotebookEdit" --agents "$READER_AGENT_JSON")
    else
      a+=(--allowed-tools "Read Glob Grep")
    fi
    local new_sess=""
    if [ "$resuming" = 1 ]; then
      a+=(--resume "$(cat "$sess_file")")
      log "$id claude: resuming session $(cat "$sess_file")"
    elif [ "${PERSIST:-0}" = 1 ]; then
      new_sess="$(new_uuid)"
      [ -n "$new_sess" ] || log "$id claude: could not generate a session id; this call starts fresh"
      [ -n "$new_sess" ] && { a+=(--session-id "$new_sess"); log "$id claude: new session $new_sess"; }
    fi
    timeout "$CALL_TIMEOUT" "$CLAUDE_BIN" -p --strict-mcp-config \
      "${a[@]}" \
      --add-dir "$WORKDIR" --add-dir "$run" \
      < "$pfile" > "$out" 2>> "$run/loop.log"
    rc=$?
    [ "$rc" = 0 ] && [ -n "$new_sess" ] && printf '%s\n' "$new_sess" > "$sess_file"
    return $rc
  fi

  local -a m=()
  [ -n "$model" ] && m+=(-m "$model")
  [ -n "$effort" ] && m+=(-c "model_reasoning_effort=\"$effort\"")
  [ -n "$tier" ] && m+=(-c "service_tier=\"$tier\"")
  if is_count "$subs"; then
    if [ "$subs" = 0 ]; then m+=(--disable multi_agent)
    else m+=(--enable multi_agent -c "agents.max_threads=$subs"
             -c "agents.max_concurrent_threads_per_session=$subs" -c "agents.max_depth=1"); fi
  fi
  local events="$run/.codex-first-events.$id.jsonl"
  if [ "$resuming" = 1 ]; then
    local sid; sid="$(cat "$sess_file")"
    log "$id codex: resuming session $sid (sandbox_mode=read-only forced)"
    timeout "$CALL_TIMEOUT" "$CODEX_BIN" exec resume "$sid" \
      --skip-git-repo-check -c 'sandbox_mode="read-only"' \
      "${m[@]}" \
      -o "$out" - \
      < "$pfile" >> "$run/loop.log" 2>&1
    rc=$?
  elif [ "${PERSIST:-0}" = 1 ]; then
    log "$id codex: new session (thread id captured from --json events)"
    timeout "$CALL_TIMEOUT" "$CODEX_BIN" exec \
      -C "$WORKDIR" -s read-only --skip-git-repo-check --json \
      "${m[@]}" \
      -o "$out" - \
      < "$pfile" > "$events" 2>> "$run/loop.log"
    rc=$?
  else
    timeout "$CALL_TIMEOUT" "$CODEX_BIN" exec \
      -C "$WORKDIR" -s read-only --skip-git-repo-check \
      "${m[@]}" \
      -o "$out" - \
      < "$pfile" >> "$run/loop.log" 2>&1
    rc=$?
  fi
  # Keep the thread only if the call succeeded: a failed call (e.g. a bad model) still prints a
  # thread id, and resuming that dead thread next round would fail again.
  if [ "$rc" = 0 ] && [ "${PERSIST:-0}" = 1 ] && [ ! -s "$sess_file" ] && [ -s "$events" ]; then
    local tid
    tid="$(grep -m1 -o '"thread_id":"[^"]*"' "$events" | cut -d'"' -f4)"
    if [ -n "$tid" ]; then printf '%s\n' "$tid" > "$sess_file"; log "$id codex: session $tid"
    else log "$id codex: no thread id in events; later calls start fresh"; fi
  fi
  return $rc
}

# spawn_agent RUN ID PROMPT OUTFILE - start agent_call in the background; pid in SPAWNED_PID.
spawn_agent() {
  agent_call "$@" &
  SPAWNED_PID=$!
  CHILD_PIDS="$CHILD_PIDS $SPAWNED_PID"
}

run_author() {  # run_author RUN PROMPT OUTFILE
  local rc
  spawn_agent "$1" A "$2" "$3"
  wait "$SPAWNED_PID"; rc=$?
  CHILD_PIDS=""
  return $rc
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
You are the AUTHOR in a convergence loop: you write, a panel of reviewers critiques, you revise.

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
  local sol="$1" changelog="$2" dissent="$3" r="$4" max="$5" task="$6" workdir="$7" id="$8" nrev="$9" focus="${10}"
  local panel="" scope=""
  [ "$nrev" -gt 1 ] && panel="You are reviewer $id of a panel of $nrev reviewing in parallel; you will not see the
others' reviews, so review independently. Changelog and dissent entries may be tagged with
reviewer ids like [R2]."
  [ -n "$focus" ] && scope="YOUR FOCUS: $focus
Review the solution for this aspect only; other reviewers cover the rest. Approve if it is
sound on your aspect, even if you suspect issues elsewhere (mention those as [NIT] at most)."
  cat <<P
You are REVIEWER $id in a convergence loop. Round $r of $max.
$panel

TASK THE SOLUTION MUST SATISFY:
$task
$scope

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

build_revise_prompt() {  # build_revise_prompt SOL REVIEW_LIST R MAX TASK WORKDIR NOTE
  local sol="$1" reviews="$2" r="$3" max="$4" task="$5" workdir="$6" note="$7"
  cat <<P
You are the AUTHOR in a convergence loop. Round $r of $max.

TASK:
$task

Read these files now:
  $sol     - your current solution
$reviews
$note
Context directory (read-only): $workdir

You are READ-ONLY: you cannot write files. Print the revised work as your
reply - the harness captures it and updates $sol for you.

For each [BLOCKER] and [MAJOR] in every review, do exactly one of:
  - fix it in the solution you print, or
  - refuse it, and say so in the DISSENT section below with your reasoning.
Never silently ignore one. Handle [NIT]s only if trivial. Tag every CHANGELOG and
DISSENT item with the reviewer id(s) it answers, e.g. [R2].

If two reviewers contradict each other, choose the position you can defend, apply it,
and record the rejected one in DISSENT tagged with both ids, e.g. [R1 vs R2].

Do not weaken correct work just to satisfy a reviewer. Agreement reached by
capitulating on a point you believe is right is a failure, not a success.

Print the COMPLETE revised solution first (not a diff, not just the changed
parts). Then print these two sections, exactly these marker lines:

$MARK_CHANGELOG
<what you changed this round, and what you rejected and why - each item tagged [Rk]>

$MARK_DISSENT
<points you refused to concede, with your evidence and reviewer ids - or the single word: none>
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
  local nrev="${REVIEWERS:-1}"

  # On TERM, take every in-flight agent process down with us.
  trap 'log "terminated by signal"; for p in $CHILD_PIDS; do kill_tree "$p"; done; set_state "$run" STATUS stopped; exit 143' TERM INT

  set_state "$run" STATUS running
  log "run $RUN_ID on $HOST (v${VERSION:-?}) : author=$(agent_label A) reviewers=$nrev rounds=$ROUNDS"
  local k
  for k in $(seq 1 "$nrev"); do log "  R$k = $(agent_label "R$k")"; done
  log "context dir (read-only)=$WORKDIR"

  log "=== drafting ==="
  if ! run_author "$run" "$(build_draft_prompt "$WORKDIR" "$task")" "$raw"; then
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

    log "=== round $r/$ROUNDS : $nrev reviewer(s) reviewing in parallel ==="
    local -a pids=()
    CHILD_PIDS=""
    for k in $(seq 1 "$nrev"); do
      set_state "$run" "R${k}_STATE" reviewing
      spawn_agent "$run" "R$k" \
        "$(build_review_prompt "$sol" "$changelog" "$dissent" "$r" "$ROUNDS" "$task" "$WORKDIR" "R$k" "$nrev" "$(agent_field "R$k" FOCUS)")" \
        "$run/review-$r-R$k.md"
      pids[$k]="$SPAWNED_PID"
    done

    local ok=0 approved=0 failed_ids="" review_list="" rc f
    for k in $(seq 1 "$nrev"); do
      wait "${pids[$k]}"; rc=$?
      f="$run/review-$r-R$k.md"
      if [ "$rc" = 0 ] && [ -s "$f" ]; then
        ok=$((ok + 1))
        set_state "$run" "R${k}_STATE" ok
        if grep -qE '^VERDICT:[[:space:]]*APPROVE' "$f"; then
          approved=$((approved + 1))
          set_state "$run" "R${k}_VERDICT" approve
        else
          grep -qE '^VERDICT:' "$f" || log "warning: R$k emitted no VERDICT line; treating as CHANGES_REQUIRED"
          set_state "$run" "R${k}_VERDICT" changes-required
        fi
        review_list="$review_list  $f  - review by $(agent_label "R$k")"$'\n'
        log "R$k review saved: $f ($(get_state "$run" "R${k}_VERDICT"))"
      else
        set_state "$run" "R${k}_STATE" failed
        set_state "$run" "R${k}_VERDICT" none
        failed_ids="$failed_ids R$k"
        log "R$k call failed or timed out (rc=$rc); it will be retried next round"
      fi
    done
    CHILD_PIDS=""

    if [ "$ok" = 0 ]; then
      log "every reviewer failed this round"
      set_state "$run" STATUS failed
      exit 1
    fi
    if [ "$ok" = "$nrev" ] && [ "$approved" = "$nrev" ]; then
      log "=== converged: all $nrev reviewer(s) approved at round $r ==="
      set_state "$run" VERDICT approve
      set_state "$run" STATUS converged
      exit 0
    fi
    set_state "$run" VERDICT "changes-required (approved $approved/$nrev${failed_ids:+, failed:$failed_ids})"

    local note=""
    [ -n "$failed_ids" ] && note="(Reviewer(s)$failed_ids failed this round and have no review; they re-review next round.)"$'\n'

    log "=== round $r/$ROUNDS : $(agent_label A) revising ==="
    prev_sum="$(cksum < "$sol")"
    if ! run_author "$run" \
        "$(build_revise_prompt "$sol" "$review_list" "$r" "$ROUNDS" "$task" "$WORKDIR" "$note")" \
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
  if [ -n "${REVIEWERS:-}" ]; then
    echo "author   : $(agent_label A)$(subs_desc A)    context dir: $WORKDIR"
    local k
    for k in $(seq 1 "$REVIEWERS"); do
      printf '  %-40s verdict=%-17s call=%s\n' "$(agent_label "R$k")$(subs_desc "R$k")" \
        "$(get_state "$run" "R${k}_VERDICT")" "$(get_state "$run" "R${k}_STATE")"
    done
  else
    echo "author   : $AUTHOR    context dir: $WORKDIR"
  fi
  echo "started  : $STARTED"
  echo "artifacts: $run"
  [ -f "$run/solution.md" ] && echo "solution : $(wc -l < "$run/solution.md") lines"
  [ -s "$run/dissent.md" ] && echo "dissent  : unresolved disagreements recorded - read $run/dissent.md"
  echo "--- last 15 log lines ---"
  tail -15 "$run/loop.log" 2>/dev/null
}

cmd_list() {
  if [ ! -d "$RUNS_DIR" ]; then echo "no runs yet"; return 0; fi
  printf '%-26s %-14s %-6s %-4s %s\n' RUN STATUS ROUND REVS CONTEXT_DIR
  local d r
  for d in $(ls -1t "$RUNS_DIR" 2>/dev/null); do
    r="$RUNS_DIR/$d"
    [ -f "$r/meta.env" ] || continue
    printf '%-26s %-14s %-6s %-4s %s\n' "$d" "$(get_state "$r" STATUS)" \
      "$(get_state "$r" ROUND)" "$(grep '^REVIEWERS=' "$r/meta.env" | cut -d= -f2- || true)" \
      "$(grep '^WORKDIR=' "$r/meta.env" | cut -d= -f2-)"
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
  # catch the agent CLIs themselves - killing only the worker leaves them running.
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
