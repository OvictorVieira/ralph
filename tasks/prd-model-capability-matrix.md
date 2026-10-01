# PRD: Model/Effort Capability Matrix

## Introduction

Ralph today treats reasoning effort as a property of the **provider** (`tool_effort_values(tool)` in `ralph.sh`), not of the **model**. This is conceptually wrong: within claude, codex and agy, different models support different effort ranges and different defaults. There is also no model lifecycle (active/deprecated/retired), no central catalog, and a confirmed bug where claude silently receives `--effort medium` even when the user never asked for an effort override, overwriting the model's own native default.

This feature introduces a curated, versioned model catalog (`config/models.json`) combined with runtime discovery per provider, refactors `ralph.sh` to resolve model and effort against (provider, model) pairs instead of provider alone, fixes the claude effort-override bug, improves `--list-models` UX, adds a GitHub Action that audits the catalog against upstream sources on a schedule, hard-removes the `gemini` tool (superseded by `agy`), and adds a bats regression suite so this class of bug cannot silently return.

Everything in this PRD is additive/corrective to `ralph.sh`. Branch handling, quota/rate-limit detection, quiet/verbose streaming, the completion-signal loop, and prompt-file resolution are explicitly preserved and must not be touched beyond what each story requires.

## Goals

- Replace provider-level effort validation with model-level validation for claude, codex and agy.
- Stop Ralph from sending `--effort` to any provider unless the user explicitly passed `--effort`.
- Introduce `config/models.json` as the single source of model metadata: lifecycle status, supported efforts, default effort, aliases, successor, minimum CLI version, source references.
- Keep unknown/manual model IDs working exactly as today (warning, passthrough) — the catalog is a knowledge base, never a hard allowlist.
- Fail fast (before the Ralph loop starts) only for two conditions: a model explicitly known to be `retired`, and an effort value known to be unsupported for a known model.
- Make `--list-models` show status/efforts/defaults per model, filterable by `--tool`, with clear catalog vs runtime-discovered sections.
- Add a scheduled, non-inference GitHub Action that diffs the catalog against upstream documentation/CLI metadata and files/updates a tracking issue on drift.
- Hard-remove `gemini` as a supported tool (superseded by `agy`).
- Cover the new resolution logic with a bats regression suite using fake provider binaries — no real model calls, no quota consumption.

## User Stories

### US-001: Hard-remove the gemini tool
**Description:** As a maintainer, I want `gemini` fully removed from Ralph so the tool list reflects what's actually supported today (agy supersedes it), instead of carrying dead code and a stale driver prompt.

**Acceptance Criteria:**
- [ ] `gemini` removed from `SUPPORTED_TOOLS` in `ralph.sh`
- [ ] `--gemini` shortcut flag and the `gemini` execution branch (the `GEMINI_ARGS=(--approval-mode yolo)` block) removed from `ralph.sh`
- [ ] `tool_configured_model`, `tool_advertised_models`, `tool_effort_values`, `tool_effort_mechanism` no longer reference `gemini`
- [ ] `GEMINI.md` deleted from repo root
- [ ] `install.sh` no longer installs `GEMINI.md`; `GEMINI_PROMPT_FILE_NAME` wiring removed
- [ ] `--tool gemini` now produces: `Error: Invalid tool 'gemini'. Must be one of: <list>` (same shape as any other invalid tool, not a special message)
- [ ] `README.md` prerequisites/tool table/examples no longer mention gemini as a supported option (a one-line note that it was superseded by agy and removed is acceptable, not required)
- [ ] `ralph.sh --help` output no longer lists `--gemini`
- [ ] `shellcheck ralph.sh install.sh` passes (or has no new warnings versus current baseline)

### US-002: Define the model catalog schema and seed Claude entries
**Description:** As a maintainer, I want a central `config/models.json` that captures per-model lifecycle and capability metadata, starting with the claude provider, so later stories have a real data source instead of hardcoded case statements.

