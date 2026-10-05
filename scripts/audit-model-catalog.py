#!/usr/bin/env python3
"""Audit Ralph's model catalog against public, zero-inference metadata.

The live collectors only download official documentation, read Codex's local
model cache, and run AGY's metadata-only `models` command. They never send a
prompt or make a model inference request. A normalized upstream JSON file can
be supplied for deterministic/offline runs.
"""

from __future__ import annotations

import argparse
import copy
import datetime as dt
import gzip
import html
from html.parser import HTMLParser
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
from typing import Any
import urllib.error
import urllib.request


ANTHROPIC_LIFECYCLE_URL = (
    "https://docs.anthropic.com/en/docs/about-claude/model-deprecations"
)
OPENAI_CURRENT_URL = "https://developers.openai.com/api/docs/guides/model-selection"
OPENAI_LIFECYCLE_URL = "https://developers.openai.com/api/docs/deprecations"
AGY_CURRENT_URL = "https://antigravity.google/docs/models"
AGY_CLI_URL = "https://www.antigravity.google/docs/cli/headless/"
SEVERITIES = ("CRITICAL", "HIGH", "MEDIUM", "LOW")
MODEL_TOKEN_RE = re.compile(r"\b(?:claude|gemini|gpt)-[a-z0-9][a-z0-9.-]*", re.I)


class TableParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.tables: list[list[list[str]]] = []
        self._table: list[list[str]] | None = None
        self._row: list[str] | None = None
        self._cell: list[str] | None = None

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        del attrs
        if tag == "table":
            self._table = []
        elif tag == "tr" and self._table is not None:
            self._row = []
        elif tag in ("td", "th") and self._row is not None:
            self._cell = []

    def handle_data(self, data: str) -> None:
        if self._cell is not None:
            self._cell.append(data)

    def handle_endtag(self, tag: str) -> None:
        if tag in ("td", "th") and self._cell is not None and self._row is not None:
            self._row.append(clean_text("".join(self._cell)))
            self._cell = None
        elif tag == "tr" and self._row is not None and self._table is not None:
            if self._row:
                self._table.append(self._row)
            self._row = None
        elif tag == "table" and self._table is not None:
            self.tables.append(self._table)
            self._table = None


def clean_text(value: str) -> str:
    return " ".join(html.unescape(value).split())


def html_text(value: str) -> str:
    return clean_text(re.sub(r"<[^>]+>", " ", value))


def model_match_key(value: Any) -> str:
    if not isinstance(value, str):
        return ""
    return re.sub(r"[._]+", "-", value.strip().lower())


def display_match_key(value: str) -> str:
    value = re.sub(
        r"\((?:thinking|minimal|low|medium|high|max|ultra)\)", "", value, flags=re.I
    )
    return re.sub(r"[^a-z0-9]+", "", value.lower())


def provider_record() -> dict[str, Any]:
    return {"currentModels": {}, "lifecycle": {}, "sources": []}


def empty_upstream() -> dict[str, Any]:
    return {
        "providers": {name: provider_record() for name in ("claude", "codex", "agy")}
    }


def add_source(
    upstream: dict[str, Any], provider: str, source: str, status: str, detail: str = ""
) -> None:
    upstream["providers"][provider]["sources"].append(
        {"url": source, "status": status, "detail": detail}
    )


def add_current(
    upstream: dict[str, Any],
    provider: str,
    model_id: str,
    *,
    label: str | None,
    efforts: list[str] | None,
    source: str,
    evidence: str,
) -> None:
    models = upstream["providers"][provider]["currentModels"]
    existing = models.setdefault(
        model_id,
        {
            "id": model_id,
            "label": label,
            "status": "active",
            "efforts": efforts,
            "sourceUrls": [source],
            "evidence": evidence,
        },
    )
    if source not in existing["sourceUrls"]:
        existing["sourceUrls"].append(source)
    if label and not existing.get("label"):
        existing["label"] = label
    if efforts is not None:
        existing["efforts"] = efforts
    if evidence and evidence not in existing.get("evidence", ""):
        existing["evidence"] = clean_text(
            f"{existing.get('evidence', '')}; {evidence}".strip("; ")
        )


def add_lifecycle(
    upstream: dict[str, Any],
    provider: str,
    model_id: str,
    status: str,
    source: str,
    evidence: str,
) -> None:
    upstream["providers"][provider]["lifecycle"][model_id] = {
        "id": model_id,
        "status": status,
        "sourceUrls": [source],
        "evidence": evidence,
    }


