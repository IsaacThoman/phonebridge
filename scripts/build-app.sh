#!/bin/sh
set -eu

configuration="${CONFIGURATION:-release}"
output_root="${1:-dist}"
app_path="${output_root}/PhoneBridge.app"

swift build -c "${configuration}" --product PhoneBridgeMacApp
bin_path="$(swift build -c "${configuration}" --show-bin-path)"

mkdir -p "${app_path}/Contents/MacOS" "${app_path}/Contents/Resources" "${app_path}/Contents/Frameworks"
cp "${bin_path}/PhoneBridgeMacApp" "${app_path}/Contents/MacOS/PhoneBridgeMacApp"
cp "Sources/PhoneBridgeMacApp/Resources/Info.plist" "${app_path}/Contents/Info.plist"
cp -R "${bin_path}/phonebridge_PhoneBridgeCore.bundle" "${app_path}/Contents/Resources/"
cp -R "${bin_path}/WebRTC.framework" "${app_path}/Contents/Frameworks/"

codesign --force --deep --sign - "${app_path}"
codesign --verify --deep --strict --verbose=2 "${app_path}"
echo "${app_path}"
