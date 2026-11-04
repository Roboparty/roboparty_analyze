#!/usr/bin/env python3
# Copyright (C) 2026 wentywenty
# SPDX-License-Identifier: GPL-3.0
"""Align seven RoboPi diagnostic dimensions on one Unix timestamp axis."""

import argparse
import csv
import datetime as dt
import json
import re
import shutil
import subprocess
from pathlib import Path


def event(rows, dimension, timestamp, kind, detail, **extra):
    if timestamp is not None:
        row = {"timestamp": timestamp, "time_local": dt.datetime.fromtimestamp(timestamp).isoformat(),
               "dimension": dimension, "kind": kind, "detail": detail}
        row.update(extra)
        rows.append(row)


def read_manifest(path):
    return json.loads(path.read_text(encoding="utf-8"))


# Only these count toward can-asc: can.log also carries native-bus frames
# (can_top/can_hipnuc/can_bottom) since capture listens on "any".
CAN_INTERFACES = ("can0", "can1", "can2", "can3")

# Split-mode outputs: dimension -> (file, columns). "session" events are not
# listed here on purpose — start/end live in summary.json, and only the
# optional merged timeline keeps them as rows.
DIMENSION_OUTPUTS = {
    "can-asc": ("can_frames.csv", ("timestamp", "time_local", "kind", "interface", "frame")),
    "bms": ("bms.csv", ("timestamp", "time_local", "kind", "voltage", "current", "soc", "power", "detail")),
    "dmesg": ("dmesg.csv", ("timestamp", "time_local", "kind", "detail")),
    "hpm-uart": ("hpm_uart.csv", ("timestamp", "time_local", "kind", "detail")),
    "thermal": ("thermal.csv", ("timestamp", "time_local", "kind", "detail")),
    "inference-session": ("inference.csv", ("timestamp", "time_local", "kind", "detail")),
    "can-details": ("can_details.csv", ("timestamp", "time_local", "kind", "detail")),
    "usb-pcap": ("usb_pcap.csv", ("timestamp", "time_local", "kind", "file")),
}

MERGED_FIELDNAMES = ("timestamp", "time_local", "dimension", "kind", "detail")


def parse_can(path, rows):
    first = last = None
    for line in path.read_text(errors="replace").splitlines():
        match = re.match(r"\((\d+\.\d+)\)\s+(\S+)\s+(\S+)", line)
        if not match or match.group(2) not in CAN_INTERFACES:
            continue
        timestamp = float(match.group(1))
        first = timestamp if first is None else first
        last = timestamp
        event(rows, "can-asc", timestamp, "frame", f"{match.group(2)} {match.group(3)}",
              interface=match.group(2), frame=match.group(3))
    return first, last


def parse_unix_lines(path, rows, dimension):
    if not path.exists():
        return
    for line in path.read_text(errors="replace").splitlines():
        match = re.match(r"(?:[^ ]+\s+)?(\d+\.\d+)\s+(.*)", line)
        if match:
            event(rows, dimension, float(match.group(1)), "log", match.group(2))


BMS_LINE = re.compile(
    r"(\d+\.\d+)\s+\S+\s+\S+.*?\[BMS Data\] Voltage: (\d+(?:\.\d+)?)V"
    r" \| Current: (\d+(?:\.\d+)?)A \| SoC: (\d+)% \| Power: (\S+)")


def parse_bms(path, rows):
    """Parse bms_daemon lines into structured voltage/current/soc/power events."""
    if not path.exists():
        return
    for line in path.read_text(errors="replace").splitlines():
        match = BMS_LINE.match(line)
        if not match:
            continue
        detail = json.dumps({"voltage": float(match.group(2)),
                             "current": float(match.group(3)),
                             "soc": int(match.group(4)),
                             "power": match.group(5)},
                            separators=(",", ":"))
        event(rows, "bms", float(match.group(1)), "sample", detail,
              voltage=float(match.group(2)), current=float(match.group(3)),
              soc=int(match.group(4)), power=match.group(5))


def parse_marked_snapshot(path, rows, dimension):
    if not path.exists():
        return
    timestamp = None
    details = []
    for line in path.read_text(errors="replace").splitlines():
        match = re.match(r"# captured_at_unix=(\d+(?:\.\d+)?)", line)
        if match:
            if timestamp is not None:
                event(rows, dimension, timestamp, "snapshot", "\\n".join(details))
            timestamp = float(match.group(1))
            details = []
        elif timestamp is not None:
            details.append(line)
    if timestamp is not None:
        event(rows, dimension, timestamp, "snapshot", "\\n".join(details))


def parse_dmesg(path, rows):
    if not path.exists():
        return
    for line in path.read_text(errors="replace").splitlines():
        match = re.match(r"(?:<\d+>)?\s*(\d{4}-\d{2}-\d{2}T\S+)\s+(.*)", line)
        if not match:
            continue
        value = match.group(1).replace("Z", "+00:00")
        try:
            timestamp = dt.datetime.fromisoformat(value).timestamp()
        except ValueError:
            continue
        event(rows, "dmesg", timestamp, "log", match.group(2))


def parse_inference(path, rows):
    if not path.exists():
        return
    for line in path.read_text(errors="replace").splitlines():
        match = re.search(r"\[(\d+(?:\.\d+)?)\]", line)
        if match:
            event(rows, "inference-session", float(match.group(1)), "log", line)
            continue
        match = re.search(r"\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d+(?:\.\d+)?)\]", line)
        if match:
            try:
                timestamp = dt.datetime.strptime(match.group(1), "%Y-%m-%d %H:%M:%S.%f").timestamp()
            except ValueError:
                continue
            event(rows, "inference-session", timestamp, "log", line)


