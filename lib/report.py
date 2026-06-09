#!/usr/bin/env python3
"""Generate a unified benchmark report from a results directory.

Usage: python3 report.py /path/to/results/YYYYMMDD_HHMMSS

Scans for .json (k6 results) and .txt (h2load results) files in
subdirectories (h1/, h2/, h3/, load-balancer/, api-gateway/, gateway-features/).
"""

import json
import os
import re
import sys
from datetime import datetime
from pathlib import Path


def parse_k6_json(path):
    """Parse a k6 JSON result file."""
    try:
        with open(path) as f:
            return json.load(f)
    except (json.JSONDecodeError, OSError):
        return None


def parse_h2load_txt(path):
    """Parse h2load text output into structured data."""
    try:
        text = Path(path).read_text()
    except OSError:
        return None

    result = {"raw": text}

    m = re.search(r"finished in ([\d.]+)(ms|s), ([\d.]+) req/s", text)
    if m:
        dur = float(m.group(1))
        if m.group(2) == "ms":
            dur /= 1000.0
        result["duration_s"] = dur
        result["req_per_sec"] = float(m.group(3))

    m = re.search(r"requests: (\d+) total.*?(\d+) succeeded.*?(\d+) failed", text)
    if m:
        result["requests_total"] = int(m.group(1))
        result["requests_succeeded"] = int(m.group(2))
        result["requests_failed"] = int(m.group(3))

    m = re.search(r"time for request:\s+([\d.]+\w+)\s+([\d.]+\w+)\s+([\d.]+\w+)", text)
    if m:
        result["latency_min"] = m.group(1)
        result["latency_max"] = m.group(2)
        result["latency_mean"] = m.group(3)

    return result


def fmt_num(n, decimals=0):
    """Format number with comma separators."""
    if isinstance(n, float):
        if decimals == 0:
            return f"{n:,.0f}"
        return f"{n:,.{decimals}f}"
    return f"{n:,}"


def fmt_ms(ms, decimals=2):
    """Format milliseconds."""
    if ms is None:
        return "N/A"
    return f"{ms:.{decimals}f}"


def extract_rps(m):
    """Extract req/s from various metric schemas."""
    for key in ("requests_per_second", "requests_per_second_avg",
                "connections_per_second", "rps"):
        if key in m and m[key]:
            return m[key]
    # Last resort: if we have requests_total, estimate
    if m.get("requests_total", 0) and not any(
        k.startswith("requests_per") for k in m
    ):
        return m["requests_total"]  # show total as-is (runner can infer /s)
    return 0


def extract_latency(m, percentile):
    """Extract latency percentile, checking multiple field names."""
    key = f"latency_{percentile}_ms"
    return m.get(key, 0) or 0


def report_h1(suite_dir):
    """Generate H1 core section."""
    files = sorted(Path(suite_dir).glob("*.json"))
    if not files:
        return ""

    lines = ["## H1 Core\n"]
    lines.append("| Test | Req/s | p95 (ms) | p99 (ms) | Errors |")
    lines.append("|------|------:|--------:|---------:|-------:|")

    for f in files:
        data = parse_k6_json(f)
        if not data or "metrics" not in data:
            continue
        m = data["metrics"]
        name = data.get("scenario", f.stem)
        rps = extract_rps(m)
        p95 = extract_latency(m, "p95")
        p99 = extract_latency(m, "p99")
        err = m.get("error_rate", 0) or 0
        lines.append(f"| {name} | {fmt_num(rps)} | {fmt_ms(p95)} | {fmt_ms(p99)} | {err:.4f} |")

    lines.append("")
    return "\n".join(lines)


def report_h2(suite_dir):
    """Generate TLS/H2 section."""
    files = sorted(Path(suite_dir).glob("*.json"))
    if not files:
        return ""

    lines = ["## TLS + HTTP/2\n"]
    lines.append("| Test | Req/s | p95 (ms) | p99 (ms) | Errors |")
    lines.append("|------|------:|--------:|---------:|-------:|")

    for f in files:
        data = parse_k6_json(f)
        if not data or "metrics" not in data:
            continue
        m = data["metrics"]
        name = data.get("scenario", f.stem)
        rps = extract_rps(m)
        p95 = extract_latency(m, "p95")
        p99 = extract_latency(m, "p99")
        err = m.get("error_rate", 0) or 0
        lines.append(f"| {name} | {fmt_num(rps)} | {fmt_ms(p95)} | {fmt_ms(p99)} | {err:.4f} |")

    lines.append("")
    return "\n".join(lines)


