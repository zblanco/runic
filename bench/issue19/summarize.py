"""Summarize independent timing rows without confusing samples and passes."""
import csv
import pathlib
import statistics
import sys
from collections import defaultdict

groups = defaultdict(list)
for path in pathlib.Path(sys.argv[1]).glob("*.csv"):
    lines = path.read_text().splitlines()
    header = next((i for i, line in enumerate(lines) if line.startswith("label,pass,")), None)
    if header is None:
        continue
    for row in csv.DictReader(lines[header:]):
        if row.get("pass") not in {"timing", "memory", "envelopes"}:
            continue
        key = tuple(row[k] for k in ["label", "case", "n", "preparation", "execution", "coordination", "limit"])
        groups[key].append(row)

writer = csv.writer(sys.stdout, lineterminator="\n")
writer.writerow(["label", "case", "n", "preparation", "execution", "coordination", "limit",
                 "timing_samples", "median_ms", "owner_peak_MiB", "tree_peak_MiB",
                 "referenced_binary_peak_MiB", "requests_MiB", "responses_MiB",
                 "fan_in_prepared", "max_prepared", "facts", "edges"])
for key, rows in sorted(groups.items()):
    timings = [int(r["elapsed_us"]) / 1000 for r in rows if r["pass"] == "timing"]
    mem = next((r for r in rows if r["pass"] == "memory"), {})
    env = next((r for r in rows if r["pass"] == "envelopes"), {})
    first = rows[0]
    mib = lambda r, k: round(int(r[k]) / 1048576, 3) if r.get(k) else ""
    writer.writerow([*key, len(timings), round(statistics.median(timings), 3) if timings else "",
                     *(mib(mem, k) for k in ["owner_peak_bytes", "tree_peak_bytes", "referenced_binary_peak_bytes"]),
                     *(mib(env, k) for k in ["request_bytes", "response_bytes"]),
                     *(first[k] for k in ["fan_in_prepared", "max_prepared", "facts", "edges"])])
