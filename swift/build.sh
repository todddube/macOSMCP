#!/bin/bash
# Build the calendar_helper Swift binary.
# Run from the project root: bash swift/build.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
echo "Compiling calendar_helper..."
swiftc -O \
    -o "$SCRIPT_DIR/calendar_helper" \
    "$SCRIPT_DIR/calendar_helper.swift" \
    -framework EventKit \
    -framework Foundation
echo "Built: $SCRIPT_DIR/calendar_helper"
