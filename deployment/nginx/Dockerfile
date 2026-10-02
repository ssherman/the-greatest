FROM nginx:latest

RUN apt-get update && apt-get install -y --no-install-recommends wget curl jq ca-certificates

# Create directories with proper permissions for nginx user
RUN mkdir -p /etc/nginx/snippets /etc/nginx/templates /etc/nginx/sites-enabled /etc/nginx/certs && \
    chmod 755 /etc/nginx/sites-enabled && \
    chown -R nginx:nginx /etc/nginx/sites-enabled

# Install nginx-ultimate-bad-bot-blocker using automated installer
# Reference: https://github.com/mitchellkrogza/nginx-ultimate-bad-bot-blocker
RUN wget https://raw.githubusercontent.com/mitchellkrogza/nginx-ultimate-bad-bot-blocker/master/install-ngxblocker -O /usr/local/sbin/install-ngxblocker
RUN chmod +x /usr/local/sbin/install-ngxblocker
RUN /usr/local/sbin/install-ngxblocker -x
RUN /usr/local/sbin/setup-ngxblocker -x -e conf

# Drop the base image's stock server block (listens on [::]:80, serves /usr/share/nginx/html).
# It is not ours, it answers any Host on IPv6 inside the container, and it is what the
# healthcheck hits when `localhost` resolves to ::1. Our servers are the only servers.
RUN rm -f /etc/nginx/conf.d/default.conf

# Origin lockdown (docs/superpowers/specs/2026-09-14-origin-lockdown-design.md):
# Cloudflare's ranges become real_ip + geo snippets at build time, so every deploy
# (which rebuilds this image --no-cache) refreshes them. A bad fetch fails the build.
COPY bin/generate-cloudflare-snippets.sh /usr/local/sbin/generate-cloudflare-snippets.sh
COPY certs/cloudflare-origin-pull-ca.pem /etc/nginx/certs/cloudflare-origin-pull-ca.pem
COPY snippets/cloudflare-only.conf /etc/nginx/snippets/cloudflare-only.conf
RUN chmod +x /usr/local/sbin/generate-cloudflare-snippets.sh && \
    /usr/local/sbin/generate-cloudflare-snippets.sh /etc/nginx/snippets

COPY nginx.conf /etc/nginx/nginx.conf
COPY snippets/ssl-params.conf /etc/nginx/snippets/ssl-params.conf
COPY snippets/proxy-params.conf /etc/nginx/snippets/proxy-params.conf

# Validate nginx.conf and the generated snippets at build time. The site template is
# rendered at container start and is covered by deployment/nginx/test/local-lockdown-test.sh.
RUN nginx -t

EXPOSE 80 443

CMD ["nginx", "-g", "daemon off;"]
