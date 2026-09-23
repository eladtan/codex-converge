---
name: codex-converge
description: Run a detached Claude-vs-Codex convergence loop - two read-only agents draft, review and revise a written solution until the reviewer approves or they deadlock. Use when the user wants Claude and Codex to review each other, argue toward agreement, iterate until they agree, or run a long unattended review loop that must survive SSH disconnect.
argument-hint: "<task to converge on> [rounds=N] [dir=PATH]"
allowed-tools: "Bash, Read, Glob, Grep"
---

# codex-converge

Drives a two-agent loop: one agent writes a solution, the other reviews it, the
author revises, repeat until the reviewer approves or the loop deadlocks. The
deliverable is a document, not a code change.

The driver is `converge.sh`, in this skill's directory.

## Safety model - do not weaken this

Both agents run **strictly read-only**:

- `claude` is invoked with `--allowed-tools Read Glob Grep` - no Write, no Edit, no Bash.
- `codex` is invoked with `-s read-only`.

Neither can modify anything in the user's project. Every file the loop produces
is written by `converge.sh` itself, into `~/.codex-converge/runs/<id>/`. This is
what makes an unattended, disconnected loop safe to leave running: the worst
case is a bad document in a scratch directory, never a mangled repo.

Never add `--permission-mode acceptEdits`, `-s workspace-write`,
`--dangerously-bypass-approvals-and-sandbox`, or similar to these invocations.
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
| `--author claude\|codex` | who writes; the other reviews | claude |
| `--codex-model M` | Codex model slug, e.g. `gpt-6-astra` | ~/.codex/config.toml |
| `--codex-effort E` | Codex reasoning effort: low\|medium\|high\|xhigh\|max | config |
| `--codex-tier T` | Codex service tier, e.g. `fast` (passed as `-c service_tier="T"`; 1.2.2) | config |
| `--claude-model M` | Claude model alias for the Claude side, e.g. `opus` | CLI default |
| `--fresh-context` | new context every call instead of one session per agent | off |
| `--foreground` | run inline, debugging only | off |

Write a **self-contained** task. Each agent invocation is a fresh process with
no memory of this conversation - "fix the bug we discussed" means nothing to it.
Expand the task before passing it.

Raise `--rounds` past 4 only if asked. Convergence, when it happens, almost
always happens by round 3; past that the models mostly agree more politely.
Each round is two full agent runs against both Anthropic and OpenAI quota.

## Persistent context (1.2.0)

By default each agent keeps one conversation for the whole run: the first call starts a session (Claude
`--session-id`, Codex `--json` to capture the thread id), and every later round resumes it (Claude `--resume`,
Codex `codex exec resume` with `sandbox_mode="read-only"` forced, since resume has no `-s` flag). Resumed prompts
tell the agent to re-read only the files that changed. This saves the re-reading of evidence each round.
`--fresh-context` restores the old behaviour (every call a new process with no memory). Session ids are stored in
the run directory as `.claude_session` / `.codex_session`. The reviewer still re-checks the revised solution; it
simply remembers what it verified before.

## Checking on a run

```bash
"$SKILL_DIR/converge.sh" status    # state, round, verdict, last log lines
"$SKILL_DIR/converge.sh" list      # every run, newest first
"$SKILL_DIR/converge.sh" show      # the current solution
"$SKILL_DIR/converge.sh" stop      # terminate the loop
```

With no run id these act on the most recent run. `watch` tails the log - never
call it from a tool, it does not exit. Use `status`.

When asked how a run is going: call `status`, read the newest `review-N.md`,
and summarize where the two agents currently disagree.

## Artifacts

`~/.codex-converge/runs/<id>/`

| File | Contents |
|---|---|
| `solution.md` | the current draft - the deliverable |
| `review-N.md` | each round's review, ending in a `VERDICT:` line |
| `dissent.md` | points the author refused to concede, with reasoning |
| `changelog.md` | what changed each round and what was rejected |
| `loop.log` | timestamped run log |
| `meta.env`, `state.env` | run config and live state |

## Terminal states

| `status` | Meaning |
|---|---|
| `converged` | reviewer returned `VERDICT: APPROVE` |
| `max-rounds` | hit the cap still disagreeing - the open objections in the last review are real |
| `stalled` | two rounds with no change to the solution; usually a genuine deadlock |
| `failed` | a CLI call errored or timed out - check `loop.log` |
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