**Acceptance Criteria:**
- [ ] `config/models.json` created with top-level `schemaVersion` (integer) and `providers` map
- [ ] Each provider entry has: `cliBinary`, `effortMechanism` (free text describing how effort is passed), `models` map
- [ ] Each model entry supports at minimum: `label`, `status` (`active|preview|superseded|deprecated|retired`), `efforts` (array, may be empty), `defaultEffort` (nullable), `aliases` (array), `successor` (nullable model id), `minCliVersion` (nullable), `source` (nullable URL or free text), `notes` (nullable)
- [ ] Claude models are seeded **only after verifying current model names and their supported effort levels against the Anthropic / Claude Code documentation and/or `claude --help` output at implementation time** — do not copy model names verbatim from this PRD's prose without confirming them live; if a model name mentioned elsewhere in this project's conversation history cannot be confirmed, mark it `"status": "preview"` with `"source": "unverified — confirm before promoting to active"` rather than omit or guess
- [ ] Do not assign any `efforts` to a model unless the documentation or CLI explicitly confirms that model accepts a reasoning-effort override (e.g. do not assume a lightweight/haiku-class model supports effort levels)
- [ ] `jq empty config/models.json` validates the file is syntactically correct JSON
- [ ] A short `config/README.md` or a comment block (as a `"_comment"` style convention is not valid JSON — use `config/README.md`) documents the schema fields for future contributors

### US-003: Seed Codex catalog entries
**Description:** As a maintainer, I want the Codex provider populated in `config/models.json` so codex gets the same model-level effort validation as claude.

**Acceptance Criteria:**
- [ ] Codex models seeded under `providers.codex.models` following the US-002 schema
- [ ] Model names and effort support verified against current OpenAI/Codex CLI documentation and, where available, actual Codex CLI capability output at implementation time — not invented
- [ ] Superseded models (e.g. an older generation replaced by a newer one within the same family) are present with `"status": "superseded"` and `"successor"` pointing at the replacing model id, not deleted
- [ ] No effort level is added to the catalog that isn't confirmed by Codex CLI docs/behavior (do not add `"ultra"`, `"minimal"`, etc. speculatively)
- [ ] `jq empty config/models.json` still validates after the merge

### US-004: Seed AGY catalog entries
**Description:** As a maintainer, I want the AGY (Antigravity) provider populated in `config/models.json` as a documented fallback, understanding that for AGY, runtime discovery (US-009) is the primary authority and the catalog is secondary.

**Acceptance Criteria:**
- [ ] AGY models seeded under `providers.agy.models` following the US-002 schema, sourced from current AGY/Antigravity documentation
- [ ] `effortMechanism` and `efforts` reflect AGY's documented `low|medium|high` range (confirm current range against docs/`agy --help` before seeding — do not assume it hasn't changed)
- [ ] Catalog entries are explicitly marked as secondary to runtime discovery in `config/README.md` (one sentence is enough)
- [ ] `jq empty config/models.json` still validates after the merge

### US-005: Catalog accessor functions in ralph.sh
**Description:** As a maintainer, I want small, single-purpose bash functions that read `config/models.json` via `jq`, so the rest of `ralph.sh` never inlines catalog lookups.

**Acceptance Criteria:**
- [ ] `catalog_model_status(provider, model)` — prints the model's `status`, or empty if unknown to the catalog
- [ ] `catalog_model_efforts(provider, model)` — prints the model's supported efforts (space-separated), or empty if unknown/none
- [ ] `catalog_model_default_effort(provider, model)` — prints `defaultEffort`, or empty
- [ ] `catalog_model_successor(provider, model)` — prints `successor`, or empty
- [ ] `catalog_model_label(provider, model)` — prints `label`, or the raw model id if unknown
- [ ] All four functions handle a missing/malformed `config/models.json` gracefully (print nothing, non-fatal) — Ralph must still run with an unknown model when the catalog file is absent
- [ ] Functions are placed together in `ralph.sh` with a short comment explaining the catalog-vs-runtime split (mirroring the existing comment style already in the file, e.g. around `tool_advertised_models`)
- [ ] No `eval` used; all jq invocations use `--arg` for interpolation, never string-concatenated into the jq filter
- [ ] `shellcheck ralph.sh` passes with no new warnings

