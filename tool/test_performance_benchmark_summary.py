#!/usr/bin/env python3
import json
import subprocess
import sys
import tempfile
from pathlib import Path


def main():
    tool_dir = Path(__file__).resolve().parent
    summarizer = tool_dir / "summarize_performance_benchmark.py"

    records = [
        {
            "type": "run-end",
            "run": {
                "scenario": "alphabet-jump-tracks-Z",
                "mode": "refreshed-sequential",
                "targetType": "tracks",
                "targetAlias": None,
                "durationMicros": 1_250_000,
                "result": "success",
                "metrics": {
                    "alphabetJumpPagesLoaded": 47,
                    "pageItemsAdded": 100,
                    "rssDeltaBytes": 123456,
                },
                "events": [],
            },
        },
        {
            "type": "diagnostic",
            "name": "startup-image-cache-index-loaded",
            "emittedAt": "2026-09-23T12:00:00Z",
            "values": {
                "persistentEntryCount": 4321,
                "mappedPlayerEntries": 321,
            },
        },
        {
            "type": "diagnostic",
            "name": "suite-phase-complete",
            "emittedAt": "2026-09-23T12:00:01Z",
            "values": {
                "phase": "synthetic",
                "rssBytes": 1000000,
                "maxRssBytes": 2000000,
                "processElapsedMs": 123.0,
            },
        },
    ]

    with tempfile.TemporaryDirectory() as temp:
        temp_dir = Path(temp)
        jsonl = temp_dir / "input.jsonl"
        json_out = temp_dir / "summary.json"
        md_out = temp_dir / "summary.md"

        jsonl.write_text(
            "".join(json.dumps(record) + "\n" for record in records),
            encoding="utf-8",
        )

        subprocess.run(
            [
                sys.executable,
                str(summarizer),
                str(jsonl),
                "--json-out",
                str(json_out),
                "--md-out",
                str(md_out),
            ],
            check=True,
        )

        summary = json.loads(json_out.read_text(encoding="utf-8"))
        group = summary["groups"][0]
        metrics = group["numericMetrics"]

        assert "alphabetJumpPagesLoaded" not in metrics
        assert "pageItemsAdded" in metrics

        image_cache = summary["startupImageCache"][0]
        assert image_cache["persistentEntryBucket"] == "1000-4999"
        assert image_cache["mappedPlayerEntryBucket"] == "100-999"
        assert "persistentEntryCount" not in image_cache
        assert "mappedPlayerEntries" not in image_cache

        markdown = md_out.read_text(encoding="utf-8")
        assert "4321" not in markdown
        assert "321" not in markdown
        assert "1000-4999" in markdown
        assert "100-999" in markdown

    print("performance benchmark summary self-test passed")


if __name__ == "__main__":
    main()
