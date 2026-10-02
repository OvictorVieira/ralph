# Ralph Model Catalog

`config/models.json` is Ralph's catalog of per-model lifecycle and capability
metadata. It is the source of truth for what Ralph knows about a model: whether
it is still supported, which reasoning efforts it accepts, and what to say
about it when it is retired or replaced. Runtime discovery (asking the CLI
what it supports) remains authoritative for the live state of a user's machine;
the catalog adds the context the CLI itself does not expose.

## Schema

```jsonc
{
  "schemaVersion": 1,            // integer, bumped on breaking schema changes
  "providers": {
    "<provider>": {              // e.g. "claude", "codex", "agy"
      "cliBinary":        "<binary name on PATH>",
      "effortMechanism":  "<free-text description of how this CLI accepts effort>",
      "models": {
        "<model-id>": {
          "label":          "<human-friendly name>",
          "status":         "active | preview | superseded | deprecated | retired",
          "efforts":        ["low", "medium", "..."],   // may be empty
          "defaultEffort":  "medium" | null,             // null = no catalog default
          "aliases":        ["opus", "..."],              // CLI aliases that resolve here
          "successor":      "<model-id>" | null,          // for superseded/deprecated/retired
          "minCliVersion":  "x.y.z" | null,               // optional CLI floor
          "source":         "<URL or short note of where this entry was verified>",
          "notes":          "<free-text, optional>"
        }
      }
    }
  }
}
```

### Field notes

- **status** — lifecycle gate used by Ralph:
  - `active`: fully supported, no warning.
  - `preview`: usable, printed with a mild notice.
  - `superseded`: still works, prints a warning naming the `successor`.
  - `deprecated`: still works, prints a louder warning naming the `successor`.
  - `retired`: Ralph refuses to start, points the user at `--list-models`.
- **efforts** — leave empty when the provider CLI does not accept a
  reasoning-effort override for this model. Never guess; only populate values
  the CLI or current provider documentation explicitly confirms.
- **defaultEffort** — the provider's own default when nothing is passed. Null
  means "we don't know; let the provider decide." Ralph will never send this
  value as a CLI flag — it is used for display/explanation only.
- **aliases** — short names a user may type that should resolve to this model
  id (e.g. CLI aliases listed in `--help`).
- **source** — URL or short note stating where this entry was verified. For any
  model whose name/efforts could not be live-verified against the CLI or
  provider documentation, use `status: preview` with
  `source: "unverified - confirm before promoting to active"` instead of
  guessing a value or dropping the entry.

### Catalog vs runtime discovery

For `claude` and `codex`, this catalog is the primary source of truth for
status/effort validation; runtime discovery (parsing `--help` output or
inspecting user config) complements it.

For `agy`, runtime discovery via the installed `agy` CLI is the primary
authority, and catalog entries are explicitly secondary to runtime discovery
(serving as a documented fallback when discovery is unavailable).

For `cursor`, `opencode` and `amp`, Ralph does not maintain catalog entries;
behavior remains unchanged and model/effort pass through to the underlying
CLI.

## Adding or updating entries

1. Verify the model name against the installed CLI (`<cli> --help`,
   `<cli> models`, or official vendor documentation) at the time of change.
2. Only add efforts the CLI/docs explicitly accept for that model.
3. For a replacement model, keep the old entry and set its `status` and
   `successor` fields rather than deleting it — history helps users understand
   migration paths and feeds the catalog-audit workflow.
4. Run `jq empty config/models.json` to confirm the file is still valid JSON.