def fetch_url(url: str, attempts: int = 2) -> str:
    request = urllib.request.Request(
        url,
        headers={
            "Accept": "text/html,application/xhtml+xml",
            "User-Agent": "Ralph-model-catalog-audit/1.0",
        },
    )
    last_error: Exception | None = None
    for attempt in range(attempts):
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                body = response.read()
                if response.headers.get(
                    "Content-Encoding", ""
                ).lower() == "gzip" or body.startswith(b"\x1f\x8b"):
                    body = gzip.decompress(body)
                return body.decode(response.headers.get_content_charset() or "utf-8")
        except (OSError, UnicodeError, urllib.error.URLError) as error:
            last_error = error
            if attempt + 1 < attempts:
                time.sleep(1)
    raise RuntimeError(f"could not fetch {url}: {last_error}")


def parse_tables(document: str) -> list[list[list[str]]]:
    parser = TableParser()
    parser.feed(document)
    return parser.tables


def parse_date(value: str) -> dt.date | None:
    cleaned = re.sub(r"(?<=\d)(st|nd|rd|th)\b", "", value, flags=re.I)
    for pattern in ("%b %d, %Y", "%B %d, %Y", "%Y-%m-%d"):
        try:
            return dt.datetime.strptime(cleaned.strip(), pattern).date()
        except ValueError:
            pass
    return None


def collect_anthropic(upstream: dict[str, Any], document: str) -> None:
    found = False
    for table in parse_tables(document):
        if not table or "current state" not in " ".join(table[0]).lower():
            continue
        for row in table[1:]:
            if len(row) < 2 or not row[0].lower().startswith("claude-"):
                continue
            found = True
            model_id, state = row[0], row[1].lower()
            evidence = " | ".join(row)
            if state == "active":
                add_current(
                    upstream,
                    "claude",
                    model_id,
                    label=None,
                    efforts=None,
                    source=ANTHROPIC_LIFECYCLE_URL,
                    evidence=evidence,
                )
            elif state in ("deprecated", "retired"):
                add_lifecycle(
                    upstream,
                    "claude",
                    model_id,
                    state,
                    ANTHROPIC_LIFECYCLE_URL,
                    evidence,
                )
    if not found:
        raise RuntimeError("Anthropic lifecycle table was not recognized")


def collect_openai_current(upstream: dict[str, Any], document: str) -> None:
    candidates = set()
    for pattern in (
        r'href="/api/docs/models/(gpt-\d+(?:\.\d+)?-(?:astra|sol|terra|luna))',
        r'src="/images/api/models/(gpt-\d+(?:\.\d+)?-(?:astra|sol|terra|luna))-texture',
    ):
        candidates.update(re.findall(pattern, document.lower()))
    if not candidates:
        raise RuntimeError("OpenAI current-model page yielded no recognized model ids")
    for model_id in sorted(candidates):
        add_current(
            upstream,
            "codex",
            model_id,
            label=None,
            efforts=None,
            source=OPENAI_CURRENT_URL,
            evidence=f"Official model-selection page names {model_id} as a current model.",
        )


def collect_openai_lifecycle(
    upstream: dict[str, Any], document: str, audit_date: dt.date
) -> None:
    recognized = False
    for table in parse_tables(document):
        if not table:
            continue
        header = " ".join(table[0]).lower()
        if "shutdown date" not in header or "model" not in header:
            continue
        recognized = True
        for row in table[1:]:
            if len(row) < 2:
                continue
            shutdown = parse_date(row[0])
            status = "retired" if shutdown and shutdown <= audit_date else "deprecated"
            for model_id in MODEL_TOKEN_RE.findall(row[1]):
                if model_id.lower().startswith("gpt-"):
                    add_lifecycle(
                        upstream,
                        "codex",
                        model_id.lower(),
                        status,
                        OPENAI_LIFECYCLE_URL,
                        " | ".join(row),
                    )
    if not recognized:
        raise RuntimeError("OpenAI deprecation tables were not recognized")


def effort_from_model_id(model_id: str) -> list[str] | None:
    match = re.search(r"-(minimal|low|medium|high|xhigh|max|ultra)$", model_id)
    return [match.group(1)] if match else None


