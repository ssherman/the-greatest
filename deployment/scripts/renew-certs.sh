#!/bin/bash
set -e

# This script renews SSL certificates using certbot in a Docker container
# It sources the CLOUDFLARE_API_TOKEN from the .env file (decrypted by SOPS during deployment)

APP_DIR="/home/deploy/apps/the-greatest"
CERT_DIR="/etc/letsencrypt"

# Source environment variables from .env file
if [ -f "$APP_DIR/.env" ]; then
    # Export only CLOUDFLARE_API_TOKEN, don't pollute environment with all vars
    export CLOUDFLARE_API_TOKEN=$(grep '^CLOUDFLARE_API_TOKEN=' "$APP_DIR/.env" | cut -d '=' -f2-)
fi

if [ -z "$CLOUDFLARE_API_TOKEN" ]; then
    echo "Error: CLOUDFLARE_API_TOKEN not found in $APP_DIR/.env"
    echo "Make sure SOPS secrets have been decrypted and deployed"
    exit 1
fi

echo "Renewing SSL certificates using certbot Docker container..."

# Create temporary Cloudflare credentials file
TEMP_CREDS=$(mktemp)
trap "rm -f $TEMP_CREDS" EXIT
cat > "$TEMP_CREDS" << EOF
dns_cloudflare_api_token = $CLOUDFLARE_API_TOKEN
EOF
chmod 600 "$TEMP_CREDS"

docker run --rm \
    -v "$CERT_DIR:/etc/letsencrypt" \
    -v "$TEMP_CREDS:/cloudflare.ini:ro" \
    certbot/dns-cloudflare renew \
    --dns-cloudflare \
    --dns-cloudflare-credentials /cloudflare.ini \
    --dns-cloudflare-propagation-seconds 60 \
    --quiet

if [ $? -eq 0 ]; then
    echo "✓ Certificate renewal successful"

    echo "Reloading nginx..."
    docker compose -f "$APP_DIR/docker-compose.prod.yml" exec nginx nginx -s reload

    echo "✓ Nginx reloaded successfully"
else
    echo "✗ Certificate renewal failed"
    exit 1
fi

echo ""
echo "Certificate renewal complete!"
