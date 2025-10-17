FROM nginx:alpine

RUN apk add --no-cache bash curl wget

# Install nginx-ultimate-bad-bot-blocker using automated installer
# Reference: https://github.com/mitchellkrogza/nginx-ultimate-bad-bot-blocker
RUN wget https://raw.githubusercontent.com/mitchellkrogza/nginx-ultimate-bad-bot-blocker/master/install-ngxblocker -O /usr/local/sbin/install-ngxblocker && \
    chmod +x /usr/local/sbin/install-ngxblocker && \
    /usr/local/sbin/install-ngxblocker -x && \
    /usr/local/sbin/setup-ngxblocker -x -e conf

# Create additional directories
RUN mkdir -p /etc/nginx/snippets /etc/nginx/templates

COPY nginx.conf /etc/nginx/nginx.conf
COPY snippets/ssl-params.conf /etc/nginx/snippets/ssl-params.conf
COPY snippets/proxy-params.conf /etc/nginx/snippets/proxy-params.conf

EXPOSE 80 443

CMD ["nginx", "-g", "daemon off;"]
