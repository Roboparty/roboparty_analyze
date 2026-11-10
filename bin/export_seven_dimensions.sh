#!/bin/bash
# Copyright (C) 2026 wentywenty
# 分析七维日志会话，生成时间线后打包为 ZIP，并生成 SHA-256 校验文件。
# SPDX-License-Identifier: GPL-3.0
set -euo pipefail

usage() { echo "Usage: $0 SESSION_DIR [OUTPUT_ZIP]" >&2; exit 2; }
session=${1:-}
[[ -n $session ]] || usage
[[ -d $session ]] || { echo "Session directory not found: $session" >&2; exit 1; }
session=$(realpath -e "$session")
name=$(basename "$session")
archive=${2:-${session}.zip}
archive=$(realpath -m "$archive")
[[ $archive != "$session"/* ]] || { echo "Output ZIP must be outside the session directory" >&2; exit 1; }
command -v zip >/dev/null 2>&1 || { echo "Missing zip; install zip" >&2; exit 1; }
command -v sha256sum >/dev/null 2>&1 || { echo "Missing sha256sum" >&2; exit 1; }
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROBOOS_PREFIX="${ROBOOS_PREFIX:-$(cd "$script_dir/.." && pwd)}"
analyzer=$script_dir/analyze_seven_dimensions.py
[[ -f $analyzer ]] || analyzer=$script_dir/../analysis/analyze_seven_dimensions.py
[[ -f $analyzer ]] || analyzer=$ROBOOS_PREFIX/bin/robopi-seven-analyze
[[ -f $analyzer ]] || { echo "Analyzer not found: $analyzer" >&2; exit 1; }
python3 "$analyzer" "$session"
stage=$(mktemp -d)
cleanup() { rm -rf "$stage"; }
trap cleanup EXIT
cp -a "$session" "$stage/$name"
rm -f "$stage/$name"/*.zip "$stage/$name"/*.zip.sha256 "$stage/$name/files.sha256"
(cd "$stage" && find "$name" -type f -print0 | sort -z | xargs -0 sha256sum) > "$stage/$name/files.sha256"
mkdir -p "$(dirname "$archive")"
rm -f "$archive" "$archive.sha256"
(cd "$stage" && zip -qr -X "$archive" "$name")
printf '%s  %s\n' "$(sha256sum "$archive" | awk '{print $1}')" "$(basename "$archive")" > "$archive.sha256"
echo "ZIP:    $archive"
echo "SHA256: $archive.sha256"
echo "FILES:  $name/files.sha256"
