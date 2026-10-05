#!/usr/bin/env python3

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
AUDIT_SCRIPT = REPO_ROOT / "scripts" / "audit-model-catalog.py"


def model(label, status="active", efforts=None, default_effort=None, **extra):
    return {
        "label": label,
        "status": status,
        "efforts": efforts or [],
        "defaultEffort": default_effort,
        "aliases": [],
        "successor": None,
        "minCliVersion": None,
        "source": "test",
        "notes": "",
        **extra,
    }


class AuditModelCatalogTest(unittest.TestCase):
    def run_audit(self, catalog, upstream):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            catalog_path = root / "catalog.json"
            upstream_path = root / "upstream.json"
            report_path = root / "report.json"
            summary_path = root / "summary.md"
            catalog_path.write_text(json.dumps(catalog), encoding="utf-8")
            upstream_path.write_text(json.dumps(upstream), encoding="utf-8")
            completed = subprocess.run(
                [
                    sys.executable,
                    str(AUDIT_SCRIPT),
                    "--catalog",
                    str(catalog_path),
                    "--upstream-file",
                    str(upstream_path),
                    "--report",
                    str(report_path),
                    "--summary",
                    str(summary_path),
                    "--now",
                    "2026-10-05T12:00:00Z",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            return json.loads(report_path.read_text()), summary_path.read_text()

    def test_classifies_all_severities_and_preserves_uncertain_lifecycle(self):
        catalog = {
            "schemaVersion": 1,
            "providers": {
                "claude": {
                    "models": {
                        "default-retired": model(
                            "Default retired",
                            efforts=["high"],
                            default_effort="high",
                            ralphDefault=True,
                        ),
                        "effort-changed": model(
                            "Effort changed", efforts=["low", "high"]
                        ),
                        "label-old": model("Old label", efforts=["medium"]),
                        "missing-without-evidence": model("Missing"),
                    }
                }
            },
        }
        upstream = {
            "providers": {
                "claude": {
                    "sources": [
                        {"url": "https://example.test", "status": "ok", "detail": ""}
                    ],
                    "currentModels": {
                        "effort-changed": {
                            "id": "effort-changed",
                            "label": "Effort changed",
                            "status": "active",
                            "efforts": ["low"],
                            "sourceUrls": ["https://example.test"],
                            "evidence": "explicit efforts",
                        },
                        "label-old": {
                            "id": "label-old",
                            "label": "New label",
                            "status": "active",
                            "efforts": ["medium", "high"],
                            "sourceUrls": ["https://example.test"],
                            "evidence": "current metadata",
                        },
                        "brand-new": {
                            "id": "brand-new",
                            "label": "Brand new",
                            "status": "active",
                            "efforts": None,
                            "sourceUrls": ["https://example.test"],
                            "evidence": "current model",
                        },
                    },
                    "lifecycle": {
                        "default-retired": {
                            "id": "default-retired",
                            "status": "retired",
                            "sourceUrls": ["https://example.test/deprecations"],
                            "evidence": "explicit retirement",
                        }
                    },
                }
            }
        }

        report, summary = self.run_audit(catalog, upstream)
        self.assertEqual(
            report["summary"],
            {
                "total": 5,
                "CRITICAL": 1,
                "HIGH": 1,
                "MEDIUM": 1,
                "LOW": 2,
                "sourceErrors": 0,
            },
        )
        self.assertEqual(
            {item["kind"] for item in report["findings"]},
            {
                "lifecycle",
                "effort-incompatible",
                "new-stable-model",
                "label-metadata",
                "effort-metadata",
            },
        )
        self.assertEqual(report["observations"][0]["model"], "missing-without-evidence")
        self.assertIn("Lifecycle was not changed", report["observations"][0]["message"])
        self.assertIn("## Could not confirm", summary)

    def test_alias_matches_upstream_and_prevents_false_new_model(self):
        catalog = {
            "schemaVersion": 1,
            "providers": {
                "agy": {
                    "models": {
                        "gpt-oss-120b-medium": {
                            **model("GPT-OSS 120B (Medium)", efforts=["medium"]),
                            "aliases": ["gpt-oss-120b"],
                        }
                    }
                }
            },
        }
        upstream = {
            "providers": {
                "agy": {
                    "sources": [],
                    "currentModels": {
                        "gpt-oss-120b": {
                            "id": "gpt-oss-120b",
                            "label": "GPT-OSS 120B (Medium)",
                            "status": "active",
                            "efforts": ["medium"],
                            "sourceUrls": ["https://example.test"],
                            "evidence": "current",
                        }
                    },
                    "lifecycle": {},
                }
            }
        }
        report, _ = self.run_audit(catalog, upstream)
        self.assertEqual(report["findings"], [])
        self.assertEqual(report["observations"], [])

    def test_unsupported_default_effort_is_critical(self):
        catalog = {
            "schemaVersion": 1,
            "providers": {
                "codex": {
                    "models": {
                        "default-model": model(
                            "Default model",
                            efforts=["low", "high"],
                            default_effort="high",
                            ralphDefault=True,
                        )
                    }
                }
            },
        }
        upstream = {
            "providers": {
                "codex": {
                    "sources": [],
                    "currentModels": {
                        "default-model": {
                            "id": "default-model",
                            "label": "Default model",
                            "status": "active",
                            "efforts": ["low"],
                            "sourceUrls": ["cli-cache://codex/models_cache.json"],
                            "evidence": "high effort removed",
                        }
                    },
                    "lifecycle": {},
                }
            }
        }
        report, _ = self.run_audit(catalog, upstream)
        self.assertEqual(report["summary"]["CRITICAL"], 1)
        self.assertEqual(report["findings"][0]["kind"], "effort-incompatible")


if __name__ == "__main__":
    unittest.main()
