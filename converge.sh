#!/usr/bin/env bash
# codex-converge - detached Claude <-> Codex <-> Gemini convergence loop.
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
#   - agy (1.5.0; Gemini through the Antigravity CLI) has no usable sandbox where user namespaces
#     are disabled, so it gets three independent layers: --mode plan, --settings forcing the
#     request-review policy with deny rules (headless -p runs refuse anything not permitted), and
#     a PreToolUse hook generated per run that denies every tool except read_file under the
#     context and run dirs. The hook matters because global allow rules in
#     ~/.gemini/config/config.json would otherwise still auto-approve the commands they name.
#     agy runs with its cwd in an empty per-agent workspace inside the run directory. No agy
#     subagents. Live-tested 2026-11-01 on agy 1.4.12: write_file, edit_file and run_command
#     (ls, touch, a nested agy) were all refused and the context dir was left untouched.
# No agent can modify the user's project. Every file written by this loop
# is written by THIS SCRIPT, into the run directory under ~/.codex-converge.
#
# Persistent context (1.2.0, default on; --fresh-context turns it off): each agent keeps ONE
# conversation for the whole run. Claude: --session-id on its first call, --resume after.
# Codex: first call with --json to capture the thread id, then `codex exec resume` with
# sandbox_mode="read-only" forced on every resumed call (resume has no -s flag).
# agy: first call prints --output-format json, whose conversation_id is resumed with --conversation.
# 1.4.0: session files are per agent id (.claude_session.A, .codex_session.R2, .agy_session.R3, ...).
# 1.5.1: agy compacts a long conversation into a summary (a CHECKPOINT step in its transcript). A
# resumed agy agent whose last turn compacted is told to re-read its evidence, not to rely on it.
# 1.5.2: stop (and the worker's TERM/INT trap) also kills the run's agent calls by their timeout
# process groups; a group kill of the worker missed them and left the CLIs running.
#
# Reviewer panel (1.4.0): one author (id A) and 1..6 reviewers (R1..RK) that review in
# parallel. Converged = every reviewer returned a review this round AND every one approved.
# 1.5.0: --trio makes the two CLIs other than the author the panel; --crosstalk shows each
# reviewer the other reviewers' previous-round reviews from round 2 on.
#
# The worker runs in its own session with stdio redirected to files, so it
# never needs a controlling terminal and survives SSH disconnect / logout.
#
#   converge.sh start --task "..." [--rounds N] [--dir DIR] [--author claude|codex|agy] [--reviewer SPEC]... [--trio] [--crosstalk]
#   converge.sh status [RUN] | watch [RUN] | show [RUN] | list | stop [RUN]

set -uo pipefail

VERSION="1.5.2"
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
STATE_ROOT="${CODEX_CONVERGE_HOME:-$HOME/.codex-converge}"
RUNS_DIR="$STATE_ROOT/runs"
DEFAULT_ROUNDS=4
MAX_REVIEWERS=6
CALL_TIMEOUT="${CODEX_CONVERGE_CALL_TIMEOUT:-1800}"
CLIS="claude codex agy"
DEFAULT_AGY_MODEL="${CODEX_CONVERGE_AGY_MODEL:-gemini-4-argon}"
# Where agy 1.4.12 keeps each conversation's transcript: BRAIN/<conversation_id>/.system_generated/logs/.
AGY_BRAIN="${CODEX_CONVERGE_AGY_BRAIN:-$HOME/.gemini/antigravity-cli/brain}"

# The only agy tool the PreToolUse guard lets through, and only for paths under the context dir or
# the run dir. agy 1.4.12 headless has no list/search tool: read_file is its one reader.
AGY_READ_TOOLS="read_file"
# Per-call agy settings, never saved: the review policy (workspace reads auto-granted, anything else
# needs an approval nobody can give headless) plus deny rules for commands, writes, MCP and network.
# Not "strict": it refuses read_file too. A policy refusal ends a headless turn mid-reply, which is
# why the guard refuses first, as a tool error the agent can read and continue past.
AGY_SETTINGS='{"toolPermission":"request-review","permissions":{"deny":["command(*)","write_file(*)","write_file(/)","mcp(*)","read_url(*)","execute_url(*)"]}}'

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