def parse_can_details(path, rows):
    if not path.exists():
        return

    text = path.read_text(errors="replace")
    decoder = json.JSONDecoder()
    index = 0
    while index < len(text):
        while index < len(text) and text[index].isspace():
            index += 1
        if index >= len(text):
            break
        try:
            record, index = decoder.raw_decode(text, index)
        except json.JSONDecodeError:
            break
        try:
            timestamp = float(record.pop("captured_at_unix"))
        except (ValueError, TypeError, KeyError, AttributeError):
            continue
        event(rows, "can-details", timestamp, "sample", json.dumps(record, separators=(",", ":")))


def parse_usb(path, rows):
    if not path.exists() or not shutil_which("capinfos"):
        return
    result = subprocess.run(["capinfos", "-a", "-e", str(path)], capture_output=True, text=True, check=False)
    values = {}
    for line in result.stdout.splitlines():
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        values[key.strip().lower()] = value.strip()
    for key, kind in (("first packet time", "first-packet"), ("last packet time", "last-packet")):
        value = values.get(key)
        if value:
            try:
                timestamp = dt.datetime.fromisoformat(value).timestamp()
            except ValueError:
                continue
            event(rows, "usb-pcap", timestamp, kind, path.name, file=path.name)


def shutil_which(command):
    return shutil.which(command) is not None


def drop_outside_window(rows, manifest):
    started = manifest.get("started_at_unix")
    ended = manifest.get("ended_at_unix")
    if started is None or ended is None:
        return 0
    kept = [row for row in rows if started <= row["timestamp"] <= ended]
    dropped = len(rows) - len(kept)
    rows[:] = kept
    return dropped


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("session", type=Path)
    parser.add_argument("--merged", action="store_true",
                        help="also write the legacy merged timeline.csv")
    parser.add_argument("--keep-outside", action="store_true",
                        help="keep events stamped outside the session window")
    args = parser.parse_args()
    if not args.session.is_dir():
        parser.error(f"session does not exist: {args.session}")
    manifest = read_manifest(args.session / "manifest.json")
    rows = []
    event(rows, "session", manifest.get("started_at_unix"), "start", "session")
    event(rows, "bms", manifest.get("started_at_unix"), "status", "bms.service")
    parse_can(args.session / "can.log", rows)
    # bms-status.txt has two generations of format: the old systemctl status
    # snapshot and the new journalctl data line. Each parser only matches
    # its own format, so both can run unconditionally.
    parse_marked_snapshot(args.session / "bms-status.txt", rows, "bms")
    parse_bms(args.session / "bms-status.txt", rows)
    parse_dmesg(args.session / "dmesg-live.txt", rows)
    parse_unix_lines(args.session / "dmesg-live.txt", rows, "dmesg")
    parse_unix_lines(args.session / "hpm-uart-live.txt", rows, "hpm-uart")
    parse_unix_lines(args.session / "thermal.txt", rows, "thermal")
    parse_inference(args.session / "inference-session.txt", rows)
    parse_can_details(args.session / "can-details.jsonl", rows)
    for pcap in sorted(args.session.glob("usbcan.pcap*")):
        parse_usb(pcap, rows)
    event(rows, "session", manifest.get("ended_at_unix"), "end", "session")
    dropped = 0 if args.keep_outside else drop_outside_window(rows, manifest)
    rows.sort(key=lambda row: row["timestamp"])

    by_dimension = {}
    for row in rows:
        by_dimension.setdefault(row["dimension"], []).append(row)

    outputs = {}
    for dimension, (filename, fieldnames) in DIMENSION_OUTPUTS.items():
        dimension_rows = by_dimension.get(dimension)
        if not dimension_rows:
            continue
        with (args.session / filename).open("w", newline="", encoding="utf-8") as stream:
            writer = csv.DictWriter(stream, fieldnames=fieldnames, extrasaction="ignore")
            writer.writeheader()
            writer.writerows(dimension_rows)
        outputs[dimension] = {"file": filename, "rows": len(dimension_rows)}

    summary = {
        "session": str(args.session),
        "started_at_unix": manifest.get("started_at_unix"),
        "ended_at_unix": manifest.get("ended_at_unix"),
        "event_count": len(rows),
        "dropped_outside_window": dropped,
        # Carry capture completeness through analysis; a hash-valid export
        # does not prove the recorders ran without errors.
        "capture": {
            "capture_failed": manifest.get("capture_failed"),
            "candump_status": manifest.get("candump_status"),
            "usb_capture_status": manifest.get("usb_capture_status"),
            "failed_recorder": manifest.get("failed_recorder"),
            "asc_mode": manifest.get("asc_mode"),
            "session_complete": manifest.get("ended_at_unix") is not None,
        },
        "events_by_dimension": {dimension: sum(row["dimension"] == dimension for row in rows)
                                 for dimension in sorted({row["dimension"] for row in rows})},
        "outputs": outputs,
    }
    if args.merged:
        timeline = args.session / "timeline.csv"
        with timeline.open("w", newline="", encoding="utf-8") as stream:
            writer = csv.DictWriter(stream, fieldnames=MERGED_FIELDNAMES, extrasaction="ignore")
            writer.writeheader()
            writer.writerows(rows)
        summary["timeline"] = str(timeline)
    (args.session / "summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    for dimension, info in sorted(outputs.items()):
        print(f"{info['file']}: {info['rows']} rows")
    if args.merged:
        print(f"timeline: {timeline}")
    print(f"events: {len(rows)}")
    print(json.dumps(summary["events_by_dimension"], sort_keys=True))


if __name__ == "__main__":
    main()
