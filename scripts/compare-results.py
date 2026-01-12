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
                server = data.get('server', Path(f).stem.split('_')[0])
                scenario = data.get('scenario', Path(f).stem.split('_')[1] if '_' in Path(f).stem else 'unknown')
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

        # Build comparison table
        metrics_to_compare = [
            ('requests_per_second', 'Requests/sec', 0),
            ('latency_avg_ms', 'Latency Avg (ms)', 2),
            ('latency_p50_ms', 'Latency p50 (ms)', 2),
            ('latency_p95_ms', 'Latency p95 (ms)', 2),
            ('latency_p99_ms', 'Latency p99 (ms)', 2),
            ('error_rate', 'Error Rate', 4),
        ]

        server_names = sorted(servers.keys())

        # Header
        lines.append("| Metric | " + " | ".join(server_names) + " |")
        lines.append("|--------|" + "|".join(["--------"] * len(server_names)) + "|")

        # Rows
        for metric_key, metric_name, decimals in metrics_to_compare:
            row = [metric_name]
            for server in server_names:
                value = servers[server].get(metric_key)
                row.append(format_number(value, decimals))
            lines.append("| " + " | ".join(row) + " |")

        lines.append("")

        # Winner analysis
        if 'requests_per_second' in servers.get(server_names[0], {}):
            rps_values = [(s, servers[s].get('requests_per_second', 0)) for s in server_names]
            winner = max(rps_values, key=lambda x: x[1] or 0)
            lines.append(f"**Throughput winner:** {winner[0]} ({format_number(winner[1], 0)} req/s)")

        if 'latency_p99_ms' in servers.get(server_names[0], {}):
            lat_values = [(s, servers[s].get('latency_p99_ms', float('inf'))) for s in server_names]
            winner = min(lat_values, key=lambda x: x[1] if x[1] else float('inf'))
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