# run_calls RUN - pids of RUN's live agent calls, found by the `timeout` wrapper of each call, whose
# arguments name the run dir (--add-dir RUN for claude and agy, -o RUN/... for codex). Found by name,
# not by tree: once its parent subshell dies, the wrapper is reparented to init.
run_calls() {
  ps -ef 2>/dev/null | awk -v id="$(basename "$1")" \
    'NR > 1 && $8 ~ /(^|\/)timeout$/ && match($0, "/" id "(/| |$)") {print $2}'
}

# kill_calls RUN - TERM, then KILL, every agent call of RUN with everything it started. GNU timeout
# runs in a process group of its own, which a TERM to the worker's group never reaches, so each
# call's group is signalled directly (a wrapper that does not lead its own group gets kill_tree).
kill_calls() {
  local p pg calls i=0
  calls="$(run_calls "$1")"
  [ -n "$calls" ] || return 0
  for p in $calls; do
    pg="$(ps -o pgid= -p "$p" 2>/dev/null | tr -d ' ')"
    if [ "$pg" = "$p" ]; then kill -TERM -- "-$p" 2>/dev/null; else kill_tree "$p"; fi
  done
  while [ "$i" -lt 5 ] && [ -n "$(run_calls "$1")" ]; do sleep 1; i=$((i + 1)); done
  # KILL a group only while it still has members: until the last one exits its id cannot be reused.
  for p in $calls; do
    ps -eo pgid= 2>/dev/null | awk -v g="$p" '$1 == g {f = 1} END {exit !f}' && kill -KILL -- "-$p" 2>/dev/null
  done
}

