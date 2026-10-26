#!/usr/bin/env python3
"""Summarize application events; preserve operation time intervals, not guessed order."""
import argparse
import collections
import csv
import json
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("trace", type=Path)
    args = parser.parse_args()
    comments = []
    counts = collections.Counter()
    maxima = {}
    faults = []
    events = 0
    with args.trace.open() as stream:
        def data_lines():
            for line in stream:
                if line.startswith("#"):
                    comments.append(line.strip())
                else:
                    yield line
        for raw in csv.DictReader(data_lines()):
            row = {key: int(value) for key, value in raw.items()}
            events += 1
            counts[row["kind"]] += 1
            if row["kind"] == 3:
                key = f"{row['ifindex']}/{row['id']}"
                maxima[key] = max(maxima.get(key, row["after"]), row["after"])
            if row["kind"] == 7:
                faults.append(row)
    print(json.dumps({
        "events": events, "kinds": counts, "capture_metadata": comments,
        "dump_complete": "# dump_complete=1" in comments,
        "faults": faults,
        "max_check_by_motor": maxima,
        "note": "Counter operations occurred within [start_ns,end_ns]. Overlapping intervals have no inferred total order. Read events occur after read returns; kernel dequeue must be correlated separately."
    }, indent=2))


if __name__ == "__main__":
    main()
