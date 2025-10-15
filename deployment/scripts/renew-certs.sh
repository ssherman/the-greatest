#!/bin/bash
set -e

if [ -z "$CLOUDFLARE_API_TOKEN" ]; then
    echo "Error: CLOUDFLARE_API_TOKEN environment variable is required"
    exit 1
fi

echo "Renewing SSL certificates..."

certbot renew \
    --dns-cloudflare \
    --dns-cloudflare-credentials /root/.secrets/certbot/cloudflare.ini \
    --dns-cloudflare-propagation-seconds 60 \
    --quiet

if [ $? -eq 0 ]; then
    echo "Certificate renewal successful"

    echo "Reloading nginx..."
    docker compose -f /home/deploy/apps/the-greatest/docker-compose.prod.yml exec nginx nginx -s reload

    echo "Nginx reloaded successfully"
else
    echo "Certificate renewal failed"
    exit 1
fi

echo "Certificate renewal complete!"
