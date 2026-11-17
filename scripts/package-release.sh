#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."

if [[ -z "${QUOTE0_SIGNING_IDENTITY:-}" ]]; then
  print -u2 '请设置 QUOTE0_SIGNING_IDENTITY 为 Developer ID Application 证书名称。'
  exit 2
fi
if [[ "${QUOTE0_SIGNING_IDENTITY}" != Developer\ ID\ Application:* ]] ||
   ! security find-identity -v -p codesigning | grep -F -- "\"${QUOTE0_SIGNING_IDENTITY}\"" >/dev/null; then
  print -u2 '找不到有效的 Developer ID Application 签名身份；Apple Distribution 证书不能用于站外分发公证。'
  exit 2
fi
if [[ -z "${QUOTE0_NOTARY_PROFILE:-}" ]]; then
  print -u2 '请设置 QUOTE0_NOTARY_PROFILE 为已配置的 notarytool 钥匙串配置名称。'
  exit 2
fi
notary_options=(--keychain-profile "${QUOTE0_NOTARY_PROFILE}")
if [[ -n "${QUOTE0_NOTARY_KEYCHAIN:-}" ]]; then
  notary_options+=(--keychain "${QUOTE0_NOTARY_KEYCHAIN}")
fi

QUOTE0_UNIVERSAL=1 ./scripts/build-app.sh
app_bundle="${PWD}/build/quote0UI.app"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${app_bundle}/Contents/Info.plist")
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${app_bundle}/Contents/Info.plist")
stage="${PWD}/build/dmg-root"
dmg="${PWD}/build/quote0UI-${version}.dmg"

codesign --force --options runtime --timestamp --sign "${QUOTE0_SIGNING_IDENTITY}" "${app_bundle}"
codesign --verify --deep --strict --verbose=2 "${app_bundle}"

if [[ -d "${stage}" ]]; then
  [[ "${stage}" == "${PWD}/build/dmg-root" ]] || exit 2
  rm -rf "${stage}"
fi
mkdir -p "${stage}"
ditto "${app_bundle}" "${stage}/quote0UI.app"
ln -sfn /Applications "${stage}/Applications"
hdiutil create -volname quote0UI -srcfolder "${stage}" -format UDZO -ov "${dmg}"
codesign --force --timestamp --sign "${QUOTE0_SIGNING_IDENTITY}" -i "${bundle_id}.dmg" "${dmg}"
codesign --verify --strict --verbose=2 "${dmg}"
hdiutil verify "${dmg}"
xcrun notarytool submit "${dmg}" "${notary_options[@]}" --wait
xcrun stapler staple "${dmg}"
xcrun stapler validate "${dmg}"
print "Created signed, notarized ${dmg}"