usage() {
  cat <<U
codex-converge - run a Claude <-> Codex <-> Gemini (agy) review loop until they agree.

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
  --author claude|codex|agy  who writes (default claude); without --reviewer or --trio one other
                          CLI reviews: codex for a claude author, claude otherwise
  --reviewer SPEC         add a reviewer to the panel (repeatable, max 6). SPEC is comma-separated
                          key=value: cli=claude|codex|agy (required), model=, effort=, tier= (codex),
                          subagents=N (not agy), focus=<text> (focus must be LAST; it takes the rest).
                          Omitted fields fall back to the side-wide flags below.
  --trio                  the panel is the two CLIs other than the author (e.g. claude writes,
                          codex and agy review); cannot be combined with --reviewer
  --crosstalk             from round 2, each reviewer also reads the other reviewers' reviews
                          from the previous round and may endorse or dispute their points
  --agy-model M           agy (Gemini) model (default: $DEFAULT_AGY_MODEL)
  --agy-effort E          agy effort, e.g. low|medium|high for argon (default: the model's default)
  --codex-model M         codex model slug (default: ~/.codex/config.toml)
  --codex-effort E        codex reasoning effort: low|medium|high|xhigh|max
  --codex-tier T          codex service tier, e.g. fast|flex|default (default: ~/.codex/config.toml)
  --claude-model M        claude model for the claude side (default: CLI default)
  --claude-effort E       claude effort: low|medium|high|xhigh|max (default: the calling agent's
                          effort, from \$CLAUDE_EFFORT when started inside Claude Code)
  --claude-subagents N    let each claude agent use up to N parallel read-only subagents
                          (prompt-enforced cap; 0 = none, same as unset)
  --codex-subagents N     cap each codex agent at N parallel subagents (hard cap via config);
                          0 = disable codex multi_agent; unset = leave ~/.codex/config.toml alone
  --subagents N           shorthand for both (per-side flags win); agy agents never get subagents
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
  local author="claude" foreground=0 trio=0 crosstalk=0
  local codex_model="" codex_effort="" codex_tier="" claude_model="" claude_effort="${CLAUDE_EFFORT:-}" persist=1
  local agy_model="$DEFAULT_AGY_MODEL" agy_effort=""
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
      --trio)       trio=1; shift ;;
      --crosstalk)  crosstalk=1; shift ;;
      --agy-model)  agy_model="${2:-}"; shift 2 ;;
      --agy-effort) agy_effort="${2:-}"; shift 2 ;;
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
  case "$agy_effort" in ""|low|medium|high|xhigh|max) ;; *) die "bad --agy-effort: $agy_effort" ;; esac
  [ -z "$claude_subs" ] && claude_subs="$both_subs"
  [ -z "$codex_subs" ] && codex_subs="$both_subs"

  if [ -n "$task_file" ]; then
    [ -f "$task_file" ] || die "no such file: $task_file"
    task="$(cat "$task_file")"
  fi
  [ -n "$task" ] || die "--task or --task-file is required"
  case "$author" in claude|codex|agy) ;; *) die "--author must be claude, codex or agy" ;; esac
  case "$rounds" in ''|*[!0-9]*) die "--rounds must be a number" ;; esac
  [ -d "$workdir" ] || die "no such directory: $workdir"
  workdir="$(cd "$workdir" && pwd)"

  local c
  if [ "$trio" = 1 ]; then
    [ "${#reviewer_specs[@]}" -eq 0 ] || die "--trio sets the panel itself; drop it or the --reviewer flags"
    for c in $CLIS; do [ "$c" = "$author" ] || reviewer_specs+=("cli=$c"); done
  fi
  # Default panel: one reviewer, the other CLI (the pre-1.4.0 loop); claude reviews an agy author.
  if [ "${#reviewer_specs[@]}" -eq 0 ]; then
    if [ "$author" = claude ]; then reviewer_specs=("cli=codex"); else reviewer_specs=("cli=claude"); fi
  fi
  local nrev="${#reviewer_specs[@]}"
  [ "$nrev" -le "$MAX_REVIEWERS" ] || die "at most $MAX_REVIEWERS reviewers (got $nrev)"
  [ "$nrev" -gt 3 ] && echo "converge: warning: $nrev reviewers - past ~3 the author's answers to each review get thinner" >&2

  # Resolve every agent to concrete fields: ID_CLI ID_MODEL ID_EFFORT ID_TIER ID_SUBS ID_FOCUS.
  local -a agent_lines=()
  side_defaults() {  # side_defaults CLI -> sets d_model d_effort d_tier d_subs
    case "$1" in
      claude) d_model="$claude_model"; d_effort="$claude_effort"; d_tier=""; d_subs="$claude_subs" ;;
      codex)  d_model="$codex_model"; d_effort="$codex_effort"; d_tier="$codex_tier"; d_subs="$codex_subs" ;;
      agy)    d_model="$agy_model"; d_effort="$agy_effort"; d_tier=""; d_subs="" ;;
    esac
  }
  local used_clis=" "
  emit_agent() {  # emit_agent ID CLI MODEL EFFORT TIER SUBS FOCUS
    local f n=0
    used_clis="$used_clis$2 "
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
    case "$cli" in claude|codex|agy) ;; *) die "--reviewer $k: cli=claude, cli=codex or cli=agy is required" ;; esac
    side_defaults "$cli"
    [ "$set_model" = 1 ]  || model="$d_model"
    [ "$set_effort" = 1 ] || effort="$d_effort"
    [ "$set_tier" = 1 ]   || tier="$d_tier"
    [ "$set_subs" = 1 ]   || subs="$d_subs"
    if [ "$cli" != codex ]; then
      case "$effort" in ""|low|medium|high|xhigh|max) ;; *) die "--reviewer $k: bad $cli effort: $effort" ;; esac
      [ -n "$tier" ] && die "--reviewer $k: tier= applies to codex only"
    fi
    if [ "$cli" = agy ] && [ -n "$subs" ] && [ "$subs" != 0 ]; then
      die "--reviewer $k: agy agents run without subagents (their read-only guard is not verified for subagents)"
    fi
    emit_agent "R$k" "$cli" "$model" "$effort" "$tier" "$subs" "$focus"
  done

  # Resolve only the CLIs this panel uses; agy also needs jq or python3 to read its JSON output.
  local claude_bin="" codex_bin="" agy_bin="" json_tool=""
  case "$used_clis" in *" claude "*) claude_bin="$(command -v claude || true)"; [ -n "$claude_bin" ] || die "claude CLI not found on PATH" ;; esac
  case "$used_clis" in *" codex "*)  codex_bin="$(command -v codex || true)";   [ -n "$codex_bin" ]  || die "codex CLI not found on PATH" ;; esac
  case "$used_clis" in *" agy "*)
    agy_bin="$(command -v agy || true)"
    [ -z "$agy_bin" ] && [ -x "$HOME/.gemini/bin/agy" ] && agy_bin="$HOME/.gemini/bin/agy"
    [ -n "$agy_bin" ] || die "agy CLI not found on PATH or in ~/.gemini/bin"
    if command -v jq >/dev/null 2>&1; then json_tool="$(command -v jq)"
    elif command -v python3 >/dev/null 2>&1; then json_tool="$(command -v python3)"
    else die "agy agents need jq or python3 to read agy's JSON output"; fi
    ;;
  esac

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
    echo "AGY_BIN=$agy_bin"
    echo "JSON_TOOL=$json_tool"
    echo "AGY_MODEL=$agy_model"
    echo "AGY_EFFORT=$agy_effort"
    echo "CROSSTALK=$crosstalk"
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
    [ "$REVIEWERS" -gt 1 ] && echo "  crosstalk: $([ "$CROSSTALK" = 1 ] && echo "on (from round 2 each reviewer reads the others' previous reviews)" || echo 'off (reviewers stay independent)')"
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
    case "$used_clis" in *" agy "*) echo "  agy guard: --mode plan + request-review policy with deny rules + PreToolUse hook allowing only $AGY_READ_TOOLS under the context and run dirs" ;; esac
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

