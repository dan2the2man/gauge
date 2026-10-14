#!/bin/bash
# Gauge release: build → sign (Developer ID) → notarize → staple → DMG → Sparkle appcast entry.
# Without a Developer ID certificate it falls back to an ad-hoc, UNSIGNED build (loud warning).
#
# Env overrides:
#   NOTARY_PROFILE   keychain profile for notarytool          (default: gauge-notary)
#   SPARKLE_ACCOUNT  keychain account of the EdDSA key        (default: gauge)
#   SPARKLE_BIN      dir with sign_update                     (default: .tools/sparkle/bin)
#   SITE_URL         where the download page + appcast live   (default: read from Info.plist SUFeedURL)
#   ALLOW_UNSIGNED=0 refuse to fall back to ad-hoc signing
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD

NOTARY_PROFILE=${NOTARY_PROFILE:-gauge-notary}
SPARKLE_ACCOUNT=${SPARKLE_ACCOUNT:-gauge}
SPARKLE_BIN=${SPARKLE_BIN:-$ROOT/.tools/sparkle/bin}
REPO=${REPO:-dan2the2man/gauge}
VERSION=$(tr -d '[:space:]' < VERSION)
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
TAG="v$VERSION"
DIST=$ROOT/dist
APP=$DIST/Gauge.app
DMG=$DIST/Gauge.dmg
PB=/usr/libexec/PlistBuddy

red()  { printf '\033[1;31m%s\033[0m\n' "$*"; }
info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

# 0. Sparkle tools (sign_update) — fetched once into .tools (gitignored)
if [ ! -x "$SPARKLE_BIN/sign_update" ]; then
  info "Fetching Sparkle tools"
  mkdir -p "$ROOT/.tools/sparkle"
  curl -fsSL https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-2.10.0.tar.xz \
    | tar -xJ -C "$ROOT/.tools/sparkle"
  SPARKLE_BIN=$ROOT/.tools/sparkle/bin
fi

# 1. Build
info "Building Gauge $VERSION ($BUILD)"
swift build -c release 2>&1 | grep -E "error|Build complete" || true
test -x .build/release/Gauge || { red "build failed"; exit 1; }

# 2. Assemble the bundle
rm -rf "$DIST"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp .build/release/Gauge "$APP/Contents/MacOS/Gauge"
cp Info.plist "$APP/Contents/Info.plist"
$PB -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
ditto .build/release/Sparkle.framework "$APP/Contents/Frameworks/Sparkle.framework"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/" && \
  $PB -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" || true
FEED=$($PB -c "Print :SUFeedURL" Info.plist)
SITE_URL=${SITE_URL:-${FEED%/appcast.xml}}

# 3. Sign
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')
SPK=$APP/Contents/Frameworks/Sparkle.framework
if [ -n "$IDENTITY" ]; then
  SIGNED=1
  info "Signing with: $IDENTITY"
  CS=(codesign --force --timestamp --options runtime --sign "$IDENTITY")
  # Sparkle's documented inside-out order (no --deep)
  "${CS[@]}" "$SPK/Versions/B/XPCServices/Installer.xpc"
  "${CS[@]}" --preserve-metadata=entitlements "$SPK/Versions/B/XPCServices/Downloader.xpc"
  "${CS[@]}" "$SPK/Versions/B/Autoupdate"
  "${CS[@]}" "$SPK/Versions/B/Updater.app"
  "${CS[@]}" "$SPK"
  "${CS[@]}" "$APP"
  codesign --verify --strict --deep --verbose=2 "$APP"
else
  SIGNED=0
  if [ "${ALLOW_UNSIGNED:-1}" = 0 ]; then red "No 'Developer ID Application' identity and ALLOW_UNSIGNED=0"; exit 1; fi
  red "################################################################################"
  red "#  WARNING: no 'Developer ID Application' certificate found in the keychain.   #"
  red "#  Building an AD-HOC, UNSIGNED, UN-NOTARIZED Gauge. Gatekeeper WILL block it: #"
  red "#  users must right-click > Open (or System Settings > Privacy > Open Anyway). #"
  red "#  Sparkle updates also need a stable signature; don't ship this widely.        #"
  red "################################################################################"
  codesign --force --deep --sign - "$APP"
  codesign --verify --deep --verbose=1 "$APP"
fi

# 4. Notarize + staple the app
if [ $SIGNED = 1 ]; then
  info "Notarizing app (profile: $NOTARY_PROFILE)"
  ditto -c -k --keepParent "$APP" "$DIST/Gauge-notarize.zip"
  xcrun notarytool submit "$DIST/Gauge-notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm "$DIST/Gauge-notarize.zip"
fi

# 5. DMG (drag-to-Applications)
info "Making DMG"
STAGE=$(mktemp -d); ditto "$APP" "$STAGE/Gauge.app"; ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Gauge" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
rm -rf "$STAGE"
if [ $SIGNED = 1 ]; then
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  spctl -a -t open --context context:primary-signature -v "$DMG"
fi

# 6. Sparkle: EdDSA-sign the DMG (private key stays in the login keychain) and write the appcast
info "Signing update for Sparkle (keychain account: $SPARKLE_ACCOUNT)"
SIG_ATTRS=$("$SPARKLE_BIN/sign_update" --account "$SPARKLE_ACCOUNT" "$DMG")   # sparkle:edSignature="…" length="…"
URL="https://github.com/$REPO/releases/download/$TAG/Gauge.dmg"
mkdir -p site
python3 - "$ROOT/site/appcast.xml" "$VERSION" "$BUILD" "$URL" "$SIG_ATTRS" "$SITE_URL" <<'PY'
import sys, os, re, email.utils
path, ver, build, url, sig, site = sys.argv[1:]
item = f'''    <item>
      <title>Version {ver}</title>
      <pubDate>{email.utils.formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{ver}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <link>{site}</link>
      <enclosure url="{url}" type="application/octet-stream" {sig.strip()} />
    </item>
'''
head = f'''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Gauge</title>
    <link>{site}</link>
    <description>Gauge updates</description>
    <language>en</language>
'''
old = open(path).read() if os.path.exists(path) else ''
items = re.findall(r'    <item>.*?</item>\n', old, re.S)
items = [i for i in items if f'<sparkle:version>{build}</sparkle:version>' not in i]
open(path, 'w').write(head + item + ''.join(items) + '  </channel>\n</rss>\n')
PY

# 7. Summary
echo
info "Done: $DMG ($(du -h "$DMG" | cut -f1)), appcast entry written to site/appcast.xml"
[ $SIGNED = 1 ] || red "REMINDER: this build is ad-hoc signed only (no Developer ID, not notarized)."
echo
echo "Next, publish the release (Download button uses releases/latest/download/Gauge.dmg):"
echo "  git tag $TAG && git push origin $TAG"
echo "  gh release create $TAG \"$DMG\" --repo $REPO --title \"Gauge $VERSION\" --generate-notes"
echo "Then redeploy site/ so $FEED serves the new appcast."
