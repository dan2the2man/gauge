#!/bin/bash
# Compiles the pure (Foundation-only) model code with Tests/selftest and runs it.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=$(mktemp -d)/gauge-selftest
swiftc -O -o "$OUT" Sources/Gauge/Parse.swift Sources/Gauge/CreditHistory.swift Tests/selftest/main.swift
"$OUT"
