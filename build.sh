#!/bin/bash
# Compila RamBar.app. Requiere las Command Line Tools de Xcode:
#   xcode-select --install
set -euo pipefail

APP_NAME="RamBar"
BUNDLE="$APP_NAME.app"

cd "$(cd "$(dirname "$0")" && pwd)"

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
cp Info.plist "$BUNDLE/Contents/Info.plist"

swiftc -O \
	-target "$(uname -m)-apple-macos13.0" \
	-framework AppKit \
	-o "$BUNDLE/Contents/MacOS/$APP_NAME" \
	main.swift

# Firma ad-hoc: suficiente para una app local y le da identidad estable
# para los permisos del sistema.
codesign --force --sign - "$BUNDLE"

echo
echo "Listo → $(pwd)/$BUNDLE"
echo "Probar:    open $BUNDLE"
echo "Instalar:  cp -R $BUNDLE /Applications/"
