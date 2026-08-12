# PRD: OpenCode as a Ralph tool, with Chinese models as the unpaid path

## Introduction

Ralph runs four agents today — amp, claude, gemini, codex — and every one of them
bills per token against a paid subscription. That makes the cheapest possible
Ralph run still cost money, which in turn makes two ordinary things expensive:
iterating on Ralph itself, and validating a PRD's shape before committing a real
run to it.

[OpenCode](https://github.com/sst/opencode) is an open-source terminal coding
agent that is provider-agnostic: it talks to whatever model endpoint it is
pointed at, including OpenAI-compatible endpoints served by the Chinese
labs — DeepSeek, Qwen (Alibaba), GLM (Zhipu), Kimi (Moonshot) — whose pricing is
one to two orders of magnitude below the US frontier models, and several of whose
weights are open enough to self-host.

Adding OpenCode as a fifth `--tool` gives Ralph a run mode that costs nearly
nothing. The goal is not to replace claude or codex for real delivery. It is to
have a tier where an exploratory or throwaway run is not a budget decision.

## Goals

- `ralph --tool opencode` runs the loop end to end, same contract as the others:
  reads `prd.json`, implements one story, commits, marks `passes: true`, emits
  `<promise>COMPLETE</promise>` when finished.
- A documented, reproducible configuration for at least one Chinese model
  provider, with the API key read from the environment and never committed.
- `--list-models` reports OpenCode's configured provider and model the same way
  it reports the others.
- A measured comparison against a paid tool on the same PRD, so "good enough for
  throwaway runs" is a finding rather than an assumption.

## Status

US-001 and US-002 are **done** — OpenCode is a working `--tool` as of
`feat: add agy, cursor and opencode tools, translate effort per tool`. What
remains is the part this PRD actually exists for: the provider configuration and
the measurement.

### Discovered contract (US-001)

Read from `opencode --help` and `opencode run --help`, v1 as installed:

| Question | Answer |
|---|---|
| Headless invocation | `opencode run [message..]` |
| Prompt supplied as | positional argument |
| Approval suppression | `--auto` ("auto-approve permissions that are not explicitly denied") |
| Model flag | `-m` / `--model`, format `provider/model` |
| Reasoning effort | `--variant` — "model variant (provider-specific reasoning effort, e.g., high, max, minimal)" |
| Model listing | `opencode models` — **answers without a sign-in**, unlike `agy models` and `cursor-agent --list-models` |
| Config location | `~/.opencode/` |
| Install location | `~/.opencode/bin/opencode`, not on PATH — Ralph resolves it there as a fallback |

`opencode models` already returns free models, several of them Chinese, which is
the tier this PRD was written for:

```
opencode/big-pickle
opencode/deepseek-v4-flash-free
opencode/laguna-s-2.1-free
opencode/ling-3.0-tiny-free
opencode/longcat-2.0-free
opencode/mimo-v2.5-free
opencode/nemotron-3-ultra-free
opencode/north-mini-code-free
```

That changes the shape of US-003: the `-free` models are reachable through
OpenCode's own gateway with no third-party API key at all. Configuring DeepSeek
or Qwen directly is now a fallback, not the first move.

## User Stories

### ~~US-001: Establish OpenCode's actual non-interactive contract~~ — DONE

**Description:** As a Ralph maintainer, I need OpenCode's real headless
invocation documented before writing any integration, so that the tool arm is
not built against guessed flags.

**Why first:** Ralph's other four arms each took a different shape — `amp
--dangerously-allow-all` reads stdin, `claude --print` reads stdin, `gemini
--prompt` takes the prompt as an argument, `codex exec` needs `-C` and a `-`
placeholder. OpenCode will be a fifth shape and nothing about it should be
inferred from the other four.

**Acceptance Criteria:**
- [ ] OpenCode installed locally and its version recorded in the PRD notes
- [ ] The following documented from `opencode --help` (not from memory or from
      another agent's flags): the non-interactive/headless subcommand or flag;
      how the prompt is supplied (stdin, argument, file); the flag that
      suppresses approval prompts; the model selection flag; whether any
      reasoning-effort equivalent exists
- [ ] How OpenCode reports a run as failed — exit code, or output only
- [ ] Where OpenCode stores its config, and which key holds provider + model
      (needed by `tool_configured_model` in `ralph.sh`)
- [ ] Findings written into this file under a "Discovered contract" heading

### ~~US-002: Add the `opencode` tool arm to ralph.sh~~ — DONE

**Description:** As a user, I want `ralph --tool opencode` to run the loop, so
that OpenCode is a first-class option rather than a fork.

**Acceptance Criteria:**
- [ ] `opencode` accepted by `--tool`, plus an `--opencode` shortcut, matching
      the existing pattern
- [ ] `SUPPORTED_TOOLS` includes it, so `--list-models` covers it automatically
- [ ] Presence check on PATH with the same error shape as the other four
- [ ] `OPENCODE.md` prompt template added, `install.sh` installs it, and the
      `case "$TOOL"` prompt-file dispatch resolves it
- [ ] `tool_configured_model opencode` reads the real config location found in
      US-001; returns empty rather than erroring when absent
- [ ] `tool_supports_effort` answers truthfully for opencode based on US-001
- [ ] `--model` is passed through
- [ ] The invocation branch uses the real flags from US-001
- [ ] `bash -n ralph.sh` passes and `ralph --list-models` shows the new row

### US-003: Verify and document the free-model tier

**Description:** As a user without a paid agent subscription, I want a copy-paste
configuration that points OpenCode at a low-cost provider, so that a Ralph run
costs cents instead of dollars.

**Acceptance Criteria:**
- [ ] A real one-story Ralph run completed on an `opencode/*-free` model, no
      third-party API key involved — this is now the primary path, since
      `opencode models` shows the free tier is reachable through OpenCode's own
      gateway
- [ ] A direct provider (DeepSeek, Qwen, GLM, Kimi) configured and verified only
      if the free tier proves unusable — documented as the fallback it is
- [ ] API key read from an environment variable. No key, and no `.env`
      containing one, is ever committed; `.gitignore` covers whatever file the
      config lives in if it can hold a secret
- [ ] README gains an "Unpaid runs" section: provider, endpoint, model id, env
      var, and the exact `ralph --tool opencode` command
- [ ] The rough per-run cost recorded, so the tier's value is a number
- [ ] Documented explicitly: which provider the code is sent to. Any repo whose
      code cannot leave a jurisdiction or a vendor boundary must not use this
      tier, and the README says so rather than leaving it implied

### US-004: Measure it against a paid tool on the same PRD

**Description:** As a maintainer, I want evidence of where this tier is and is
not usable, so the recommendation is grounded.

**Acceptance Criteria:**
- [ ] The same PRD run twice — once `--tool opencode` with the Chinese model,
      once with claude or codex
- [ ] Recorded per run: stories completed, iterations consumed, commits produced,
      whether the project's own quality checks passed, wall-clock time
- [ ] Recorded specifically: did the agent respect the Branch Policy — correct
      convention, short name, no story id, no branch per story
- [ ] Findings written into this file under a "Measured comparison" heading,
      including the failure modes seen, not only the totals
- [ ] README states plainly which kinds of story this tier handles and which it
      does not

## Functional Requirements

- FR-1: `--tool opencode` runs the Ralph loop with the same story-per-iteration
  and `<promise>COMPLETE</promise>` contract as the existing tools.
- FR-2: No provider, endpoint or model id is hardcoded in `ralph.sh`. Ralph
  passes `--model` through and otherwise defers to OpenCode's own config, exactly
  as it does for the other four.
- FR-3: `--list-models` includes opencode and reports its configured provider and
  model, or states that none is discoverable.
- FR-4: No API key is ever written to a tracked file.
- FR-5: The Branch Policy in `OPENCODE.md` is identical to the other four
  templates. A cheaper model is not a reason for a looser branch rule.

## Non-Goals

- Not replacing claude or codex for delivery work. This is a validation and
  throwaway tier.
- No self-hosting or local inference (Ollama, vLLM, LiteRT). Hosted
  OpenAI-compatible endpoints only. Local weights are a separate PRD.
- No provider abstraction layer inside Ralph. OpenCode already is that layer;
  duplicating it would be the mistake this PRD exists to avoid.
- No automatic fallback from a paid tool to OpenCode on quota exhaustion. Which
  model sees the code is an explicit choice, never an automatic one.

## Technical Considerations

- **Where the code goes.** This tier sends repository contents to a third-party
  provider. That is a per-repository decision, not a Ralph default, and the
  README must be blunt about it.
- **Effort.** Ralph's effort matrix already refuses `--effort` for tools that
  lack the knob. If OpenCode has no equivalent, adding it to that refusal list is
  the correct outcome, not a gap to paper over.
- **Prompt sensitivity.** The Ralph prompt templates assume an agent that can
  read a repo, run checks, and commit without hand-holding. A weaker model may
  need a more prescriptive `OPENCODE.md`. Diverging that file is acceptable —
  diverging the Branch Policy inside it is not.

## Success Metrics

- A full PRD completes on `--tool opencode` for under a dollar.
- The Branch Policy is respected on the OpenCode run.
- README lets someone with no paid subscription go from clone to running Ralph
  without asking a question.

## Open Questions

- Which provider first? Depends on what OpenCode supports most directly (US-001).
- Does OpenCode have a reasoning-effort equivalent, or does the effort matrix
  simply gain a fourth entry that refuses it?
- Does a weaker model need a diverged `OPENCODE.md`, or does the shared template
  hold?
