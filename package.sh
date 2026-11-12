#!/bin/bash
# Empaqueta RamBar para distribuir: binario universal, .app, firma y .dmg.
#
# Uso:
#   ./package.sh                                  → firma ad-hoc (gratis)
#   SIGN_IDENTITY="Developer ID Application: Tu Nombre (TEAMID)" \
#   NOTARY_PROFILE="rambar-notary" ./package.sh   → firmado + notarizado
#
# El perfil de notarización se crea una sola vez con:
#   xcrun notarytool store-credentials "rambar-notary" \
#       --apple-id "tu@correo.com" --team-id TEAMID --password APP_SPECIFIC_PASSWORD
set -euo pipefail

APP_NAME="RamBar"
VERSION="${VERSION:-1.0.0}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"   # "-" = firma ad-hoc
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

cd "$(cd "$(dirname "$0")" && pwd)"
BUILD="build"
BUNDLE="$BUILD/$APP_NAME.app"
DMG="$BUILD/$APP_NAME-$VERSION.dmg"

rm -rf "$BUILD"
mkdir -p "$BUNDLE/Contents/MacOS"

# ---------------------------------------------------------------- compilar
# Binario universal: se compila una vez por arquitectura y se unen con lipo,
# así corre igual en Apple Silicon y en los Mac Intel que aún andan por ahí.
for arch in arm64 x86_64; do
	echo "→ compilando $arch"
	swiftc -O \
		-target "$arch-apple-macos13.0" \
		-framework AppKit \
		-o "$BUILD/$APP_NAME-$arch" \
		main.swift
done

lipo -create -output "$BUNDLE/Contents/MacOS/$APP_NAME" \
	"$BUILD/$APP_NAME-arm64" "$BUILD/$APP_NAME-x86_64"
rm -f "$BUILD/$APP_NAME-arm64" "$BUILD/$APP_NAME-x86_64"

sed "s/<string>1.0<\/string>/<string>$VERSION<\/string>/" Info.plist \
	> "$BUNDLE/Contents/Info.plist"

# ------------------------------------------------------------------ firmar
# --options runtime activa el hardened runtime y --timestamp agrega el sello
# de tiempo seguro: ambos son obligatorios si vas a notarizar.
echo "→ firmando con: $SIGN_IDENTITY"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
	codesign --force --sign - "$BUNDLE"
else
	codesign --force --options runtime --timestamp \
		--sign "$SIGN_IDENTITY" "$BUNDLE"
fi
codesign --verify --strict --verbose=2 "$BUNDLE"

# --------------------------------------------------------------------- dmg
# Carpeta de staging con la app y un alias a /Applications: el clásico
# "arrastra aquí" sin necesidad de instalador.
STAGE="$BUILD/stage"
mkdir -p "$STAGE"
cp -R "$BUNDLE" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

hdiutil create \
	-volname "$APP_NAME" \
	-srcfolder "$STAGE" \
	-format UDZO -ov \
	"$DMG"
rm -rf "$STAGE"

if [[ "$SIGN_IDENTITY" != "-" ]]; then
	codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
fi

# -------------------------------------------------------------- notarizar
if [[ -n "$NOTARY_PROFILE" && "$SIGN_IDENTITY" != "-" ]]; then
	echo "→ enviando a notarizar (esto tarda unos minutos)"
	xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
	xcrun stapler staple "$DMG"
	xcrun stapler validate "$DMG"
	echo
	echo "→ verificación final:"
	spctl --assess --verbose=2 --type install "$DMG"
else
	echo
	echo "⚠️  Sin notarizar: quien lo descargue tendrá que autorizarlo en"
	echo "   Ajustes del Sistema → Privacidad y seguridad → Abrir de todos modos."
fi

echo
echo "Listo → $(pwd)/$DMG"
