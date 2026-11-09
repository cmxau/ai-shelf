#!/bin/sh
set -e; cd "$(dirname "$0")"
A="AI Shelf.app"; mkdir -p "$A/Contents/MacOS" "$A/Contents/Resources"
V=$(cat VERSION)
xcrun swiftc -parse-as-library -O Sources/*.swift -o "$A/Contents/MacOS/ai-shelf"
cp AppIcon.icns "$A/Contents/Resources/"
cat > "$A/Contents/Info.plist" <<P
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>ai-shelf</string>
<key>CFBundleIdentifier</key><string>com.cmxau.ai-shelf</string>
<key>CFBundleName</key><string>AI Shelf</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleDisplayName</key><string>AI Shelf</string>
<key>CFBundleShortVersionString</key><string>$V</string>
<key>CFBundleVersion</key><string>$V</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppleEventsUsageDescription</key><string>Open projects in your terminal.</string>
</dict></plist>
P
touch "$A"
echo "Built: $PWD/$A"
if [ "$1" = "--install" ]; then rm -rf "/Applications/$A" && cp -R "$A" /Applications/ && echo "Installed: /Applications/$A"; fi
