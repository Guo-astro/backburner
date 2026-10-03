#!/bin/bash
# tests/security/run.sh - the security checks that need no phone: the app's connection gate and argument validators
# (cable-policy-test), the Wi-Fi tunnel's crypto (tunnel-test), the listener lint, the commit / push hooks
# (check-sensitive-test) and an audit of every tracked file. Exits non-zero on any failure.
# On a phone (Backburner open, on the cable, Mac on the same Wi-Fi): scripts/check-phone-exposure.py
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT=${TMPDIR:-/tmp}/bb-security-tests
mkdir -p "$OUT"
xcrun clang++ -std=c++17 -O1 -Wall -Wextra -Wno-unused-parameter -Wno-unused-function \
  -Illama.cpp/include -Illama.cpp/ggml/include \
  tests/security/cable-policy-test.cpp -o "$OUT/cable-policy-test"
"$OUT/cable-policy-test"
scripts/check-listeners.sh
xcrun swiftc -O -parse-as-library -o "$OUT/tunnel-test" ios/Backburner/Sidecar/Tunnel.swift tests/security/tunnel-test.swift
"$OUT/tunnel-test"
tests/security/check-sensitive-test.sh
python3 scripts/hooks/check-sensitive.py --all && echo "check-sensitive --all: no personal data, secrets or stray files in the tracked tree"
echo "security tests: all passed"
