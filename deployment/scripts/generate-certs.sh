#!/bin/bash
set -e

# This script generates SSL certificates using certbot in a Docker container
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

DOMAINS=(
    "thegreatestmusic.org"
    "thegreatest.games"
    "thegreatestmovies.org"
)

echo "Generating SSL certificates using certbot Docker container..."
echo ""

# Create temporary Cloudflare credentials file
TEMP_CREDS=$(mktemp)
trap "rm -f $TEMP_CREDS" EXIT
cat > "$TEMP_CREDS" << EOF
dns_cloudflare_api_token = $CLOUDFLARE_API_TOKEN
EOF
chmod 600 "$TEMP_CREDS"

for domain in "${DOMAINS[@]}"; do
    echo "Generating certificate for $domain and www.$domain..."

    docker run --rm \
        -v "$CERT_DIR:/etc/letsencrypt" \
        -v "$TEMP_CREDS:/cloudflare.ini:ro" \
        certbot/dns-cloudflare certonly \
        --dns-cloudflare \
        --dns-cloudflare-credentials /cloudflare.ini \
        --dns-cloudflare-propagation-seconds 60 \
        -d "$domain" \
        -d "www.$domain" \
        --non-interactive \
        --agree-tos \
        --email "admin@$domain" \
        --cert-name "$domain"

    if [ $? -eq 0 ]; then
        echo "✓ Certificate for $domain generated successfully"
    else
        echo "✗ Failed to generate certificate for $domain"
        exit 1
    fi
    echo ""
done

echo "All certificates generated successfully!"
echo ""
echo "Certificate locations:"
for domain in "${DOMAINS[@]}"; do
    echo "  $domain: $CERT_DIR/live/$domain/"
done

echo ""
echo "Reloading nginx..."
docker compose -f "$APP_DIR/docker-compose.prod.yml" exec nginx nginx -s reload

echo ""
echo "Certificate generation complete!"
