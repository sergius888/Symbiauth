#!/bin/bash

# Armadillo Development Runner Script
# Starts all components for local development

set -e

echo "🛡️  Starting Armadillo Development Environment"
echo "============================================="

# Check if required tools are installed
command -v cargo >/dev/null 2>&1 || { echo "❌ Rust/Cargo not found. Please install Rust."; exit 1; }
command -v node >/dev/null 2>&1 || { echo "❌ Node.js not found. Please install Node.js."; exit 1; }

# Build Rust agent
echo "🦀 Building Rust agent..."
cd apps/agent-macos
cargo build
cd ../..

# Build Chrome extension
echo "🌐 Building Chrome extension..."
cd packages/webext
npm install
npm run build
cd ../..

echo ""
echo "✅ Build complete!"
echo ""
echo "📱 Next steps:"
echo "   1. Open apps/tls-terminator-macos/ArmadilloTLS.xcodeproj in Xcode"
echo "   2. Build and run the Swift TLS terminator"
echo "   3. Start the Rust agent: ./apps/agent-macos/target/debug/agent-macos"
echo "   4. Load the Chrome extension from packages/webext/dist/"
echo "   5. Open apps/app-ios/ArmadilloMobile.xcodeproj in Xcode for iOS app"
echo ""
echo "🔧 Development commands:"
echo "   make build    - Build all components"
echo "   make test     - Run all tests"
echo "   make lint     - Run linters"
echo "   make clean    - Clean build artifacts"