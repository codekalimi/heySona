#!/bin/bash
set -euo pipefail


export PATH="/opt/homebrew/bin:$PATH"






























SCHEME="heySona"
APP_NAME="makesomething"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${PROJECT_DIR}/build"
ARCHIVE_PATH="${BUILD_DIR}/${APP_NAME}.xcarchive"
EXPORT_DIR="${BUILD_DIR}/export"
DMG_OUTPUT_DIR="${BUILD_DIR}/dmg"
RELEASES_DIR="${PROJECT_DIR}/releases"
DMG_BACKGROUND="${PROJECT_DIR}/dmg-background.png"

GITHUB_REPO="julianjear/makesomething-mac-app"


SPARKLE_BIN=$(find ~/Library/Developer/Xcode/DerivedData/heySona*/SourcePackages/artifacts/sparkle/Sparkle/bin -maxdepth 0 2>/dev/null | head -1)

if [ -z "$SPARKLE_BIN" ]; then
    echo "❌ Sparkle tools not found. Build the project in Xcode first so SPM downloads Sparkle."
    exit 1
fi






echo "🔍 Checking latest release on GitHub..."

LATEST_TAG=$(gh release view --repo "${GITHUB_REPO}" --json tagName --jq '.tagName' 2>/dev/null || echo "")

if [ -n "$LATEST_TAG" ]; then

    LATEST_VERSION="${LATEST_TAG#v}"






    LATEST_BUILD=$(gh release list --repo "${GITHUB_REPO}" --json tagName --jq 'length' 2>/dev/null || echo "0")

    echo "   Latest release: ${LATEST_TAG} (build ${LATEST_BUILD})"
else
    LATEST_VERSION="0.0"
    LATEST_BUILD=0
    echo "   No previous releases found — starting from scratch"
fi



