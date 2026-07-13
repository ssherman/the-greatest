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

# Format: cert-name;comma-separated-SANs;registration-email
# An empty SAN field means the cert covers only the cert-name.
DOMAINS=(
    "thegreatestmusic.org;www.thegreatestmusic.org;admin@thegreatestmusic.org"
    "thegreatest.games;www.thegreatest.games;admin@thegreatest.games"
    "thegreatestmovies.org;www.thegreatestmovies.org;admin@thegreatestmovies.org"
    "new.thegreatestbooks.org;;admin@thegreatestbooks.org"
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

for entry in "${DOMAINS[@]}"; do
    IFS=';' read -r cert_name sans email <<< "$entry"

    domain_args=(-d "$cert_name")
    if [ -n "$sans" ]; then
        IFS=',' read -ra san_list <<< "$sans"
        for san in "${san_list[@]}"; do
            domain_args+=(-d "$san")
        done
    fi

    echo "Generating certificate for $cert_name (${#domain_args[@]} names)..."

    docker run --rm \
        -v "$CERT_DIR:/etc/letsencrypt" \
        -v "$TEMP_CREDS:/cloudflare.ini:ro" \
        certbot/dns-cloudflare certonly \
        --dns-cloudflare \
        --dns-cloudflare-credentials /cloudflare.ini \
        --dns-cloudflare-propagation-seconds 60 \
        "${domain_args[@]}" \
        --non-interactive \
        --agree-tos \
        --email "$email" \
        --cert-name "$cert_name"

    if [ $? -eq 0 ]; then
        echo "✓ Certificate for $cert_name generated successfully"
    else
        echo "✗ Failed to generate certificate for $cert_name"
        exit 1
    fi
    echo ""
done

echo "All certificates generated successfully!"
echo ""
echo "Certificate locations:"
for entry in "${DOMAINS[@]}"; do
    IFS=';' read -r cert_name _ _ <<< "$entry"
    echo "  $cert_name: $CERT_DIR/live/$cert_name/"
done

echo ""
echo "Reloading nginx..."
docker compose -f "$APP_DIR/docker-compose.prod.yml" exec nginx nginx -s reload

echo ""
echo "Certificate generation complete!"