def collect_agy_docs(
    upstream: dict[str, Any],
    models_document: str,
    cli_document: str,
    audit_date: dt.date,
) -> None:
    model_rows: dict[str, str] = {}
    for table in parse_tables(models_document):
        if not table or not table[0] or table[0][0].lower() != "model":
            continue
        for row in table[1:]:
            if row:
                raw_label = row[0]
                label = raw_label.rstrip("*").strip()
                model_rows[label] = raw_label

    attr_matches = re.findall(
        r'data-model-id="([^"]+)"(?:(?!data-model-id=).){0,1200}?'
        r'class="model-name"[^>]*>([^<]+)',
        models_document,
        flags=re.I | re.S,
    )
    if not attr_matches:
        raise RuntimeError("Antigravity models page yielded no model metadata")
    for model_id, raw_label in attr_matches:
        label = clean_text(raw_label).rstrip("*").strip()
        add_current(
            upstream,
            "agy",
            model_id.lower(),
            label=label,
            efforts=effort_from_model_id(model_id.lower()),
            source=AGY_CURRENT_URL,
            evidence=f"Official Antigravity model selector lists {label}.",
        )

    # The CLI guide publishes exact selectable slugs. Tier suffixes are also
    # explicit effort metadata, so they are safe to compare without inference.
    cli_slugs = set(
        re.findall(
            r"\b(?:gemini-\d+\.\d+-(?:flash|pro)-(?:low|medium|high|max)|"
            r"claude-(?:sonnet|opus)-\d+-\d+(?:-thinking)?|"
            r"gpt-oss-\d+b-(?:low|medium|high))\b",
            html_text(cli_document).lower(),
        )
    )
    for model_id in sorted(cli_slugs):
        add_current(
            upstream,
            "agy",
            model_id,
            label=None,
            efforts=effort_from_model_id(model_id),
            source=AGY_CLI_URL,
            evidence=f"Official AGY CLI guide lists selectable slug {model_id}.",
        )

    removal_match = re.search(
        r"will be removed on ([A-Z][a-z]+ \d{1,2}, \d{4})",
        html_text(models_document),
        re.I,
    )
    removal_date = parse_date(removal_match.group(1)) if removal_match else None
    if removal_date:
        status = "retired" if removal_date <= audit_date else "deprecated"
        for label, raw_label in model_rows.items():
            if not raw_label.endswith("*") or raw_label.endswith("**"):
                continue
            matching_id = next(
                (
                    model_id
                    for model_id, upstream_label in attr_matches
                    if display_match_key(clean_text(upstream_label).rstrip("*").strip())
                    == display_match_key(label)
                ),
                None,
            )
            if matching_id:
                add_lifecycle(
                    upstream,
                    "agy",
                    matching_id.lower(),
                    status,
                    AGY_CURRENT_URL,
                    f"{label}: official page says it will be removed on {removal_date.isoformat()}.",
                )


def collect_codex_cache(upstream: dict[str, Any], cache_path: Path) -> None:
    if not cache_path.is_file():
        return
    try:
        payload = json.loads(cache_path.read_text(encoding="utf-8"))
        models = payload.get("models", [])
        for model in models:
            model_id = model.get("slug")
            if not isinstance(model_id, str) or not model.get("supported_in_api", True):
                continue
            effort_rows = model.get("supported_reasoning_levels")
            efforts = None
            if isinstance(effort_rows, list):
                efforts = [
                    row["effort"]
                    for row in effort_rows
                    if isinstance(row, dict) and isinstance(row.get("effort"), str)
                ]
            add_current(
                upstream,
                "codex",
                model_id,
                label=model.get("display_name"),
                efforts=efforts,
                source="cli-cache://codex/models_cache.json",
                evidence="Codex local model cache marks this model supported_in_api.",
            )
        add_source(
            upstream,
            "codex",
            "cli-cache://codex/models_cache.json",
            "ok",
            f"Read {len(models)} cached model records.",
        )
    except (OSError, ValueError, TypeError) as error:
        add_source(
            upstream,
            "codex",
            "cli-cache://codex/models_cache.json",
            "error",
            str(error),
        )


