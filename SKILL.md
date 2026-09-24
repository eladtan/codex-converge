---
name: codex-converge
description: Run a detached Claude-vs-Codex convergence loop - a read-only author and a panel of one or more read-only reviewers (optionally with parallel subagents) draft, review and revise a written solution until every reviewer approves or they deadlock. Use when the user wants Claude and Codex to review each other, argue toward agreement, iterate until they agree, or run a long unattended review loop that must survive SSH disconnect.
argument-hint: "<task to converge on> [rounds=N] [dir=PATH] [subagents=N] [reviewers=...]"
allowed-tools: "Bash, Read, Glob, Grep"
---

# codex-converge

Drives a review loop: one agent writes a solution, a panel of one or more reviewers
(default: one, the other CLI) critiques it in parallel, the author revises, repeat until
every reviewer approves or the loop deadlocks. The
deliverable is a document, not a code change.

The driver is `converge.sh`, in this skill's directory.

## Safety model - do not weaken this

Every agent, and every subagent, runs **strictly read-only**:

- `claude` is invoked with `--strict-mcp-config --allowed-tools Read Glob Grep` - no Write,
  no Edit, no Bash, no MCP connector tools.
- With Claude subagents on, it also gets `--tools "Read,Glob,Grep,Agent"` (no other tool
  exists in the process), `--disallowed-tools "Bash Write Edit NotebookEdit"`, and one custom
  subagent, `reader`, whose tool list is Read/Glob/Grep - it cannot spawn further subagents.
  Live-tested 2026-09-24: parent, `general-purpose` and `reader` subagents all failed to write.
- `codex` is invoked with `-s read-only` (resume: `sandbox_mode="read-only"` forced). Codex
  subagents inherit that sandbox: live-tested 2026-09-24 on codex-cli 0.155.1, a sub-agent's
  patch was rejected by the read-only sandbox. `agents.max_depth=1` stops sub-sub-agents.

Neither can modify anything in the user's project. Every file the loop produces
is written by `converge.sh` itself, into `~/.codex-converge/runs/<id>/`. This is
what makes an unattended, disconnected loop safe to leave running: the worst
case is a bad document in a scratch directory, never a mangled repo.

Never add `--permission-mode acceptEdits`, `-s workspace-write`,
`--dangerously-bypass-approvals-and-sandbox`, or similar to these invocations, and never give
the `reader` subagent or the `--tools` list a write-capable tool. After a CLI upgrade, re-run
the subagent write test before trusting the sandbox notes above.
If the user wants the agreed solution applied to their code, show them
`solution.md` and let them apply it in a normal supervised session.

## Starting a run

Never run the loop in the foreground and never wait for it to finish. Start it,
report the run id, hand control back.

```bash
SKILL_DIR=~/.claude/skills/codex-converge
"$SKILL_DIR/converge.sh" start --task "<the task>" --dir "<project dir>" --rounds 4
```

| Flag | Meaning | Default |
|---|---|---|
| `--task "<text>"` | what to converge on (or `--task-file FILE`) | required |
| `--dir DIR` | directory the agents read for context, never written | cwd |
| `--rounds N` | max review rounds | 4 |
| `--author claude\|codex` | who writes; without `--reviewer`, the other CLI reviews | claude |
| `--reviewer SPEC` | add a panel reviewer (repeatable, max 6, warns above 3); see below | one reviewer, the other CLI |
| `--codex-model M` | Codex model slug, e.g. `gpt-6-astra` | ~/.codex/config.toml |
| `--codex-effort E` | Codex reasoning effort: low\|medium\|high\|xhigh\|max | config |
| `--codex-tier T` | Codex service tier, e.g. `fast` (passed as `-c service_tier="T"`; 1.2.2) | config |
| `--claude-model M` | Claude model alias for the Claude side, e.g. `opus` | CLI default |
| `--claude-effort E` | Claude effort (`--effort`): low\|medium\|high\|xhigh\|max; 1.2.3 | the calling agent's effort (`$CLAUDE_EFFORT`) |
| `--claude-subagents N` | each Claude agent may use up to N parallel read-only subagents (**soft cap**: prompt-enforced; 0 = none) | unset = none |
| `--codex-subagents N` | each Codex agent capped at N parallel subagents (**hard cap**: `agents.max_threads`, `max_concurrent_threads_per_session` = N, `max_depth` = 1); `0` = `--disable multi_agent` | unset = `~/.codex/config.toml` untouched |
| `--subagents N` | shorthand for both; per-side flags win | unset |
| `--fresh-context` | new context every call instead of one session per agent | off |
| `--foreground` | run inline, debugging only | off |

Write a **self-contained** task. Each agent invocation is a fresh process with
no memory of this conversation - "fix the bug we discussed" means nothing to it.
Expand the task before passing it.

For speed: `--subagents N` parallelises evidence reading inside each call, and a panel
runs the reviewers at the same time, so a round costs the slowest reviewer, not the sum.
Caps are per agent: worst case at once is the sum of (1 + N) over the reviewers; `start`
prints it. Subagents start with empty context, so the prompt tells agents to use them only
for reading they have not done yet - the persistent sessions carry the rest.

Raise `--rounds` past 4 only if asked. Convergence, when it happens, almost
always happens by round 3; past that the models mostly agree more politely.
Each round is two full agent runs against both Anthropic and OpenAI quota.

## Reviewer panel (1.4.0)

`--reviewer "cli=codex,model=gpt-6-astra,effort=high,tier=fast,subagents=4,focus=numerical stability"`

