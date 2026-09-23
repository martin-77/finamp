#!/usr/bin/env python3
import argparse
import json
import math
import statistics
from collections import defaultdict
from pathlib import Path


def p90(values):
    if not values:
        return None
    ordered = sorted(values)
    idx = max(0, math.ceil(0.90 * len(ordered)) - 1)
    return ordered[idx]


def ms(value):
    return round(value / 1000.0, 3)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("jsonl")
    parser.add_argument("--json-out", required=True)
    parser.add_argument("--md-out", required=True)
    args = parser.parse_args()

    source = Path(args.jsonl)
    groups = defaultdict(list)
    startup_tasks = defaultdict(list)
    phases = []
    diagnostics = []

    for raw in source.read_text(encoding="utf-8").splitlines():
        if not raw.strip():
            continue
        try:
            record = json.loads(raw)
        except json.JSONDecodeError:
            continue

        if record.get("type") == "run-end":
            run = record.get("run") or {}
            key = (
                run.get("scenario", "unknown"),
                run.get("mode", "unknown"),
                run.get("targetType"),
                run.get("targetAlias"),
            )
            groups[key].append(run)
        elif record.get("type") == "diagnostic":
            name = record.get("name")
            values = record.get("values") or {}
            if name == "startup-task-complete":
                duration = values.get("durationMs")
                task = values.get("task")
                if isinstance(duration, (int, float)) and isinstance(task, str):
                    startup_tasks[task].append(float(duration))
            elif name == "suite-phase-complete":
                phase = values.get("phase")
                if phase:
                    phases.append(phase)
            elif name in {
                "startup-main-init-complete",
                "startup-first-frame",
                "startup-quiescent",
                "network-quiescent",
                "startup-baseline-complete",
                "host-restart-requested",
                "suite-complete",
            }:
                diagnostics.append({
                    "name": name,
                    "emittedAt": record.get("emittedAt"),
                    "values": values,
                })

    summary_groups = []
    for key, runs in sorted(groups.items(), key=lambda x: tuple("" if v is None else str(v) for v in x[0])):
        durations = [
            int(run.get("durationMicros", 0))
            for run in runs
            if isinstance(run.get("durationMicros"), int)
        ]
        results = defaultdict(int)
        for run in runs:
            results[str(run.get("result", "unknown"))] += 1

        summary_groups.append({
            "scenario": key[0],
            "mode": key[1],
            "targetType": key[2],
            "targetAlias": key[3],
            "runs": len(runs),
            "medianMs": ms(statistics.median(durations)) if durations else None,
            "p90Ms": ms(p90(durations)) if durations else None,
            "minMs": ms(min(durations)) if durations else None,
            "maxMs": ms(max(durations)) if durations else None,
            "results": dict(results),
        })

    startup_summary = []
    for task, durations in sorted(startup_tasks.items()):
        startup_summary.append({
            "task": task,
            "runs": len(durations),
            "medianMs": round(statistics.median(durations), 3),
            "p90Ms": round(p90(durations), 3),
            "minMs": round(min(durations), 3),
            "maxMs": round(max(durations), 3),
        })

    output = {
        "source": source.name,
        "completedPhases": phases,
        "startupTasks": startup_summary,
        "groups": summary_groups,
        "milestones": diagnostics,
    }
    Path(args.json_out).write_text(
        json.dumps(output, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )

    lines = [
        "# Finamp performance benchmark summary",
        "",
        f"Source: `{source.name}`",
        "",
        "## Completed phases",
        "",
    ]
    lines.extend(f"- {phase}" for phase in phases)
    if not phases:
        lines.append("- none recorded")

    lines.extend([
        "",
        "## Startup tasks",
        "",
        "| Task | Runs | Median ms | p90 ms | Min ms | Max ms |",
        "|---|---:|---:|---:|---:|---:|",
    ])
    for item in startup_summary:
        lines.append(
            f"| {item['task']} | {item['runs']} | {item['medianMs']:.3f} | "
            f"{item['p90Ms']:.3f} | {item['minMs']:.3f} | {item['maxMs']:.3f} |"
        )

    lines.extend([
        "",
        "## Scenario groups",
        "",
        "| Scenario | Mode | Target | Runs | Median ms | p90 ms | Results |",
        "|---|---|---|---:|---:|---:|---|",
    ])
    for item in summary_groups:
        target = item["targetAlias"] or item["targetType"] or ""
        results = ", ".join(
            f"{name}:{count}" for name, count in sorted(item["results"].items())
        )
        median = "" if item["medianMs"] is None else f"{item['medianMs']:.3f}"
        p90_value = "" if item["p90Ms"] is None else f"{item['p90Ms']:.3f}"
        lines.append(
            f"| {item['scenario']} | {item['mode']} | {target} | {item['runs']} | "
            f"{median} | {p90_value} | {results} |"
        )

    Path(args.md_out).write_text("\n".join(lines) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
