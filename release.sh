#!/bin/bash

set -e

echo "🚀 Building IMAP Menu Universal Binary"
echo ""

# Clean previous builds
echo "🧹 Cleaning previous builds..."
rm -rf .build
rm -rf IMAPMenu.app
rm -f IMAPMenu-universal.zip

# Build for Apple Silicon (arm64)
echo ""
echo "🍎 Building for Apple Silicon (arm64)..."
swift build -c release --arch arm64

# Build for Intel (x86_64)
echo ""
echo "🖥️  Building for Intel (x86_64)..."
swift build -c release --arch x86_64

# Create universal binary with lipo
echo ""
echo "🔗 Creating universal binary..."
mkdir -p .build/universal
lipo -create \
    .build/arm64-apple-macosx/release/IMAPMenu \
    .build/x86_64-apple-macosx/release/IMAPMenu \
    -output .build/universal/IMAPMenu

# Verify the binary
echo ""
echo "✅ Verifying universal binary..."
lipo -info .build/universal/IMAPMenu

# Create app bundle
echo ""
echo "📦 Creating app bundle..."
mkdir -p IMAPMenu.app/Contents/MacOS
mkdir -p IMAPMenu.app/Contents/Resources

# Copy binary
cp .build/universal/IMAPMenu IMAPMenu.app/Contents/MacOS/

# Create Info.plist
cat > IMAPMenu.app/Contents/Info.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>IMAPMenu</string>
    <key>CFBundleIdentifier</key>
    <string>com.imapmenu.app</string>
    <key>CFBundleName</key>
    <string>IMAP Menu</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

# Code sign (ad-hoc signature for local use)
echo ""
echo "✍️  Code signing..."
codesign --force --deep --sign - IMAPMenu.app

# Create zip for distribution
echo ""
echo "📦 Creating distribution package..."
zip -r IMAPMenu-universal.zip IMAPMenu.app

echo ""
echo "✅ Build complete!"
echo ""
echo "📍 Universal app: IMAPMenu.app"
echo "📦 Distribution: IMAPMenu-universal.zip"
echo ""

# Get file size
SIZE=$(du -h IMAPMenu-universal.zip | awk '{print $1}')
echo "📊 Package size: $SIZE"

# Check if gh CLI is available for GitHub release
if command -v gh &> /dev/null; then
    echo ""
    read -p "🚀 Create GitHub release? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        read -p "📝 Enter version tag (e.g., v1.0.0): " VERSION
        read -p "📝 Enter release title: " TITLE

        echo ""
        echo "🚀 Creating GitHub release..."
        gh release create "$VERSION" \
            IMAPMenu-universal.zip \
            --title "$TITLE" \
            --notes "Universal binary supporting both Intel and Apple Silicon Macs.

## Installation
1. Download IMAPMenu-universal.zip
2. Extract and copy IMAPMenu.app to /Applications/
3. Launch and configure your IMAP accounts

## Features
- 🔔 Real-time notifications with unread count badges
- 📬 Multiple accounts & folders support
- 🎨 Customizable icons (500+ SF Symbols) with custom colors
- ⚡ Instant mark read/unread/delete operations
- 🔍 Email filtering by sender and subject
- 📐 Adjustable popover sizes
- 🔐 Secure password storage in Keychain
- 🚀 Fast ~2 second load times
- 📧 Full HTML email rendering

See README for detailed setup instructions."

        echo ""
        echo "✅ GitHub release created!"
    fi
else
    echo ""
    echo "💡 To create a GitHub release:"
    echo "   1. Install GitHub CLI: brew install gh"
    echo "   2. Run: gh release create v1.0.0 IMAPMenu-universal.zip --title 'Release Title'"
    echo "   Or manually upload IMAPMenu-universal.zip to GitHub Releases"
fi

echo ""
echo "🎉 Done!"