- Comma-separated `key=value`; `cli=` is required. `model`, `effort`, `tier` (codex only),
  `subagents` fall back to the side-wide flags. `focus=` must be last and takes the rest of the
  string (commas allowed). A reviewer may use the same CLI as the author.
- Ids: author `A`, reviewers `R1..RK` in flag order. All reviewers run in parallel and every
  reviewer reviews every round, including ones that approved before.
- **Converged** = every reviewer returned a review this round AND every one says APPROVE. A
  reviewer that errors or times out is logged, the round continues with the others, and it is
  retried next round; a round with a failed reviewer can revise but never converge. Only when
  every reviewer fails in one round does the run fail.
- The author sees all reviews headed by reviewer id, answers every [BLOCKER]/[MAJOR] by id, and
  records a contradiction between reviewers in `dissent.md` as `[R1 vs R2]`.
- Reviewers see the solution, `changelog.md` and `dissent.md`, never each other's raw reviews,
  so they stay independent. A reviewer with a focus reviews only that aspect.

## Persistent context (1.2.0)

By default each agent keeps one conversation for the whole run: the first call starts a session (Claude
`--session-id`, Codex `--json` to capture the thread id), and every later round resumes it (Claude `--resume`,
Codex `codex exec resume` with `sandbox_mode="read-only"` forced, since resume has no `-s` flag). Resumed prompts
tell the agent to re-read only the files that changed. This saves the re-reading of evidence each round.
`--fresh-context` restores the old behaviour (every call a new process with no memory). Session ids are stored in
the run directory per agent id as `.claude_session.<id>` / `.codex_session.<id>` (1.4.0; e.g.
`.claude_session.A`, `.codex_session.R2`), so every panel reviewer keeps its own conversation. The reviewer still re-checks the revised solution; it
simply remembers what it verified before.

## Checking on a run

```bash
"$SKILL_DIR/converge.sh" status    # state, round, per-reviewer verdict + call state, last log lines
"$SKILL_DIR/converge.sh" list      # every run, newest first
"$SKILL_DIR/converge.sh" show      # the current solution
"$SKILL_DIR/converge.sh" stop      # terminate the loop
```

With no run id these act on the most recent run. `watch` tails the log - never
call it from a tool, it does not exit. Use `status`.

When asked how a run is going: call `status`, read the newest `review-N-R<k>.md` files,
and summarize where the author and each reviewer currently disagree.

## Artifacts

`~/.codex-converge/runs/<id>/`

| File | Contents |
|---|---|
| `solution.md` | the current draft - the deliverable |
| `review-N-R<k>.md` | reviewer k's review in round N, ending in a `VERDICT:` line (pre-1.4.0 runs: `review-N.md`) |
| `dissent.md` | points the author refused to concede, with reasoning |
| `changelog.md` | what changed each round and what was rejected |
| `loop.log` | timestamped run log |
| `meta.env`, `state.env` | run config and live state |

## Terminal states

| `status` | Meaning |
|---|---|
| `converged` | every reviewer returned `VERDICT: APPROVE` in the same round |
| `max-rounds` | hit the cap still disagreeing - the open objections in the last review are real |
| `stalled` | two rounds with no change to the solution; usually a genuine deadlock |
| `failed` | the author call, or every reviewer in one round, errored or timed out - check `loop.log` |
| `stopped` | terminated by `stop` or a signal |

**Always read `dissent.md` when reporting results, even on `converged`.** A
converged run with a non-empty dissent file means they agreed on everything
*except* those points - that residue is usually the most interesting output.

Do not report `converged` as "the answer is correct". It means one model
stopped objecting. Report what they converged on and what stayed contested.

## How convergence is forced

Worth knowing before tuning the prompts in `converge.sh`:

- The reviewer must end with `VERDICT: APPROVE` or `VERDICT: CHANGES_REQUIRED`.
  A greppable token makes termination detectable; prose never is.
- Issues are tagged `[BLOCKER]` / `[MAJOR]` / `[NIT]`; only the first two gate
  convergence, otherwise the loop bikesheds forever.
- The reviewer is told that approving is valid and not to invent work. Without
  that, a reviewer model always finds something.
- The author is told not to capitulate on points it believes are right, and to
  record refusals in the DISSENT section instead.
- Each round feeds the reviewer `changelog.md` and `dissent.md` so it stops
  re-raising settled points. Every agent call is a fresh process with no memory
  - those files are the loop's memory.
- A stall detector ends the run when two consecutive rounds leave the solution
  byte-identical.

## Detachment

The worker is launched with `setsid` + `nohup`, stdio redirected to files, so
it has no controlling terminal. Dropping SSH, closing the shell, or logging out
does not kill it. Reconnect later and run `status`.

Where `setsid` is missing (Git Bash on Windows) it falls back to `nohup` +
`disown`.

## Relationship to the bridge

This skill drives the `claude` and `codex` CLIs directly rather than the
claude-codex-bridge MCP tools, because the bridge blocks nested calls at
`BRIDGE_DEPTH >= 2` - an agent reached through the bridge cannot call back.
Two top-level processes side-step that, and detaching is what survives a
disconnect.

For a single quick second opinion, use the `/codex` skill instead. This one is
for long unattended runs.

## Requirements

`claude` and `codex` on `PATH` and authenticated. `converge.sh` resolves both
to absolute paths at start and records them in `meta.env`, so the detached
worker does not need a login shell.

## Editing converge.sh while loops run
Running loops are bash processes reading `converge.sh` incrementally. Never edit it in place while a run is
alive: write the new version to a separate file and `mv` it over (atomic rename; running loops keep the old inode).