def report_h3(suite_dir):
    """Generate H3 section."""
    files = sorted(Path(suite_dir).glob("*.txt"))
    if not files:
        return ""

    lines = ["## HTTP/3 (QUIC)\n"]
    lines.append("| Test | Req/s | Duration | Succeeded | Failed |")
    lines.append("|------|------:|---------:|----------:|-------:|")

    for f in files:
        data = parse_h2load_txt(f)
        if not data:
            continue
        name = f.stem.replace("swerver_", "")
        rps = data.get("req_per_sec", 0)
        dur = data.get("duration_s", 0)
        succ = data.get("requests_succeeded", 0)
        fail = data.get("requests_failed", 0)
        lines.append(f"| {name} | {fmt_num(rps)} | {dur:.1f}s | {fmt_num(succ)} | {fmt_num(fail)} |")

    lines.append("")
    return "\n".join(lines)


def report_scenario(suite_dir, title):
    """Generate a proxy/gateway scenario section."""
    files = sorted(Path(suite_dir).glob("*.json"))
    if not files:
        return ""

    lines = [f"## {title}\n"]

    for f in files:
        data = parse_k6_json(f)
        if not data:
            continue
        name = f.stem
        m = data.get("metrics", {})

        # Handle nested metrics (auth-overhead has noauth/apikey/jwt sub-objects)
        if any(isinstance(v, dict) for v in m.values()):
            lines.append(f"### {name}\n")
            lines.append("| Variant | Requests | Avg (ms) | p95 (ms) | p99 (ms) |")
            lines.append("|---------|--------:|---------:|---------:|---------:|")
            for k, v in m.items():
                if isinstance(v, dict):
                    reqs = v.get("requests", v.get("count", 0))
                    avg = v.get("latency_avg_ms", 0) or 0
                    p95 = v.get("latency_p95_ms", 0) or 0
                    p99 = v.get("latency_p99_ms", 0) or 0
                    lines.append(f"| {k} | {fmt_num(reqs)} | {fmt_ms(avg)} | {fmt_ms(p95)} | {fmt_ms(p99)} |")
            lines.append("")
        else:
            rps = extract_rps(m)
            p95 = extract_latency(m, "p95")
            p99 = extract_latency(m, "p99")
            err = m.get("error_rate", 0) or 0
            lines.append(f"**{name}**: {fmt_num(rps)} req/s, p95={fmt_ms(p95)}ms, p99={fmt_ms(p99)}ms, errors={err:.4f}")

            # Distribution info (load-balancer)
            dist = data.get("distribution")
            if dist:
                lines.append("")
                for k, v in dist.items():
                    if isinstance(v, dict):
                        lines.append(f"  - {k}: {fmt_num(v.get('count', 0))} ({v.get('pct', '?')}%)")
            lines.append("")

    return "\n".join(lines)


def main():
    if len(sys.argv) < 2:
        print("Usage: report.py <results_dir>", file=sys.stderr)
        sys.exit(1)

    results_dir = Path(sys.argv[1])
    if not results_dir.is_dir():
        print(f"Not a directory: {results_dir}", file=sys.stderr)
        sys.exit(1)

    ts = results_dir.name
    print(f"# Benchmark Report — {ts}\n")
    print(f"Generated: {datetime.now().isoformat()}\n")

    sections = []

    if (results_dir / "h1").is_dir():
        sections.append(report_h1(results_dir / "h1"))
    if (results_dir / "h2").is_dir():
        sections.append(report_h2(results_dir / "h2"))
    if (results_dir / "h3").is_dir():
        sections.append(report_h3(results_dir / "h3"))
    if (results_dir / "load-balancer").is_dir():
        sections.append(report_scenario(results_dir / "load-balancer", "Load Balancer"))
    if (results_dir / "api-gateway").is_dir():
        sections.append(report_scenario(results_dir / "api-gateway", "API Gateway"))
    if (results_dir / "gateway-features").is_dir():
        sections.append(report_scenario(results_dir / "gateway-features", "Gateway Features"))

    # Also check flat layout (results directly in results_dir)
    flat_jsons = list(results_dir.glob("*.json"))
    if flat_jsons and not sections:
        sections.append(report_scenario(results_dir, "Results"))

    output = "\n".join(s for s in sections if s)
    if output:
        print(output)
    else:
        print("No result files found.")

    # Summary stats
    total_json = sum(1 for _ in results_dir.rglob("*.json"))
    total_txt = sum(1 for _ in results_dir.rglob("*.txt"))
    print(f"\n---\n*{total_json} JSON + {total_txt} text result files collected.*")


if __name__ == "__main__":
    main()