if [ $
    MARKETING_VERSION="$1"
else
    MAJOR=$(echo "$LATEST_VERSION" | cut -d. -f1)
    MINOR=$(echo "$LATEST_VERSION" | cut -d. -f2)
    NEXT_MINOR=$((MINOR + 1))
    if [ "$NEXT_MINOR" -ge 10 ]; then
        MAJOR=$((MAJOR + 1))
        NEXT_MINOR=0
    fi
    MARKETING_VERSION="${MAJOR}.${NEXT_MINOR}"
fi


if [ $
    BUILD_NUMBER="$2"
else
    BUILD_NUMBER=$((LATEST_BUILD + 1))
fi

DMG_FILENAME="${APP_NAME}.dmg"
TAG="v${MARKETING_VERSION}"




if gh release view "${TAG}" --repo "${GITHUB_REPO}" &>/dev/null; then
    echo ""
    echo "❌ Release ${TAG} already exists on GitHub!"
    echo "   https://github.com/${GITHUB_REPO}/releases/tag/${TAG}"
    echo ""
    echo "   To release a new version, either:"
    echo "     • Run without arguments to auto-bump: ./scripts/release.sh"
    echo "     • Specify a higher version: ./scripts/release.sh $(echo "${MARKETING_VERSION} + 0.1" | bc)"
    echo "     • Delete the existing release first: gh release delete ${TAG} --repo ${GITHUB_REPO} --yes"
    exit 1
fi

echo ""
echo "🚀 Releasing ${APP_NAME} v${MARKETING_VERSION} (build ${BUILD_NUMBER})"
echo "   Previous: ${LATEST_TAG:-none}"
echo ""


read -p "   Proceed? (y/N) " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "   Aborted."
    exit 0
fi
echo ""



echo "🧹 Cleaning build directory and stale DMGs..."
rm -rf "${BUILD_DIR}"


rm -f "${RELEASES_DIR}"/rw.*.dmg "${RELEASES_DIR}/${DMG_FILENAME}"
mkdir -p "${BUILD_DIR}" "${EXPORT_DIR}" "${DMG_OUTPUT_DIR}" "${RELEASES_DIR}"



echo "📦 Archiving..."
xcodebuild archive \
    -scheme "${SCHEME}" \
    -archivePath "${ARCHIVE_PATH}" \
    MARKETING_VERSION="${MARKETING_VERSION}" \
    CURRENT_PROJECT_VERSION="${BUILD_NUMBER}" \
    2>&1 | tail -5

echo "✅ Archive created"






EXPORT_OPTIONS="${BUILD_DIR}/ExportOptions.plist"
cat > "${EXPORT_OPTIONS}" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>destination</key>
    <string>export</string>
</dict>
</plist>
PLIST

echo "📤 Exporting (signing + notarizing — this may take a few minutes)..."
xcodebuild -exportArchive \
    -archivePath "${ARCHIVE_PATH}" \
    -exportPath "${EXPORT_DIR}" \
    -exportOptionsPlist "${EXPORT_OPTIONS}" \
    2>&1 | tail -5

echo "✅ Export complete (signed + notarized)"



DMG_PATH="${RELEASES_DIR}/${DMG_FILENAME}"

echo "💿 Creating DMG..."
create-dmg \
    --volname "${APP_NAME}" \
    --window-pos 200 120 \
    --window-size 660 400 \
    --icon-size 100 \
    --icon "${APP_NAME}.app" 160 195 \
    --app-drop-link 500 195 \
    --background "${DMG_BACKGROUND}" \
    "${DMG_PATH}" \
    "${EXPORT_DIR}/${APP_NAME}.app" \
    2>&1 | tail -3

echo "✅ DMG created: ${DMG_PATH}"







echo "🔏 Notarizing DMG with Apple (this may take a few minutes)..."
xcrun notarytool submit "${DMG_PATH}" \
    --keychain-profile "AC_PASSWORD" \
    --wait

echo "📎 Stapling notarization ticket to DMG..."
xcrun stapler staple "${DMG_PATH}"

echo "✅ DMG notarized and stapled"



echo "🔐 Signing DMG with Sparkle EdDSA key..."
"${SPARKLE_BIN}/sign_update" "${DMG_PATH}"







echo "📡 Generating appcast.xml..."
"${SPARKLE_BIN}/generate_appcast" \
    --download-url-prefix "https://github.com/${GITHUB_REPO}/releases/download/${TAG}/" \
    -o "${PROJECT_DIR}/appcast.xml" \
    "${RELEASES_DIR}"

echo "✅ appcast.xml updated"





echo "🏷️  Creating GitHub Release ${TAG}..."
gh release create "${TAG}" "${DMG_PATH}" \
    --repo "${GITHUB_REPO}" \
    --title "v${MARKETING_VERSION}" \
    --notes "makesomething v${MARKETING_VERSION}" \
    --latest





echo "📝 Pushing appcast.xml to ${GITHUB_REPO}..."
RELEASES_REPO_DIR=$(mktemp -d)
git clone --depth 1 "https://github.com/${GITHUB_REPO}.git" "${RELEASES_REPO_DIR}" 2>&1 | tail -2
cp "${PROJECT_DIR}/appcast.xml" "${RELEASES_REPO_DIR}/appcast.xml"
cd "${RELEASES_REPO_DIR}"
git add appcast.xml
git commit -m "Update appcast.xml for v${MARKETING_VERSION}" || echo "   (no changes to commit)"
git push || echo "   (push failed — you may need to push manually)"
cd "${PROJECT_DIR}"
rm -rf "${RELEASES_REPO_DIR}"

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "✅ Release v${MARKETING_VERSION} (build ${BUILD_NUMBER}) complete!"
echo ""
echo "   DMG:      ${DMG_PATH}"
echo "   Appcast:  ${PROJECT_DIR}/appcast.xml"
echo "   Release:  https://github.com/${GITHUB_REPO}/releases/tag/${TAG}"
echo ""
echo "   Download URL (always latest):"
echo "   https://github.com/${GITHUB_REPO}/releases/latest/download/${DMG_FILENAME}"
echo "═══════════════════════════════════════════════════════════════"