### US-006: resolve_model and resolve_effort with explicit source tracking
**Description:** As a user, I want Ralph to tell me *where* the model and effort it's about to use came from (explicit flag, provider config, Ralph default, or provider default), so I'm never guessing why a run used a particular setting.

**Acceptance Criteria:**
- [ ] `resolve_model(tool, cli_model_flag)` returns the model id and a source tag via two outputs (e.g. prints `model\tsource` on one line, or sets two variables — pick one approach and use it consistently), where source is one of: `explicit`, `provider-config`, `ralph-default`, `provider-default`
- [ ] Precedence implemented exactly as: 1) `--model` flag if given → `explicit`; 2) `tool_configured_model` if non-empty → `provider-config`; 3) a catalog model flagged as Ralph's own default (only if such a flag exists in `config/models.json` for that provider — otherwise skip this step) → `ralph-default`; 4) nothing resolved → `provider-default` (Ralph sends no `--model`, the CLI's own default applies)
- [ ] `resolve_effort(tool, model, cli_effort_flag, effort_explicit)` returns the effort value (possibly empty) and a source tag (`explicit` or absent/none)
- [ ] When `effort_explicit` is false, `resolve_effort` returns an empty effort — it never substitutes a default value to be sent to the CLI
- [ ] When `effort_explicit` is false AND the catalog knows `defaultEffort` for that model, the function still returns empty for the value actually sent, but makes the known default available separately for display purposes only (e.g. a third output field)
- [ ] Unit-testable in isolation (no side effects, pure functions of their inputs plus the catalog file and `tool_configured_model`)

### US-007: Fix the claude effort bug and wire resolve_effort into claude/codex/agy execution
**Description:** As a user, I want claude to use the model's own native default reasoning effort when I don't pass `--effort`, instead of Ralph silently forcing `medium`.

**Acceptance Criteria:**
- [ ] `ralph.sh:887` (`CLAUDE_ARGS=(--effort "$EFFORT" ...)`) no longer unconditionally includes `--effort`
- [ ] Claude execution block now only appends `--effort "$VALUE"` when `EFFORT_EXPLICIT=1` (same pattern codex/agy already use)
- [ ] Codex and agy execution blocks switched to use `resolve_effort`/catalog validation from US-005/US-006 instead of the current ad-hoc `EFFORT_EXPLICIT` checks, with identical externally-observable behavior when no catalog entry exists for the given model (pass through unchanged, warn only)
- [ ] `EFFORT` global default of `"medium"` remains only as the **display fallback** when no model-specific default is known — it must never be sent as a CLI flag unless the user explicitly asked for `medium`
- [ ] Manually verified: `ralph --tool claude --model <any-model> 1` (against a fake `claude` binary that echoes its argv) shows **no** `--effort` in the captured argv when `--effort` wasn't passed on the ralph command line
- [ ] Manually verified: `ralph --tool claude --model <any-model> --effort high 1` shows `--effort high` in the captured argv

### US-008: Model-effort validation with fail-fast
**Description:** As a user, I want Ralph to stop immediately with a clear error if I ask for an effort level a known model doesn't support, or if I target a model the catalog marks as retired — instead of discovering the failure mid-run or burning a provider call on something doomed to fail.

