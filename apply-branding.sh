#!/bin/bash
# QAYDAO Branding Script - Run after container recreation
# Usage: bash /root/chat-qaydao/apply-branding.sh

set -e
THEME_DIR="/root/chat-qaydao/custom-theme"
CONTAINER="chatwoot_web"

echo "Applying QAYDAO branding to Chatwoot..."

# Wait for container to be ready
until docker exec $CONTAINER echo "ready" 2>/dev/null; do
  echo "Waiting for container..."
  sleep 5
done

# Replace logo SVGs
for dir in /app/public/brand-assets /app/public/packs/brand-assets; do
  docker cp "$THEME_DIR/qaydao-logo.svg" "$CONTAINER:${dir}/logo.svg"
  docker cp "$THEME_DIR/qaydao-logo-dark.svg" "$CONTAINER:${dir}/logo_dark.svg"
  docker cp "$THEME_DIR/qaydao-logo-icon.svg" "$CONTAINER:${dir}/logo_thumbnail.svg"
done

# Replace favicons
for size in 16 32 96 512; do
  docker cp "$THEME_DIR/icon-${size}x${size}.png" "$CONTAINER:/app/public/favicon-${size}x${size}.png"
  docker cp "$THEME_DIR/icon-${size}x${size}.png" "$CONTAINER:/app/public/packs/favicon-${size}x${size}.png"
done
for size in 16 32 96; do
  docker cp "$THEME_DIR/icon-${size}x${size}.png" "$CONTAINER:/app/public/favicon-badge-${size}x${size}.png"
  docker cp "$THEME_DIR/icon-${size}x${size}.png" "$CONTAINER:/app/public/packs/favicon-badge-${size}x${size}.png"
done

# Replace Android icons
for size in 36 48 72 96 144 192; do
  docker cp "$THEME_DIR/icon-${size}x${size}.png" "$CONTAINER:/app/public/android-icon-${size}x${size}.png"
done

# Replace Apple icons
for size in 57 60 72 76 114 120 144 152 180; do
  docker cp "$THEME_DIR/icon-${size}x${size}.png" "$CONTAINER:/app/public/apple-icon-${size}x${size}.png"
done
docker cp "$THEME_DIR/icon-180x180.png" "$CONTAINER:/app/public/apple-icon.png"
docker cp "$THEME_DIR/icon-180x180.png" "$CONTAINER:/app/public/apple-icon-precomposed.png"

# Replace MS icons
for size in 70 144 150 310; do
  docker cp "$THEME_DIR/icon-${size}x${size}.png" "$CONTAINER:/app/public/ms-icon-${size}x${size}.png"
  docker cp "$THEME_DIR/icon-${size}x${size}.png" "$CONTAINER:/app/public/packs/ms-icon-${size}x${size}.png"
done

# Update manifest and error pages
docker exec $CONTAINER sed -i 's/"Chatwoot"/"QAYDAO"/g' /app/public/manifest.json
docker exec $CONTAINER sed -i 's/"Chatwoot"/"QAYDAO"/g' /app/public/packs/manifest.json 2>/dev/null || true
docker exec $CONTAINER sed -i 's/Chatwoot/QAYDAO/g' /app/public/404.html
docker exec $CONTAINER sed -i 's/Chatwoot/QAYDAO/g' /app/public/422.html
docker exec $CONTAINER sed -i 's/Chatwoot/QAYDAO/g' /app/public/500.html

echo "✅ QAYDAO branding applied successfully!"
