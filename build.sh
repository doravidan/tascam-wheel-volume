#!/bin/zsh
set -eu
cd -- "${0:A:h}"
app="$PWD/build/Tascam Wheel Volume.app"
mkdir -p "$app/Contents/MacOS"
cp Info.plist "$app/Contents/Info.plist"
xcrun clang -mmacosx-version-min=15.0 -std=c11 -O2 -Wall -Wextra -Wno-unused-parameter -c AudioBridge.c -o build/AudioBridge.o
xcrun swiftc -target "$(uname -m)-apple-macos15.0" -swift-version 5 -O -framework CoreAudio -framework AppKit -framework Carbon -import-objc-header AudioBridge.h main.swift build/AudioBridge.o -o "$app/Contents/MacOS/TascamWheelVolume"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
"$app/Contents/MacOS/TascamWheelVolume" --self-test
if [[ "${1:-}" == "--probe" ]]; then
  "$app/Contents/MacOS/TascamWheelVolume" --probe-output
fi