**Acceptance Criteria:**
- [ ] `validate_model_effort(provider, model, effort, effort_explicit)` implemented: if the model is known to the catalog, has a non-empty `efforts` list, `effort_explicit=1`, and the requested effort is not in that list → print the valid list and exit non-zero before the iteration loop starts
- [ ] If the model is known and its catalog `status` is `retired` → exit non-zero before the loop starts, with a message explaining the model is retired and pointing at `ralph --tool <tool> --list-models` to see alternatives
- [ ] If the model is unknown to the catalog (any status, including entirely absent) → no fail-fast; proceed with a warning only, exactly like today's "not in the model list the CLI advertises" warning (these two warnings may be merged into one)
- [ ] If the model is known with `status` of `superseded` → proceed, print a warning naming the `successor` when known
- [ ] If the model is known with `status` of `deprecated` → proceed, print a **stronger** warning (visually distinct from `superseded`, e.g. different color/prefix) naming the `successor` when known
- [ ] These checks run for claude, codex and agy only (the three providers with a catalog) — cursor, opencode and amp keep today's behavior unchanged (no catalog, no model-level validation) and this is intentional, not a gap to fill in this PRD

### US-009: CLI capability preflight (claude --effort support, version gating)
**Description:** As a user, if my installed claude CLI is too old to support `--effort` at all, or a model I selected declares a `minCliVersion` in the catalog, I want Ralph to tell me clearly before starting rather than letting the provider fail obscurely mid-run.

**Acceptance Criteria:**
- [ ] A capability check determines whether the installed `claude` binary supports `--effort` (e.g. by checking `claude --help` for the flag, consistent with how `tool_advertised_models` already parses `--help`)
- [ ] If the user passed `--effort` explicitly and the installed claude CLI does not advertise `--effort` support → fail fast with a clear message before the loop starts (not a mid-run provider error)
- [ ] If a selected model's catalog entry declares `minCliVersion` and Ralph can determine the installed CLI's version (e.g. `claude --version`, `codex --version`, `agy --version`), compare and fail fast with a clear message if the installed version is older
- [ ] If the installed CLI's version cannot be determined, this check is skipped silently (never a false failure) — this mirrors the existing "warn and proceed" philosophy for anything Ralph can't verify
- [ ] No `minCliVersion` is set in the seeded catalog (US-002/003/004) unless it was confirmed from documentation — this story only needs to prove the mechanism works, it does not require the catalog to actually declare any version constraint yet

### US-010: Improve --list-models UX with per-model table and --tool filtering
**Description:** As a user, I want `ralph --list-models` and `ralph --tool codex --list-models` to show me, per model, its status, supported efforts and default — not just a flat space-separated list of names.

