#!/bin/bash

# Armadillo Development Helper Script
# Generate and display certificate fingerprint for development

set -e

CERT_PATH="${1:-/tmp/armadillo_dev_cert.pem}"

echo "🛡️  Armadillo Certificate Fingerprint Tool"
echo "=========================================="

if [ ! -f "$CERT_PATH" ]; then
    echo "❌ Certificate not found at: $CERT_PATH"
    echo ""
    echo "To generate a development certificate:"
    echo "  openssl req -x509 -newkey rsa:2048 -keyout /tmp/armadillo_dev_key.pem -out $CERT_PATH -days 365 -nodes -subj '/CN=armadillo-dev'"
    exit 1
fi

echo "📄 Certificate: $CERT_PATH"
echo ""

# Calculate SHA-256 fingerprint
FINGERPRINT=$(openssl x509 -in "$CERT_PATH" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':' | tr '[:upper:]' '[:lower:]')

echo "🔑 SHA-256 Fingerprint:"
echo "   sha256:$FINGERPRINT"
echo ""

# Display certificate details
echo "📋 Certificate Details:"
openssl x509 -in "$CERT_PATH" -noout -subject -dates
echo ""

echo "✅ Use this fingerprint in your QR codes and certificate pinning logic"