compacted_note() {  # compacted_note WHEN - the resume note for an agent whose conversation was summarised
  cat <<N
[Continuing your earlier session in this loop, but your conversation $1, so treat what you
remember of earlier rounds as a summary, not the text itself. Re-read the files named below, and
re-read the evidence your reply depends on (the code, data or documents it cites) before relying on
it. Check an earlier finding against the files before you repeat or withdraw it.]
N
}

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

shell_quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }  # STRING as one single-quoted shell word
jesc() { printf '%s' "$1" | sed 's/[\\"]/\\&/g'; }                    # STRING escaped for a JSON string

# agy_guard RUN WS - write the run's PreToolUse guard and the agent workspace's hooks.json.
# The guard only ever denies: a tool it lets through still faces agy's own policy, so a payload
# it cannot parse ends in a denial, never in a grant. Paths are compared lexically (realpath -s)
# against the logical and physical forms of the context dir and the run dir.
agy_guard() {
  local run="$1" ws="$2" guard="$1/.agy-guard.sh" get_name get_path r pat=""
  if [ ! -x "$guard" ]; then
    case "$(basename "$JSON_TOOL")" in
      jq) get_name="$(shell_quote "$JSON_TOOL") -r '.toolCall.name // empty'"
          get_path="$(shell_quote "$JSON_TOOL") -r '.toolCall.args.Path // empty'" ;;
      *)  get_name="$(shell_quote "$JSON_TOOL") -I -c 'import json,sys; print((json.load(sys.stdin).get(\"toolCall\") or {}).get(\"name\") or \"\")'"
          get_path="$(shell_quote "$JSON_TOOL") -I -c 'import json,sys; print(((json.load(sys.stdin).get(\"toolCall\") or {}).get(\"args\") or {}).get(\"Path\") or \"\")'" ;;
    esac
    for r in "$WORKDIR" "$(cd "$WORKDIR" && pwd -P)" "$run" "$(cd "$run" && pwd -P)"; do
      pat="$pat${pat:+|}$(shell_quote "$r")|$(shell_quote "$r")/*"
    done
    local deny_tool deny_path
    deny_tool="{\"decision\":\"deny\",\"reason\":\"codex-converge: this agent is read-only and its only tool is read_file. No commands, edits, searches or subagents. Print your answer as your reply instead.\"}"
    deny_path="{\"decision\":\"deny\",\"reason\":\"codex-converge: read_file is limited to absolute paths under $(jesc "$WORKDIR") and $(jesc "$run").\"}"
    cat > "$guard.tmp" <<G
