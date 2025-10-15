#!/bin/bash
set -e

if [ -z "$CLOUDFLARE_API_TOKEN" ]; then
    echo "Error: CLOUDFLARE_API_TOKEN environment variable is required"
    exit 1
fi

DOMAINS=(
    "thegreatestmusic.org"
    "thegreatest.games"
    "thegreatestmovies.org"
)

CERT_DIR="/etc/letsencrypt"

echo "Installing certbot and Cloudflare DNS plugin..."
apt-get update
apt-get install -y certbot python3-certbot-dns-cloudflare

echo "Creating Cloudflare credentials file..."
mkdir -p /root/.secrets/certbot
cat > /root/.secrets/certbot/cloudflare.ini << EOF
dns_cloudflare_api_token = $CLOUDFLARE_API_TOKEN
EOF
chmod 600 /root/.secrets/certbot/cloudflare.ini

for domain in "${DOMAINS[@]}"; do
    echo "Generating certificate for $domain and www.$domain..."

    certbot certonly \
        --dns-cloudflare \
        --dns-cloudflare-credentials /root/.secrets/certbot/cloudflare.ini \
        --dns-cloudflare-propagation-seconds 60 \
        -d "$domain" \
        -d "www.$domain" \
        --non-interactive \
        --agree-tos \
        --email admin@$domain \
        --cert-name "$domain"

    if [ $? -eq 0 ]; then
        echo "Certificate for $domain generated successfully"
    else
        echo "Failed to generate certificate for $domain"
        exit 1
    fi
done

echo "All certificates generated successfully!"
echo "Certificate locations:"
for domain in "${DOMAINS[@]}"; do
    echo "  $domain: $CERT_DIR/live/$domain/"
done

echo ""
echo "Reloading nginx..."
docker compose -f /home/deploy/apps/the-greatest/docker-compose.prod.yml exec nginx nginx -s reload

echo "Certificate generation complete!"
