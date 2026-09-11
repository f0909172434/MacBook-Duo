#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h}"
TEST_DIR=$(mktemp -d)
swiftc -parse-as-library \
  "$PROJECT_DIR/Sources/ScreenCapturePermissionPreparation.swift" \
  "$PROJECT_DIR/Sources/LiveEffectPolicy.swift" \
  "$PROJECT_DIR/Tests/PermissionPreparationTests.swift" \
  -o "$TEST_DIR/policy-tests"
"$TEST_DIR/policy-tests"