def collect_agy_cli(upstream: dict[str, Any]) -> None:
    binary = shutil.which("agy")
    if not binary:
        return
    source = "cli://agy --output-format json models"
    try:
        completed = subprocess.run(
            [binary, "--output-format", "json", "models"],
            check=True,
            capture_output=True,
            text=True,
            timeout=30,
        )
        payload = json.loads(completed.stdout)
        models = payload.get("command", {}).get("data", {}).get("models", [])
        if not isinstance(models, list):
            raise ValueError("command.data.models is not a list")
        for model in models:
            if not isinstance(model, dict) or not isinstance(model.get("id"), str):
                continue
            model_id = model["id"]
            add_current(
                upstream,
                "agy",
                model_id,
                label=model.get("label"),
                efforts=effort_from_model_id(model_id),
                source=source,
                evidence="AGY's metadata-only models command returned this selectable model.",
            )
        add_source(
            upstream, "agy", source, "ok", f"Read {len(models)} CLI model records."
        )
    except (OSError, subprocess.SubprocessError, ValueError, TypeError) as error:
        add_source(upstream, "agy", source, "error", str(error))


def collect_live_upstream(audit_date: dt.date, use_cli: bool) -> dict[str, Any]:
    upstream = empty_upstream()
    collectors = (
        ("claude", ANTHROPIC_LIFECYCLE_URL, collect_anthropic),
        ("codex", OPENAI_CURRENT_URL, collect_openai_current),
        (
            "codex",
            OPENAI_LIFECYCLE_URL,
            lambda data, doc: collect_openai_lifecycle(data, doc, audit_date),
        ),
    )
    for provider, url, collector in collectors:
        try:
            collector(upstream, fetch_url(url))
            add_source(upstream, provider, url, "ok")
        except RuntimeError as error:
            add_source(upstream, provider, url, "error", str(error))

    try:
        models_document = fetch_url(AGY_CURRENT_URL)
        cli_document = fetch_url(AGY_CLI_URL)
        collect_agy_docs(upstream, models_document, cli_document, audit_date)
        add_source(upstream, "agy", AGY_CURRENT_URL, "ok")
        add_source(upstream, "agy", AGY_CLI_URL, "ok")
    except RuntimeError as error:
        add_source(upstream, "agy", AGY_CURRENT_URL, "error", str(error))

    if use_cli:
        codex_home = Path(os.environ.get("CODEX_HOME", Path.home() / ".codex"))
        collect_codex_cache(upstream, codex_home / "models_cache.json")
        collect_agy_cli(upstream)
    return upstream


def catalog_defaults(provider_data: dict[str, Any]) -> set[str]:
    defaults: set[str] = set()
    if isinstance(provider_data.get("defaultModel"), str):
        defaults.add(provider_data["defaultModel"])
    for model_id, metadata in provider_data.get("models", {}).items():
        if metadata.get("ralphDefault") is True:
            defaults.add(model_id)
    return defaults


def find_upstream_record(
    records: dict[str, Any], identifiers: list[str]
) -> dict[str, Any] | None:
    wanted = {model_match_key(value) for value in identifiers}
    for upstream_id, record in records.items():
        upstream_keys = {model_match_key(upstream_id)}
        if record.get("label"):
            upstream_keys.add(model_match_key(record["label"]))
        if upstream_keys & wanted:
            return record
    return None


def finding(
    severity: str,
    kind: str,
    provider: str,
    model_id: str,
    message: str,
    catalog_metadata: dict[str, Any] | None,
    upstream_metadata: dict[str, Any],
    suggested_action: str,
    audited_at: str,
) -> dict[str, Any]:
    safe_kind = re.sub(r"[^a-z0-9-]+", "-", kind.lower()).strip("-")
    stable_model = re.sub(r"[^a-z0-9.-]+", "-", model_id.lower()).strip("-")
    return {
        "key": f"[model-audit][{provider}][{stable_model}][{safe_kind}]",
        "severity": severity,
        "kind": kind,
        "provider": provider,
        "model": model_id,
        "message": message,
        "catalog": {"id": model_id, "metadata": catalog_metadata}
        if catalog_metadata is not None
        else None,
        "upstream": upstream_metadata,
        "sourceUrls": upstream_metadata.get("sourceUrls", []),
        "suggestedAction": suggested_action,
        "auditedAt": audited_at,
    }


