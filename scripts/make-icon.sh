#!/usr/bin/env bash
# Regenerates Resources/AppIcon.icns from assets/icon-source.png.
set -euo pipefail

cd "$(dirname "$0")/.."

SOURCE="assets/icon-source.png"
ICONSET="build/AppIcon.iconset"

rm -rf "$ICONSET"
mkdir -p "$ICONSET"
swiftc -O scripts/make-icon.swift -o build/make-icon

for base in 16 32 128 256 512; do
  build/make-icon "$SOURCE" "$ICONSET/icon_${base}x${base}.png" "$base"
  build/make-icon "$SOURCE" "$ICONSET/icon_${base}x${base}@2x.png" "$((base * 2))"
done

iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
echo "Built Resources/AppIcon.icns"