#!/bin/sh
# codex-converge PreToolUse guard for agy agents: refuse every tool except read_file under the
# context dir or the run dir. It never grants: what it lets through still faces agy's own policy.
payload="\$(cat)"
name="\$(printf '%s' "\$payload" | $get_name 2>/dev/null)"
case " $AGY_READ_TOOLS " in *" \$name "*) [ -n "\$name" ] ;; *) false ;; esac || { printf '%s\n' $(shell_quote "$deny_tool"); exit 0; }
path="\$(printf '%s' "\$payload" | $get_path 2>/dev/null)"
norm="\$(realpath -m -s -- "\$path" 2>/dev/null)"
[ -n "\$norm" ] || norm="\$path"
case "\$norm" in $pat) exit 0 ;; esac
printf '%s\n' $(shell_quote "$deny_path")
G
    chmod +x "$guard.tmp" && mv "$guard.tmp" "$guard" || return 1
  fi
  mkdir -p "$ws/.agents" || return 1
  local qguard; qguard="$(printf '%s' "$guard" | sed 's/[\\"]/\\&/g')"
  printf '{"codex-converge-guard":{"PreToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"%s","timeout":20}]}]}}\n' \
    "$qguard" > "$ws/.agents/hooks.json"
}

# agy_index RUN - list the context dir's files into the run dir, once: agy agents cannot list
# directories or search. Tracked files when the dir is in a git repo (git ls-files writes nothing),
# else a shallow find; untracked files are left out, as a big run tree would swamp the list.
agy_index() {
  local f="$1/agy-files.txt"
  [ -s "$f" ] && return 0
  {
    if git -C "$WORKDIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      echo "# Files tracked by git under $WORKDIR, relative to it (untracked files are not listed)."
      git -C "$WORKDIR" ls-files --recurse-submodules 2>/dev/null || git -C "$WORKDIR" ls-files 2>/dev/null
    else
      echo "# Files under $WORKDIR up to 4 levels deep, relative to it (hidden paths left out)."
      (cd "$WORKDIR" && find . -maxdepth 4 -type f -not -path '*/.*' 2>/dev/null | sed 's|^\./||' | sort)
    fi | head -n 20000
  } > "$f.tmp" && mv "$f.tmp" "$f"
}

agy_note() {  # agy_note RUN - the tool limits an agy agent works under
  cat <<N
[Tools: your only tool is read_file, and only for absolute paths under $WORKDIR or $1.
You cannot list directories, search, run commands or start subagents - those calls are refused.
To find files, read $1/agy-files.txt (a file list for $WORKDIR); also follow the paths
named in the task and the solution.]
N
}

# agy_json FILE KEY - a top-level field of agy's --output-format json result (last JSON object in
# FILE); arrays come back one element per line, objects as JSON, a missing key as nothing.
agy_json() {
  case "$(basename "$JSON_TOOL")" in
    jq) "$JSON_TOOL" -rs --arg k "$2" 'last | .[$k] // empty
          | if type == "array" then map(if type == "string" then . else tojson end) | join("\n")
            elif type == "string" then . else tojson end' "$1" 2>/dev/null ;;
    *)  "$JSON_TOOL" -I - "$1" "$2" 2>/dev/null <<'PY'
import json, sys
text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
dec, i, last = json.JSONDecoder(), 0, None
while True:
    while i < len(text) and text[i].isspace():
        i += 1
    if i >= len(text):
        break
    last, i = dec.raw_decode(text, i)
v = last.get(sys.argv[2]) if isinstance(last, dict) else None
if isinstance(v, list):
    print("\n".join(x if isinstance(x, str) else json.dumps(x) for x in v))
elif isinstance(v, str):
    print(v)
elif v is not None:
    print(json.dumps(v))
PY
    ;;
  esac
}

# agy_compacted CID - "yes" if agy compacted conversation CID during its latest turn (a CHECKPOINT step
# after the last USER_INPUT in its transcript), "no" if not, "unknown" if the transcript is missing or
# cannot be parsed.
agy_compacted() {
  local t="$AGY_BRAIN/$1/.system_generated/logs/transcript.jsonl" types
  [ -n "$1" ] && [ -s "$t" ] || { echo unknown; return 0; }
  case "$(basename "$JSON_TOOL")" in
    jq) types="$("$JSON_TOOL" -r '.type // empty' "$t" 2>/dev/null)" || { echo unknown; return 0; } ;;
    *)  types="$("$JSON_TOOL" -I - "$t" 2>/dev/null <<'PY'
