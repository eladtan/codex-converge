# codex-converge

A [Claude Code](https://claude.com/claude-code) skill that makes **Claude and OpenAI Codex review each other's work until they agree**.

One agent writes a solution, such as a plan, a design, a bug diagnosis or a patch proposal. The other agent reviews it, or a panel of several reviewers reviews it in parallel. The author revises and the loop repeats until one of these happens:

- every reviewer approves in the same round,
- the two agents deadlock, or
- the round cap is reached.

The loop runs **detached**, so it keeps going if you close your terminal or your SSH connection drops. Every agent, and every subagent it spawns, runs **strictly read-only**, so an unattended loop can never modify your project.

```
          ┌──────────── task ────────────┐
          ▼                              │
   author drafts ──► reviewer reviews ──► VERDICT: APPROVE ──► converged
          ▲                 │
          │     VERDICT: CHANGES_REQUIRED
          └──── author revises (or records dissent)
```

## Why

A single model reviewing its own work tends to agree with itself. Two different models from two different vendors catch different mistakes. The loop has a few rules that stop it from going around in circles:

- The reviewer must end with a greppable `VERDICT: APPROVE` or `VERDICT: CHANGES_REQUIRED`.
- Every issue is tagged `[BLOCKER]`, `[MAJOR]` or `[NIT]`. Only blockers and majors hold up convergence.
- The reviewer is told explicitly that approving is a valid outcome and that it should not invent work.
- The author is told **not** to give in on points it believes are right. It records those refusals in `dissent.md`, and the reviewer has to engage with that reasoning instead of repeating itself.
- A stall detector ends the run after two consecutive rounds that leave the solution byte-identical.

## Requirements

- **bash**, plus the standard coreutils (`timeout`, `nohup`, `awk`, `cksum`). `setsid` and `flock` are used when present. Tested on Linux. It should also work on macOS and on Git Bash for Windows (on Windows it falls back to `nohup` + `disown`).
- **[Claude Code CLI](https://docs.claude.com/en/docs/claude-code)** (`claude`) on your `PATH` and logged in.
- **[OpenAI Codex CLI](https://github.com/openai/codex)** (`codex`) on your `PATH` and logged in.

Check both:

```bash
claude --version && codex --version
```

## Install

Clone the repo straight into your personal Claude Code skills directory:

```bash
git clone https://github.com/eladtan/codex-converge.git ~/.claude/skills/codex-converge
```

To install it for a single project instead, clone it into that project's `.claude/skills/codex-converge`.

Restart Claude Code (or start a new session). `codex-converge` should then appear in the skill list.

### Update

```bash
git -C ~/.claude/skills/codex-converge pull
```

> Do not pull while a loop is running. Running loops read `converge.sh` incrementally, so rewriting the file in place can break them. Check with `converge.sh list` first.

### Uninstall

```bash
rm -rf ~/.claude/skills/codex-converge
```

Run artifacts live separately in `~/.codex-converge/`. Delete that directory too if you no longer want them.

## Usage

### From Claude Code (recommended)

Just ask. For example:

> Have Claude and Codex converge on a plan for migrating our auth middleware to the new session store. Read `src/auth/` for context.

> /codex-converge Review the retry logic in `worker/queue.py` and agree on the root cause of the duplicate-delivery bug. rounds=3

Claude expands your request into a self-contained task, starts the loop in the background, reports the run id and hands control back to you. Later, ask *"how is the converge run going?"* and Claude will check its status and summarize where the two agents still disagree.

### From the shell

```bash
S=~/.claude/skills/codex-converge/converge.sh

$S start --task "Propose a schema migration plan for ... (self-contained description)" \
         --dir ~/my-project --rounds 4

$S status          # state, round, per-reviewer verdicts, recent log lines
$S show            # print the current solution
$S list            # all runs, newest first
$S watch           # follow the log (Ctrl-C only stops watching)
$S stop            # terminate the loop
```

With no run id, `status`, `show`, `watch` and `stop` act on the most recent run.

### Options for `start`

| Flag | Meaning | Default |
|---|---|---|
| `--task "<text>"` | What to converge on. Use `--task-file FILE` for long tasks. | required |
| `--dir DIR` | Directory the agents read for context. It is never written to. | current dir |
| `--rounds N` | Maximum number of review rounds | 4 |
| `--author claude\|codex` | Which agent writes; without `--reviewer`, the other one reviews | `claude` |
| `--reviewer SPEC` | Add a reviewer to the panel (repeatable, up to 6). See [Reviewer panel](#reviewer-panel). | one reviewer, the other CLI |
| `--codex-model M` | Codex model slug | your `~/.codex/config.toml` |
| `--codex-effort E` | Codex reasoning effort: `low`, `medium`, `high`, `xhigh` or `max` | config |
| `--codex-tier T` | Codex service tier, e.g. `fast` | config |
| `--claude-model M` | Claude model alias, e.g. `opus` | CLI default |
| `--claude-effort E` | Claude effort: `low`, `medium`, `high`, `xhigh` or `max` | the calling agent's effort (`$CLAUDE_EFFORT`) |
| `--claude-subagents N` | Each Claude agent may use up to N parallel read-only subagents. **Soft cap**: enforced by the prompt only. `0` means none. | none |
| `--codex-subagents N` | Each Codex agent is capped at N parallel subagents. **Hard cap**, set through Codex config; subagents cannot spawn their own. `0` turns Codex subagents off. | your `~/.codex/config.toml` |
| `--subagents N` | Sets both of the above; the per-side flags win | unset |
| `--fresh-context` | Start a new context for every call instead of keeping one session per agent | off |
| `--foreground` | Run inline instead of detaching (for debugging) | off |

Environment variables:

- `CODEX_CONVERGE_HOME`: where runs are stored (default `~/.codex-converge`).
- `CODEX_CONVERGE_CALL_TIMEOUT`: per-agent-call timeout in seconds (default `1800`).

**Write a self-contained task.** Each agent is a separate process that knows nothing about your chat. A task like "fix the bug we discussed" means nothing to it.

**Cost:** each round is one author run plus one run per reviewer, billed against your Anthropic and OpenAI quotas. Subagents add more. When the agents converge, it is usually by round 3.

**Speed:** reviewers run at the same time, so a round takes as long as the slowest reviewer rather than the sum. `--subagents N` also lets each agent read evidence in parallel. Caps apply per agent, and `start` prints the worst-case number of agent processes running at once.

### Reviewer panel

```bash
$S start --task "..." --dir ~/my-project \
   --reviewer "cli=codex,model=gpt-6-astra,effort=high,subagents=4" \
   --reviewer "cli=claude,focus=numerical stability, units and edge cases"
```

- A spec is comma-separated `key=value`. `cli=claude|codex` is required. `model`, `effort`, `tier` (Codex only) and `subagents` fall back to the side-wide flags. `focus=` must come last and takes the rest of the string, commas included. A reviewer may use the same CLI as the author.
- The author is `A` and the reviewers are `R1..RK`, in flag order. Every reviewer reviews every round, including ones that approved earlier, because a revision can undo something they approved.
- **Converged** means every reviewer returned a review this round and every one says APPROVE.
- A reviewer that errors or times out is logged, the round continues without it, and it is retried next round. A round with a failed reviewer can still revise but cannot converge. The run fails only if every reviewer fails in the same round.
- The author sees all the reviews, headed by reviewer id, and answers every `[BLOCKER]`/`[MAJOR]` by id. When two reviewers contradict each other, the author picks one and records the other in `dissent.md` as `[R1 vs R2]`.
- Reviewers see the solution, `changelog.md` and `dissent.md`, but never each other's reviews, so they stay independent. A reviewer given a `focus` reviews only that aspect.
- Warns above 3 reviewers: past that, the author's answer to each review gets thinner.

## Output

Every run gets its own directory, `~/.codex-converge/runs/<id>/`:

| File | Contents |
|---|---|
| `solution.md` | The current draft. This is the deliverable. |
| `review-N-R<k>.md` | Reviewer k's review in round N, ending in a `VERDICT:` line (runs before 1.4.0: `review-N.md`) |
| `dissent.md` | Points the author refused to concede, with its reasoning |
| `changelog.md` | What changed each round and what was rejected |
| `loop.log` | Timestamped run log |
| `meta.env`, `state.env` | Run configuration and live state |

### Terminal states

| Status | Meaning |
|---|---|
| `converged` | Every reviewer returned `VERDICT: APPROVE` in the same round. |
| `max-rounds` | The cap was reached with the agents still disagreeing. The open objections in the last review are real. |
| `stalled` | Two rounds passed with no change to the solution. This is usually a genuine deadlock. |
| `failed` | The author call, or every reviewer in one round, errored or timed out. Check `loop.log`. |
| `stopped` | The run was ended by `stop` or by a signal. |

**Always read `dissent.md`, even when the run converged.** A non-empty dissent file means the agents agreed on everything *except* those points, and that leftover disagreement is often the most useful output. Also, `converged` does not mean "correct". It means the reviewer stopped objecting.

## Safety model

- `claude` runs with `--strict-mcp-config --allowed-tools "Read Glob Grep"`, which means no Write, no Edit, no Bash and no MCP connector tools.
- With Claude subagents on, it also gets `--tools "Read,Glob,Grep,Agent"` (no other tool exists in the process), `--disallowed-tools "Bash Write Edit NotebookEdit"`, and one custom subagent, `reader`, limited to Read, Glob and Grep, which cannot spawn further subagents.
- `codex` runs with `-s read-only`. Resumed sessions force `sandbox_mode="read-only"`. Codex subagents inherit that sandbox, and `agents.max_depth=1` stops them spawning their own.
- Both were live-tested on 2026-09-24 (Claude Code 2.1.267, codex-cli 0.155.1): subagents told to write a file were blocked on both sides. Re-run that test after upgrading either CLI.
- Every file the loop produces is written by `converge.sh` itself, and only into the run directory.

The worst case for an unattended run is therefore a bad document in a scratch directory, never a damaged repository. To apply the agreed solution, read `solution.md` and apply it yourself in a normal, supervised session. Please don't fork this with write permissions turned on.

## Persistent context

By default each agent keeps one conversation for the whole run:

- **Claude:** `--session-id` on the first call, then `--resume` on later calls.
- **Codex:** `--json` on the first call to capture the thread id, then `codex exec resume` on later calls.

On later rounds the agents are told to re-read only the files that changed, which saves re-reading all the evidence every round. Every panel reviewer keeps its own session (`.claude_session.<id>`, `.codex_session.<id>` in the run directory). Subagents always start empty, so agents are told to use them only for reading they have not done yet. Pass `--fresh-context` to start every call from scratch instead.

## License

[MIT](LICENSE)
