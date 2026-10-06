#!/bin/bash
# Builds CodexUsage.app — a menu bar (status item) app showing codex quota.
set -euo pipefail
cd "$(dirname "$0")"

APP=CodexUsage.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -swift-version 5 -o "$APP/Contents/MacOS/CodexUsage" main.swift
cp Info.plist "$APP/Contents/Info.plist"
codesign --force -s - "$APP" 2>/dev/null || true

echo "Built $APP"