import json, sys
for line in open(sys.argv[1], encoding="utf-8"):
    if line.strip():
        print(json.loads(line).get("type") or "")
PY
)" || { echo unknown; return 0; } ;;
  esac
  printf '%s\n' "$types" | awk '$0 == "USER_INPUT" {u = NR} $0 == "CHECKPOINT" {c = NR}
    END {if (!u) print "unknown"; else if (c > u) print "yes"; else print "no"}'
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

  # A compacted agy conversation holds a summary, not the evidence the plain resume note says it holds.
  local resume_note="$RESUME_NOTE"
  if [ "$resuming" = 1 ] && [ "$cli" = agy ]; then
    case "$(agy_compacted "$(cat "$sess_file")")" in
      no) ;;
      yes) resume_note="$(compacted_note "was compacted during your last turn")"
           log "$id agy: conversation was compacted during its last turn; told to re-read its evidence" ;;
      *)   resume_note="$(compacted_note "may have been compacted since your last turn")"
           log "$id agy: cannot read its transcript under $AGY_BRAIN to check for compaction; told to re-read its evidence" ;;
    esac
  fi

  {
    [ "$resuming" = 1 ] && printf '%s\n\n' "$resume_note"
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

  if [ "$cli" = agy ]; then
    # cwd is an empty per-agent workspace in the run dir: it carries the guard's hooks.json, and
    # anything agy keeps per workspace lands there, never in $WORKDIR.
    # No --disable-slash-commands: it switches --mode plan off. Prompts never start with "/".
    local ws="$run/.agy-ws.$id" res="$run/.agy-result.$id.json" ptimeout=$((CALL_TIMEOUT - 60))
    [ "$ptimeout" -lt 60 ] && ptimeout=60
    agy_guard "$run" "$ws" || { log "$id agy: could not write the read-only guard; refusing to call agy"; return 1; }
    agy_index "$run"
    { agy_note "$run"; echo; cat "$pfile"; } > "$pfile.agy" && mv "$pfile.agy" "$pfile"
    local -a g=(--mode plan --settings "$AGY_SETTINGS" --output-format json
                --print-timeout "${ptimeout}s" --add-dir "$WORKDIR" --add-dir "$run")
    [ -n "$model" ] && g+=(--model "$model")
    [ -n "$effort" ] && g+=(--effort "$effort")
    if [ "$resuming" = 1 ]; then
      g+=(--conversation "$(cat "$sess_file")")
      log "$id agy: resuming conversation $(cat "$sess_file")"
    fi
    # The prompt is one argv string, capped by the kernel at 128 KiB; a longer one is read from its file.
    local ptext
    if [ "$(wc -c < "$pfile")" -gt 100000 ]; then
      ptext="Your complete instructions for this turn are in $pfile. Read that whole file now and follow it exactly."
    else
      ptext="$(cat "$pfile")"
    fi
    ( cd "$ws" && exec timeout "$CALL_TIMEOUT" "$AGY_BIN" "${g[@]}" -p="$ptext" ) \
      < /dev/null > "$res" 2>> "$run/loop.log"
    rc=$?
    # A policy refusal (denied_actions) ends a headless turn mid-reply with status SUCCESS, so it
    # counts as a failed call: a cut-off reply must never become the solution or a review.
    local status reason denied
    status="$(agy_json "$res" status)"
    reason="$(agy_json "$res" finished_reason)"
    denied="$(agy_json "$res" denied_actions)"
    agy_json "$res" response > "$out"
    if [ "$rc" = 0 ] && [ -n "$denied" ]; then
      log "$id agy: agy's policy refused an action, which ended the turn early: $(printf '%s' "$denied" | tr '\n' ' ' | cut -c1-300)"
      rc=1
    elif [ "$rc" = 0 ] && { [ -n "$reason" ] || [ "$status" != SUCCESS ]; }; then
      log "$id agy: turn did not complete (status=${status:-none} finished_reason=${reason:-none})"
      rc=1
    fi
    if [ "$rc" = 0 ] && [ "${PERSIST:-0}" = 1 ] && [ ! -s "$sess_file" ]; then
      local cid; cid="$(agy_json "$res" conversation_id)"
      if [ -n "$cid" ]; then printf '%s\n' "$cid" > "$sess_file"; log "$id agy: conversation $cid"
      else log "$id agy: no conversation_id in its JSON; later calls start fresh"; fi
    fi
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
  local others="${11:-}"
  local panel="" scope="" talk=""
  [ "$nrev" -gt 1 ] && panel="You are reviewer $id of a panel of $nrev reviewing in parallel; you will not see the
others' reviews of this round, so review independently. Changelog and dissent entries may be tagged
with reviewer ids like [R2]."
  [ -n "$others" ] && talk="CROSSTALK - the other reviewers' reviews from round $((r - 1)); read them too:
$others
Weigh their points against the CURRENT solution: some may already be fixed. Where you checked a
point and agree, say so in one line tagged [AGREE Rk]. Where you think a point is wrong or
overstated, say why, tagged [DISPUTE Rk] - the author reads both and has to weigh it. Raise an
issue as your own only if you verified it yourself. Your verdict is yours alone."
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
$talk

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
  trap 'log "terminated by signal"; for p in $CHILD_PIDS; do kill_tree "$p"; done; kill_calls "$run"; set_state "$run" STATUS stopped; exit 143' TERM INT

  set_state "$run" STATUS running
  log "run $RUN_ID on $HOST (v${VERSION:-?}) : author=$(agent_label A) reviewers=$nrev rounds=$ROUNDS crosstalk=${CROSSTALK:-0}"
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

  local prev_sum="" cur_sum="" stalls=0 r=1 prev_failed=""
  while [ "$r" -le "$ROUNDS" ]; do
    set_state "$run" ROUND "$r"

    log "=== round $r/$ROUNDS : $nrev reviewer(s) reviewing in parallel ==="
    local -a pids=()
    CHILD_PIDS=""
    for k in $(seq 1 "$nrev"); do
      set_state "$run" "R${k}_STATE" reviewing
      # Crosstalk: the other reviewers' reviews from the previous round, minus calls that failed.
      local others="" j prevf
      if [ "${CROSSTALK:-0}" = 1 ] && [ "$r" -gt 1 ]; then
        for j in $(seq 1 "$nrev"); do
          prevf="$run/review-$((r - 1))-R$j.md"
          [ "$j" = "$k" ] && continue
          case "$prev_failed " in *" R$j "*) continue ;; esac
          [ -s "$prevf" ] && others="$others  $prevf  - review by $(agent_label "R$j")"$'\n'
        done
      fi
      spawn_agent "$run" "R$k" \
        "$(build_review_prompt "$sol" "$changelog" "$dissent" "$r" "$ROUNDS" "$task" "$WORKDIR" "R$k" "$nrev" "$(agent_field "R$k" FOCUS)" "$others")" \
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
    prev_failed="$failed_ids"

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
    [ "${CROSSTALK:-0}" = 1 ] && [ "$r" -gt 1 ] && note="$note(Reviewers read each other's previous reviews: [AGREE Rk] endorses Rk's point, [DISPUTE Rk] argues against it. Weigh both; a disputed point still needs your own decision.)"$'\n'

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

  local calls
  if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
    # The worker can be gone while calls it started live on (an older stop, a crash).
    calls="$(run_calls "$run" | wc -w | tr -d ' ')"
    if [ "$calls" -gt 0 ]; then
      kill_calls "$run"
      echo "no live worker for that run; killed $calls leftover agent call(s)"
    else
      echo "no live process for that run"
    fi
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
  # Only now, with the worker gone and unable to start another call, sweep the calls it left.
  calls="$(run_calls "$run" | wc -w | tr -d ' ')"
  kill_calls "$run"
  if kill -0 "$pid" 2>/dev/null; then
    echo "warning: pid $pid still alive after SIGKILL - check it by hand"
  else
    echo "stopped run $(basename "$run") (pid $pid and descendants; $calls agent call(s) outlived the worker and were killed)"
  fi
  [ -n "$(run_calls "$run")" ] && echo "warning: agent calls of this run are still alive - check them by hand"
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