**Acceptance Criteria:**
- [ ] `ralph --tool <tool> --list-models` restricts output to that single provider (currently `--list-models` ignores `--tool` entirely and always lists all tools)
- [ ] `ralph --list-models` (no `--tool`) still lists all supported tools, as today
- [ ] Each provider section renders a table: `MODEL  STATUS  EFFORTS  DEFAULT` for every model the catalog knows about for that provider, with a marker (e.g. `*`) on the row matching the provider's configured/default model when known
- [ ] A `Runtime discovered:` section lists models the CLI enumerated that are **not** in the catalog (new/unknown to Ralph)
- [ ] A `Catalog only:` section lists catalog models the CLI did **not** enumerate (e.g. signed out, or the CLI doesn't support discovery) — only shown when non-empty
- [ ] Empty sections are omitted entirely (no "Runtime discovered:\n(none)" noise), matching the existing instruction to not print empty sections
- [ ] For providers with no catalog (cursor, opencode, amp), output is unchanged from today's `print_models` behavior
- [ ] Output remains readable in a non-TTY (no stray ANSI codes when piped), consistent with existing banner color-guarding (`[[ -t 1 ]]`)

### US-011: AGY JSON-first runtime discovery with safe fallback
**Description:** As a user running `--tool agy`, I want Ralph to use AGY's structured model listing when available, so discovery doesn't depend on fragile regex over human-readable text.

**Acceptance Criteria:**
- [ ] Before calling `agy models`, Ralph feature-detects whether the installed agy CLI supports a machine-readable output flag (e.g. checking `agy models --help` or `agy --help` for an output-format option) — confirm the actual current flag name against the installed CLI/docs rather than assuming one
- [ ] When the structured flag is supported, Ralph parses it with `jq` instead of regex
- [ ] When the structured flag is not supported (older agy CLI), Ralph falls back to the existing regex-based text parsing in `tool_advertised_models` unchanged
- [ ] Model slugs returned are used exactly as AGY reports them — no normalization/renaming
- [ ] If both the structured and fallback parse paths produce nothing (e.g. signed out), behavior matches today: empty result, no crash, `--model` still passes through unvalidated

### US-012: Expanded startup banner
**Description:** As a user, I want the startup banner to show where the model and effort came from, the model's known lifecycle status, its supported efforts, and (when determinable) the installed CLI version — so I can sanity-check a run before it burns an iteration.

**Acceptance Criteria:**
- [ ] Banner adds, only for claude/codex/agy (the catalog-backed providers): `Model source:`, `Model status:` (omitted if unknown to catalog), `Effort source:`, `Supported:` (the model's effort list, omitted if the model has none/unknown), `CLI version:` (omitted if undeterminable)
- [ ] `Effort:` line shows `model default (medium)` style text (matching existing style at `ralph.sh:847`) when no explicit effort was given but the catalog knows a default, instead of the current generic `"<tool> default (no --effort given)"` — fall back to the current generic text when the catalog has no default for that model
- [ ] Existing banner fields (Tool, Max iterations, Project root, PRD file, Prompt file, Model, Target branch, Commit email) remain in the same order and format
- [ ] Existing color scheme (`C_LABEL`/`C_VALUE`/`C_ACCENT`/`C_MUTED`/`C_BANNER`) reused for new fields rather than introducing new colors, and the `[[ -t 1 ]]` guard still applies
- [ ] For tools without a catalog (cursor, opencode, amp, and the removed gemini N/A), banner output is unchanged from today

### US-013: GitHub Action — model catalog audit
**Description:** As a maintainer, I want an automated, scheduled check that catches catalog drift (new models we don't know about, models that became deprecated/retired upstream, effort changes) before a user hits it, without spending any inference budget.

**Acceptance Criteria:**
- [ ] `scripts/audit-model-catalog.py` created: reads `config/models.json`, compares against upstream sources (official docs pages and/or CLI-exposed metadata — no model inference calls of any kind)
- [ ] Findings classified as `CRITICAL` (Ralph's resolved default model/effort for a provider is retired/unsupported upstream), `HIGH` (catalog model deprecated/retired upstream, or effort capability changed incompatibly), `MEDIUM` (new stable model upstream absent from catalog), `LOW` (label/metadata-only changes)
- [ ] Absence from a "current models" page is never alone sufficient to mark something `retired` — the script only reports a lifecycle downgrade when it has explicit evidence (e.g. an upstream deprecation notice), otherwise it reports "could not confirm" rather than asserting retirement
- [ ] Script writes a JSON report artifact and a human-readable summary suitable for `$GITHUB_STEP_SUMMARY`
- [ ] `.github/workflows/model-catalog-audit.yml` created: triggers on `schedule` (a few times a week) and `workflow_dispatch`; `permissions: contents: read, issues: write`
- [ ] On any finding, the workflow creates or updates a GitHub issue using a stable identifying key in the title/body, e.g. `[model-audit][codex][gpt-x]` — re-running the audit updates the existing issue (comment) instead of creating a duplicate
- [ ] Issue body includes: severity, provider, model, current Ralph catalog metadata, upstream metadata found, source URL(s), suggested action, audit timestamp
- [ ] Issue is assigned to / mentions `@OvictorVieira`
- [ ] If any `CRITICAL` finding exists, the workflow job fails (non-zero exit) after publishing the report/issue, so it surfaces as a red workflow run in addition to the issue
- [ ] Labels used by the workflow are created if missing, or the label step fails gracefully without failing the whole workflow
- [ ] Workflow YAML validates (`yamllint` or `actionlint` if available, otherwise a GitHub Actions workflow syntax check)

### US-014: Bats regression suite
**Description:** As a maintainer, I want automated tests covering model/effort resolution so the claude-effort bug class (and similar provider-argv mistakes) can't silently regress again.

**Acceptance Criteria:**
- [ ] `tests/` directory with bats-core specs; fake provider binaries (`claude`, `codex`, `agy`, etc.) placed on `PATH` for the test run that just echo/record their received argv instead of calling any real API — no real model inference triggered by any test
- [ ] Test: explicit model + valid effort for that model → succeeds, correct flags passed
- [ ] Test: explicit model + invalid effort for that known model → fails fast with the valid-efforts list in the output, before any provider binary is invoked
- [ ] Test: model marked `retired` in a test catalog fixture → fails fast with a clear message, before any provider binary is invoked
- [ ] Test: unknown/manual model id → warning printed, run proceeds, model passed through verbatim to the fake binary
- [ ] Test: no `--effort` given → the fake claude/codex/agy binary's recorded argv contains no effort flag/config-key at all
- [ ] Test: claude never auto-receives `--effort medium` when `--effort` wasn't passed (the specific regression this PRD fixes)
- [ ] Test: codex argv includes `-c model_reasoning_effort="<value>"` only when `--effort` was explicit
- [ ] Test: agy argv includes `--model ...` and, only when explicit, `--effort ...`
- [ ] Test: `ralph --tool codex --list-models` output is scoped to codex only
- [ ] Test: `ralph --list-models` (no `--tool`) lists every supported tool
- [ ] Test: runtime discovery failure (fake CLI exits non-zero / prints nothing) does not crash Ralph and catalog-only fallback still works
- [ ] Test: a `RALPH_PROJECT_ROOT` containing spaces in its path works correctly through the whole flag-parsing/model-resolution path
- [ ] A documented way to run the suite locally (e.g. `bats tests/`) added to `README.md` or a `tests/README.md`
- [ ] Suite runnable without any real provider CLI installed and without any network access or API key

### US-015: README updates
**Description:** As a user, I want the README to explain the new model catalog, lifecycle, effort-per-model behavior, and the audit workflow, so I don't have to read `ralph.sh` to understand what changed.

**Acceptance Criteria:**
- [ ] README documents `ralph --tool codex --list-models` and the full example `ralph --tool codex --model <model> --effort high 6` (model name pulled from whatever the catalog actually contains after US-003, not invented)
- [ ] README explains catalog vs runtime discovery in plain language (what each is for, which wins when they disagree)
- [ ] README explains model lifecycle statuses and what happens at each (active/preview/superseded/deprecated/retired — warn vs fail-fast)
- [ ] README explains that effort is now per-model and that Ralph never sends an effort override unless `--effort` was explicitly passed
- [ ] README explains, briefly, how the model-catalog-audit workflow works and where its findings show up (GitHub issues)
- [ ] README explicitly states that unknown/custom/manual model IDs remain supported (warning, not a hard block)
- [ ] All references to `gemini` as a supported tool removed from README (per US-001); a brief historical note that it was superseded by `agy` and removed is acceptable
- [ ] Existing README sections not touched by this PRD (Setup, Workflow steps 1-3, Archiving, etc.) remain unchanged

## Functional Requirements

- FR-1: `config/models.json` is the single source of truth for model lifecycle/capability metadata; no model capability table may be hardcoded inline in `ralph.sh` for claude, codex or agy after this PRD lands.
- FR-2: Effort is resolved against (provider, model), never provider alone, for claude, codex and agy.
- FR-3: Ralph must never send an effort flag/config-key to any provider unless the user passed `--effort` on the Ralph command line.
- FR-4: An unknown model id (not present in the catalog) must never block execution — warn and pass through, exactly as today.
- FR-5: A model with catalog `status: retired` must block execution before the first iteration starts.
- FR-6: An effort value not in a known model's `efforts` list must block execution before the first iteration starts.
- FR-7: Model resolution source (`explicit`/`provider-config`/`ralph-default`/`provider-default`) must be determinable and shown to the user.
- FR-8: `--list-models` must accept an optional `--tool` scope and otherwise behave as it does today for providers without a catalog.
- FR-9: The GitHub Action must perform zero paid model inference calls.
- FR-10: The GitHub Action must not create duplicate issues for the same finding across repeated runs.
- FR-11: `gemini` must not appear in `SUPPORTED_TOOLS`, `install.sh`, `bin/ralph` wiring, or README after US-001.
- FR-12: All new jq usage must interpolate values via `--arg`/`--argjson`, never raw string concatenation into a filter; no `eval` is introduced anywhere in `ralph.sh`.
- FR-13: All new/modified bash functions must correctly handle paths containing spaces (project root, prompt file, catalog file).
- FR-14: Branch handling (`detect_default_branch`, `resolve_target_branch`, `persist_branch_name`, `resolve_git_identity_from_history`), quota/rate-limit detection, quiet/verbose streaming (`-v`/`--verbose`, `TEE_TARGET`), the completion-signal check, and the iteration loop structure must not change behavior as part of this PRD.

## Non-Goals (Out of Scope)

- No model-level catalog/effort validation for cursor, opencode or amp in this PRD — they keep today's provider-level/passthrough behavior.
- No rewrite of the per-tool execution case block into provider-specific "argument builder" functions beyond what's needed for US-006/US-007 — a full builder-function refactor of every tool's execution is explicitly deferred (document it as a follow-up note in README or AGENTS.md, do not implement it here).
- No adoption of structured provider output (`--output-format stream-json`, `--json`, etc.) for quota/completion detection in this PRD — document it as a documented next step only (per the original ask), the existing regex/heuristic quota detection stays exactly as-is.
- No changes to the `/prd` or `/ralph` skills themselves.
- No changes to the flowchart app.
- No softening of the existing "project rules file must carry the stop sentinel to be used as a driver" behavior.
- The GitHub Action must not run any paid/metered inference call against any model, under any circumstance.
- Do not invent model names, effort support, or lifecycle status not confirmed by official documentation or live CLI output at implementation time — if something can't be confirmed, mark it unverified in the catalog rather than guessing.

## Technical Considerations

- `ralph.sh` stays a single bash file (no new runtime dependency beyond `jq`, which Ralph already requires); Python is only introduced for `scripts/audit-model-catalog.py`, which runs in CI, never in the normal `ralph` execution path.
- Fake-binary mocking for bats tests should prepend a temp directory to `PATH` per test rather than touching any real provider CLI installed on the dev machine.
- `jq`'s exit-on-missing-key behavior means every catalog lookup should use `// empty` or equivalent so a field absent in `config/models.json` degrades to "unknown" rather than erroring the whole script.
- Preserve the existing comment style in `ralph.sh` (long explanatory comments above non-obvious functions) for any new function that encodes a non-obvious decision — this repo's existing convention, keep it consistent.

## Success Metrics

- `ralph --tool claude --model <any-model> <n>` (no `--effort`) never includes an effort flag in the claude invocation — closes the specific bug reported.
- `ralph --list-models` and `ralph --tool <x> --list-models` show per-model status/efforts/default for claude, codex and agy.
- A retired model or an invalid model+effort combination fails before any provider CLI is invoked, with zero iterations burned.
- The audit workflow runs on schedule with zero inference spend and produces at most one tracked issue per distinct finding.
- `shellcheck ralph.sh install.sh` and `bats tests/` both pass clean after implementation.

## Open Questions

- Should `config/models.json` eventually be split per-provider (`config/models/claude.json`, etc.) if it grows large? Not needed at current scope — single file is fine for now.
- Should the audit workflow's issue-mention use a GitHub username (`@OvictorVieira`) or a CODEOWNERS-style assignee API call? Default to a plain `@mention` in the issue body for simplicity; an actual `assignees` field on the issue is a nice-to-have, not required.
