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
    queue_restores = []
    startup_network = []
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
            elif name == "queue-restore-complete":
                queue_restores.append({
                    "storedTrackCount": values.get("storedTrackCount"),
                    "durationMs": values.get("durationMs"),
                    "emittedAt": record.get("emittedAt"),
                })
            elif name == "startup-network-summary":
                startup_network.append({
                    "requestCount": values.get("requestCount"),
                    "responseBytes": values.get("responseBytes"),
                    "durationMicrosTotal": values.get("durationMicrosTotal"),
                    "durationMicrosMax": values.get("durationMicrosMax"),
                    "emittedAt": record.get("emittedAt"),
                })
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

        numeric_metrics = defaultdict(list)
        event_elapsed = defaultdict(list)
        for run in runs:
            for metric_name, metric_value in (run.get("metrics") or {}).items():
                if isinstance(metric_value, (int, float)) and not isinstance(metric_value, bool):
                    numeric_metrics[metric_name].append(float(metric_value))
            for event in run.get("events") or []:
                event_name = event.get("name")
                elapsed = event.get("elapsedMicros")
                if isinstance(event_name, str) and isinstance(elapsed, int):
                    event_elapsed[event_name].append(elapsed)

        metric_summary = {
            metric_name: {
                "median": statistics.median(values),
                "p90": p90(values),
                "min": min(values),
                "max": max(values),
            }
            for metric_name, values in sorted(numeric_metrics.items())
            if values
        }

        event_summary = {
            event_name: {
                "medianMsFromRunStart": ms(statistics.median(values)),
                "p90MsFromRunStart": ms(p90(values)),
                "minMsFromRunStart": ms(min(values)),
                "maxMsFromRunStart": ms(max(values)),
            }
            for event_name, values in sorted(event_elapsed.items())
            if values
        }

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
            "numericMetrics": metric_summary,
            "eventMilestones": event_summary,
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
        "startupNetwork": startup_network,
        "queueRestores": queue_restores,
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
        "## Startup network",
        "",
        "| Requests | Response bytes | HTTP total ms | HTTP max ms |",
        "|---:|---:|---:|---:|",
    ])
    if startup_network:
        for item in startup_network:
            total_us = item.get("durationMicrosTotal")
            max_us = item.get("durationMicrosMax")
            total_ms = "" if not isinstance(total_us, (int, float)) else round(total_us / 1000.0, 3)
            max_ms = "" if not isinstance(max_us, (int, float)) else round(max_us / 1000.0, 3)
            lines.append(
                f"| {item.get('requestCount', '')} | {item.get('responseBytes', '')} | "
                f"{total_ms} | {max_ms} |"
            )
    else:
        lines.append("|  |  |  |  |")

    lines.extend([
        "",
        "## Queue restore",
        "",
        "| Stored tracks | Duration ms |",
        "|---:|---:|",
    ])
    if queue_restores:
        for item in queue_restores:
            lines.append(
                f"| {item.get('storedTrackCount', '')} | {item.get('durationMs', '')} |"
            )
    else:
        lines.append("|  |  |")

    lines.extend([
        "",
        "## Scenario groups",
        "",
        "| Scenario | Mode | Target | Runs | Median ms | p90 ms | HTTP req med | HTTP total ms med | HTTP max ms med | Bytes med | RSS Δ MiB med | >50ms frames med | Results |",
        "|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|",
    ])
    for item in summary_groups:
        target = item["targetAlias"] or item["targetType"] or ""
        results = ", ".join(
            f"{name}:{count}" for name, count in sorted(item["results"].items())
        )
        median = "" if item["medianMs"] is None else f"{item['medianMs']:.3f}"
        p90_value = "" if item["p90Ms"] is None else f"{item['p90Ms']:.3f}"
        metrics = item.get("numericMetrics") or {}
        http_requests = metrics.get("httpRequestCount", {}).get("median", "")
        http_total_us = metrics.get("httpDurationMicrosTotal", {}).get("median")
        http_max_us = metrics.get("httpDurationMicrosMax", {}).get("median")
        response_bytes = metrics.get("httpResponseBytes", {}).get("median", "")
        rss_delta = metrics.get("rssDeltaBytes", {}).get("median")
        frames_50 = metrics.get("framesOver50ms", {}).get("median", "")
        http_total_ms = "" if http_total_us is None else round(http_total_us / 1000.0, 3)
        http_max_ms = "" if http_max_us is None else round(http_max_us / 1000.0, 3)
        rss_delta_mib = "" if rss_delta is None else round(rss_delta / (1024 * 1024), 3)
        lines.append(
            f"| {item['scenario']} | {item['mode']} | {target} | {item['runs']} | "
            f"{median} | {p90_value} | {http_requests} | {http_total_ms} | "
            f"{http_max_ms} | {response_bytes} | {rss_delta_mib} | "
            f"{frames_50} | {results} |"
        )

    problem_groups = [
        item for item in summary_groups
        if any(name != "success" and count > 0 for name, count in item["results"].items())
    ]
    lines.extend([
        "",
        "## Non-successful runs",
        "",
        "| Scenario | Mode | Target | Results |",
        "|---|---|---|---|",
    ])
    if problem_groups:
        for item in problem_groups:
            target = item["targetAlias"] or item["targetType"] or ""
            results = ", ".join(
                f"{name}:{count}" for name, count in sorted(item["results"].items())
            )
            lines.append(
                f"| {item['scenario']} | {item['mode']} | {target} | {results} |"
            )
    else:
        lines.append("| none |  |  | all recorded runs successful |")

    slowest = sorted(
        [item for item in summary_groups if item["medianMs"] is not None],
        key=lambda item: item["medianMs"],
        reverse=True,
    )[:25]
    lines.extend([
        "",
        "## Slowest scenario groups",
        "",
        "| Scenario | Mode | Target | Median ms | p90 ms |",
        "|---|---|---|---:|---:|",
    ])
    for item in slowest:
        target = item["targetAlias"] or item["targetType"] or ""
        p90_value = "" if item["p90Ms"] is None else f"{item['p90Ms']:.3f}"
        lines.append(
            f"| {item['scenario']} | {item['mode']} | {target} | "
            f"{item['medianMs']:.3f} | {p90_value} |"
        )

    lines.extend([
        "",
        "## Event milestones",
        "",
        "Milestones below are measured from each scenario run start. Full details remain in the JSON summary.",
        "",
        "| Scenario | Mode | Target | Event | Median ms | p90 ms |",
        "|---|---|---|---|---:|---:|",
    ])
    for item in summary_groups:
        target = item["targetAlias"] or item["targetType"] or ""
        for event_name, event_values in item.get("eventMilestones", {}).items():
            if event_name in {"run-start", "run-end"}:
                continue
            lines.append(
                f"| {item['scenario']} | {item['mode']} | {target} | {event_name} | "
                f"{event_values['medianMsFromRunStart']:.3f} | "
                f"{event_values['p90MsFromRunStart']:.3f} |"
            )

    Path(args.md_out).write_text("\n".join(lines) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