def compare_catalog(
    catalog: dict[str, Any], upstream: dict[str, Any], audited_at: str
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    findings: list[dict[str, Any]] = []
    observations: list[dict[str, Any]] = []
    for provider, provider_data in catalog.get("providers", {}).items():
        upstream_provider = upstream.get("providers", {}).get(
            provider, provider_record()
        )
        current = upstream_provider.get("currentModels", {})
        lifecycle = upstream_provider.get("lifecycle", {})
        defaults = catalog_defaults(provider_data)
        matched_current: set[str] = set()

        for model_id, metadata in provider_data.get("models", {}).items():
            identifiers = [
                model_id,
                *metadata.get("aliases", []),
                metadata.get("label", ""),
            ]
            current_record = find_upstream_record(current, identifiers)
            lifecycle_record = find_upstream_record(lifecycle, identifiers)
            if lifecycle_record is None and current_record is not None:
                lifecycle_record = find_upstream_record(
                    lifecycle,
                    [current_record["id"], current_record.get("label", "")],
                )
            is_default = model_id in defaults
            if current_record:
                matched_current.add(current_record["id"])
                upstream_efforts = current_record.get("efforts")
                catalog_efforts = metadata.get("efforts", [])
                if upstream_efforts is not None:
                    removed = sorted(set(catalog_efforts) - set(upstream_efforts))
                    added = sorted(set(upstream_efforts) - set(catalog_efforts))
                    if removed:
                        default_effort = metadata.get("defaultEffort")
                        severity = (
                            "CRITICAL"
                            if is_default and default_effort in removed
                            else "HIGH"
                        )
                        findings.append(
                            finding(
                                severity,
                                "effort-incompatible",
                                provider,
                                model_id,
                                f"Upstream no longer advertises catalog effort(s): {', '.join(removed)}.",
                                metadata,
                                current_record,
                                "Remove unsupported efforts and verify any configured default effort.",
                                audited_at,
                            )
                        )
                    if added:
                        findings.append(
                            finding(
                                "LOW",
                                "effort-metadata",
                                provider,
                                model_id,
                                f"Upstream advertises additional effort(s): {', '.join(added)}.",
                                metadata,
                                current_record,
                                "Review and add the newly supported efforts if Ralph should expose them.",
                                audited_at,
                            )
                        )
                upstream_label = current_record.get("label")
                if (
                    upstream_label
                    and clean_text(upstream_label).casefold()
                    != clean_text(metadata.get("label", "")).casefold()
                ):
                    findings.append(
                        finding(
                            "LOW",
                            "label-metadata",
                            provider,
                            model_id,
                            f"Catalog label differs from upstream label {upstream_label!r}.",
                            metadata,
                            current_record,
                            "Review the display label; this does not affect model selection.",
                            audited_at,
                        )
                    )

            if lifecycle_record:
                upstream_status = lifecycle_record["status"]
                catalog_status = metadata.get("status")
                if (
                    upstream_status in ("deprecated", "retired")
                    and catalog_status != upstream_status
                ):
                    severity = (
                        "CRITICAL"
                        if is_default and upstream_status == "retired"
                        else "HIGH"
                    )
                    findings.append(
                        finding(
                            severity,
                            "lifecycle",
                            provider,
                            model_id,
                            f"Upstream explicitly marks this model {upstream_status}; catalog says {catalog_status}.",
                            metadata,
                            lifecycle_record,
                            "Update lifecycle metadata and successor guidance; migrate a Ralph default immediately if affected.",
                            audited_at,
                        )
                    )
            elif not current_record and metadata.get("status") in ("active", "preview"):
                observations.append(
                    {
                        "kind": "could-not-confirm",
                        "provider": provider,
                        "model": model_id,
                        "message": (
                            "Model was absent from the current-model metadata, but no explicit "
                            "deprecation or retirement evidence was found. Lifecycle was not changed."
                        ),
                    }
                )

        catalog_ids = {
            model_match_key(identifier)
            for model_id, metadata in provider_data.get("models", {}).items()
            for identifier in [
                model_id,
                *metadata.get("aliases", []),
                metadata.get("label", ""),
            ]
        }
        for upstream_id, upstream_metadata in current.items():
            upstream_keys = {model_match_key(upstream_id)}
            if upstream_metadata.get("label"):
                upstream_keys.add(model_match_key(upstream_metadata["label"]))
            if upstream_id in matched_current or upstream_keys & catalog_ids:
                continue
            findings.append(
                finding(
                    "MEDIUM",
                    "new-stable-model",
                    provider,
                    upstream_id,
                    "Upstream lists a stable/current model that is absent from Ralph's catalog.",
                    None,
                    upstream_metadata,
                    "Verify CLI availability and add a catalog entry with lifecycle and effort metadata.",
                    audited_at,
                )
            )

    findings.sort(key=lambda item: (SEVERITIES.index(item["severity"]), item["key"]))
    observations.sort(key=lambda item: (item["provider"], item["model"]))
    return findings, observations


def render_summary(report: dict[str, Any]) -> str:
    counts = report["summary"]
    lines = [
        "# Ralph model catalog audit",
        "",
        f"Audited at: `{report['auditedAt']}`",
        "",
        (
            f"Findings: **{counts['total']}** "
            f"(CRITICAL {counts['CRITICAL']}, HIGH {counts['HIGH']}, "
            f"MEDIUM {counts['MEDIUM']}, LOW {counts['LOW']})."
        ),
        f"Upstream source errors: **{counts['sourceErrors']}**.",
        "",
    ]
    if report["findings"]:
        lines.extend(
            [
                "| Severity | Provider | Model | Finding |",
                "|---|---|---|---|",
            ]
        )
        for item in report["findings"]:
            message = item["message"].replace("|", "\\|")
            lines.append(
                f"| {item['severity']} | {item['provider']} | `{item['model']}` | {message} |"
            )
    else:
        lines.append("No catalog drift findings were detected.")

    lines.extend(["", "## Source status", ""])
    for provider, provider_data in report["upstream"]["providers"].items():
        for source in provider_data.get("sources", []):
            detail = f" — {source['detail']}" if source.get("detail") else ""
            lines.append(
                f"- **{provider}** `{source['status']}`: {source['url']}{detail}"
            )

    lines.extend(["", "## Could not confirm", ""])
    if report["observations"]:
        lines.append(
            "Absence from a current-model page is not retirement evidence. These entries remain unchanged:"
        )
        lines.append("")
        for item in report["observations"]:
            lines.append(
                f"- **{item['provider']}** `{item['model']}` — {item['message']}"
            )
    else:
        lines.append(
            "Every active/preview catalog model was confirmed or had explicit lifecycle evidence."
        )
    lines.append("")
    return "\n".join(lines)


def load_json(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise ValueError(f"{path} must contain a JSON object")
    return value


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog", type=Path, default=Path("config/models.json"))
    parser.add_argument("--report", type=Path, default=Path("model-audit-report.json"))
    parser.add_argument("--summary", type=Path, default=Path("model-audit-summary.md"))
    parser.add_argument(
        "--upstream-file",
        type=Path,
        help="Use normalized upstream JSON instead of network/CLI discovery.",
    )
    parser.add_argument(
        "--no-cli", action="store_true", help="Skip local CLI/cache metadata."
    )
    parser.add_argument(
        "--now",
        help="Override audit time (ISO-8601) for deterministic tests.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        now = (
            dt.datetime.fromisoformat(args.now.replace("Z", "+00:00"))
            if args.now
            else None
        )
        if now is None:
            now = dt.datetime.now(dt.timezone.utc)
        elif now.tzinfo is None:
            now = now.replace(tzinfo=dt.timezone.utc)
        now = now.astimezone(dt.timezone.utc)
        audited_at = now.isoformat().replace("+00:00", "Z")
        catalog = load_json(args.catalog)
        if catalog.get("schemaVersion") != 1 or not isinstance(
            catalog.get("providers"), dict
        ):
            raise ValueError(
                "catalog must use schemaVersion 1 and contain a providers object"
            )
        upstream = (
            load_json(args.upstream_file)
            if args.upstream_file
            else collect_live_upstream(now.date(), not args.no_cli)
        )
        upstream = copy.deepcopy(upstream)
        findings, observations = compare_catalog(catalog, upstream, audited_at)
        counts = {
            severity: sum(item["severity"] == severity for item in findings)
            for severity in SEVERITIES
        }
        source_errors = sum(
            source.get("status") == "error"
            for provider in upstream.get("providers", {}).values()
            for source in provider.get("sources", [])
        )
        report = {
            "schemaVersion": 1,
            "auditedAt": audited_at,
            "catalogPath": str(args.catalog),
            "summary": {
                "total": len(findings),
                **counts,
                "sourceErrors": source_errors,
            },
            "findings": findings,
            "observations": observations,
            "upstream": upstream,
        }
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.summary.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        summary = render_summary(report)
        args.summary.write_text(summary, encoding="utf-8")
        print(summary)
        return 0
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"model catalog audit failed: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
