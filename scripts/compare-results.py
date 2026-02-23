#!/usr/bin/env python3
"""
Generate comparison report from benchmark results.
Usage: ./compare-results.py results/*.json > comparison.md
"""

import json
import sys
from pathlib import Path
from collections import defaultdict


def load_results(files):
    """Load all result files into a structured dict."""
    results = defaultdict(lambda: defaultdict(dict))

    for f in files:
        try:
            with open(f) as fp:
                data = json.load(fp)
                # Use filename as fallback, but prefer JSON fields
                stem = Path(f).stem
                parts = stem.split('_')
                server = data.get('server', parts[0] if parts else 'unknown')
                scenario = data.get('scenario', parts[1] if len(parts) > 1 else 'unknown')

                # Validate server matches filename to catch stale results
                expected_server = parts[0] if parts else None
                if expected_server and server != expected_server:
                    print(f"Warning: {f} claims server='{server}' but filename says '{expected_server}' (stale result?)",
                          file=sys.stderr)
                    continue

                results[scenario][server] = data.get('metrics', {})
        except (json.JSONDecodeError, IOError) as e:
            print(f"Warning: Could not load {f}: {e}", file=sys.stderr)

    return results


def format_number(n, decimals=2):
    """Format number with commas and decimal places."""
    if n is None:
        return 'N/A'
    if isinstance(n, float):
        return f"{n:,.{decimals}f}"
    return f"{n:,}"


def generate_report(results):
    """Generate markdown comparison report."""
    lines = []
    lines.append("# Benchmark Comparison Report")
    lines.append("")
    lines.append(f"Generated: {__import__('datetime').datetime.now().isoformat()}")
    lines.append("")

    for scenario, servers in sorted(results.items()):
        lines.append(f"## {scenario.title()}")
        lines.append("")

        # Build comparison table — include metrics that exist in ANY server
        metrics_to_compare = [
            ('requests_per_second', 'Requests/sec', 0),
            ('requests_per_second_avg', 'Requests/sec (avg)', 0),
            ('connections_per_second', 'Connections/sec', 0),
            ('latency_avg_ms', 'Latency Avg (ms)', 2),
            ('latency_p50_ms', 'Latency p50 (ms)', 2),
            ('latency_p95_ms', 'Latency p95 (ms)', 2),
            ('latency_p99_ms', 'Latency p99 (ms)', 2),
            ('error_rate', 'Error Rate', 4),
        ]

        server_names = sorted(servers.keys())

        # Only include metric rows where at least one server has data
        active_metrics = []
        for metric_key, metric_name, decimals in metrics_to_compare:
            if any(servers[s].get(metric_key) is not None for s in server_names):
                active_metrics.append((metric_key, metric_name, decimals))

        # Header
        lines.append("| Metric | " + " | ".join(server_names) + " |")
        lines.append("|--------|" + "|".join(["--------"] * len(server_names)) + "|")

        # Rows
        for metric_key, metric_name, decimals in active_metrics:
            row = [metric_name]
            for server in server_names:
                value = servers[server].get(metric_key)
                row.append(format_number(value, decimals))
            lines.append("| " + " | ".join(row) + " |")

        lines.append("")

        # Winner analysis — check ALL servers, not just the first
        rps_key = None
        for key in ('requests_per_second', 'requests_per_second_avg', 'connections_per_second'):
            if any(servers[s].get(key) is not None for s in server_names):
                rps_key = key
                break

        if rps_key:
            rps_values = [(s, servers[s].get(rps_key)) for s in server_names]
            rps_values = [(s, v) for s, v in rps_values if v is not None and v > 0]
            if rps_values:
                winner = max(rps_values, key=lambda x: x[1])
                lines.append(f"**Throughput winner:** {winner[0]} ({format_number(winner[1], 0)} req/s)")

        lat_values = [(s, servers[s].get('latency_p99_ms')) for s in server_names]
        lat_values = [(s, v) for s, v in lat_values if v is not None and v > 0]
        if lat_values:
            winner = min(lat_values, key=lambda x: x[1])
            lines.append(f"**Latency winner (p99):** {winner[0]} ({format_number(winner[1])} ms)")

        lines.append("")

    return "\n".join(lines)


def main():
    if len(sys.argv) < 2:
        print("Usage: ./compare-results.py results/*.json", file=sys.stderr)
        sys.exit(1)

    files = sys.argv[1:]
    results = load_results(files)

    if not results:
        print("No valid results found", file=sys.stderr)
        sys.exit(1)

    report = generate_report(results)
    print(report)


if __name__ == '__main__':
    main()
