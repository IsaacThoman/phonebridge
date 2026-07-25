#!/bin/sh
set -eu

configuration="${CONFIGURATION:-release}"
output_root="${1:-dist}"
app_path="${output_root}/PhoneBridge.app"
case "${app_path}" in
  "/PhoneBridge.app"|"/Users/PhoneBridge.app")
    echo "Refusing unsafe app output path: ${app_path}" >&2
    exit 1
    ;;
esac
staging_root="$(mktemp -d "${TMPDIR:-/tmp}/phonebridge-app.XXXXXX")"
staging_app="${staging_root}/PhoneBridge.app"
trap 'rm -rf "${staging_root}"' EXIT

swift build -c "${configuration}" --product PhoneBridgeMacApp
bin_path="$(swift build -c "${configuration}" --show-bin-path)"

mkdir -p \
  "${staging_app}/Contents/MacOS" \
  "${staging_app}/Contents/Resources" \
  "${staging_app}/Contents/Frameworks"
cp "${bin_path}/PhoneBridgeMacApp" "${staging_app}/Contents/MacOS/PhoneBridgeMacApp"
cp "Sources/PhoneBridgeMacApp/Resources/Info.plist" "${staging_app}/Contents/Info.plist"
cp -R "${bin_path}/phonebridge_PhoneBridgeCore.bundle" "${staging_app}/Contents/Resources/"
cp -R "${bin_path}/WebRTC.framework" "${staging_app}/Contents/Frameworks/"

codesign --force --deep --sign - "${staging_app}"
codesign --verify --deep --strict --verbose=2 "${staging_app}"
mkdir -p "${output_root}"
rm -rf "${app_path}"
mv "${staging_app}" "${app_path}"
echo "${app_path}"
