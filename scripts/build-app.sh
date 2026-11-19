#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
bundle_id="${QUOTE0_BUNDLE_ID:-com.linkinstars.quote0ui}"
app_version="${QUOTE0_VERSION:-0.1.1}"
build_number="${QUOTE0_BUILD_NUMBER:-2}"
if [[ ! "${bundle_id}" =~ '^[A-Za-z0-9]+([.-][A-Za-z0-9]+)+$' ||
      ! "${app_version}" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ||
      ! "${build_number}" =~ '^[0-9]+$' ]]; then
  print -u2 'Bundle ID、版本号或构建号格式无效。'
  exit 2
fi
app_bundle="${PWD}/build/quote0UI.app"
if [[ "${QUOTE0_UNIVERSAL:-0}" == 1 ]]; then
  swift build -c release --triple arm64-apple-macosx13.0 --scratch-path build/arm64
  bin_dir="$(swift build -c release --triple arm64-apple-macosx13.0 --scratch-path build/arm64 --show-bin-path)"
  swift build -c release --triple x86_64-apple-macosx13.0 --scratch-path build/x86_64
  intel_bin_dir="$(swift build -c release --triple x86_64-apple-macosx13.0 --scratch-path build/x86_64 --show-bin-path)"
else
  swift build -c release
  bin_dir="$(swift build -c release --show-bin-path)"
fi
if [[ -d "${app_bundle}" ]]; then
  [[ "${app_bundle}" == "${PWD}/build/quote0UI.app" ]] || exit 2
  rm -rf "${app_bundle}"
fi
mkdir -p "${app_bundle}/Contents/MacOS" "${app_bundle}/Contents/Resources"
if [[ "${QUOTE0_UNIVERSAL:-0}" == 1 ]]; then
  lipo -create "${bin_dir}/Quote0UI" "${intel_bin_dir}/Quote0UI" -output "${app_bundle}/Contents/MacOS/Quote0UI"
else
  cp "${bin_dir}/Quote0UI" "${app_bundle}/Contents/MacOS/Quote0UI"
fi
mkdir -p "${app_bundle}/Contents/Resources/Quote0UI_Quote0UI.bundle"
rsync -a --delete "${bin_dir}/Quote0UI_Quote0UI.bundle/" "${app_bundle}/Contents/Resources/Quote0UI_Quote0UI.bundle/"
iconset="${PWD}/build/AppIcon.iconset"
mkdir -p "${iconset}"
for spec in '16:16x16' '32:16x16@2x' '32:32x32' '64:32x32@2x' '128:128x128' '256:128x128@2x' '256:256x256' '512:256x256@2x' '512:512x512' '1024:512x512@2x'; do
  pixels="${spec%%:*}"
  name="${spec#*:}"
  sips -s format png -z "${pixels}" "${pixels}" Assets/AppIcon.png --out "${iconset}/icon_${name}.png" >/dev/null
done
iconutil -c icns "${iconset}" -o "${app_bundle}/Contents/Resources/AppIcon.icns"
cat > "${app_bundle}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>${bundle_id}</string>
  <key>CFBundleName</key><string>quote0UI</string>
  <key>CFBundleDisplayName</key><string>quote0UI</string>
  <key>CFBundleExecutable</key><string>Quote0UI</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>${app_version}</string>
  <key>CFBundleVersion</key><string>${build_number}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --deep --sign - "${app_bundle}"
echo "Created ${app_bundle}"
