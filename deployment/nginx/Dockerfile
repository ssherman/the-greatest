FROM nginx:latest

RUN apt-get update
RUN apt-get install -y wget

# Create directories with proper permissions for nginx user
RUN mkdir -p /etc/nginx/snippets /etc/nginx/templates /etc/nginx/sites-enabled && \
    chmod 755 /etc/nginx/sites-enabled && \
    chown -R nginx:nginx /etc/nginx/sites-enabled

# Install nginx-ultimate-bad-bot-blocker using automated installer
# Reference: https://github.com/mitchellkrogza/nginx-ultimate-bad-bot-blocker
RUN wget https://raw.githubusercontent.com/mitchellkrogza/nginx-ultimate-bad-bot-blocker/master/install-ngxblocker -O /usr/local/sbin/install-ngxblocker
RUN chmod +x /usr/local/sbin/install-ngxblocker
RUN /usr/local/sbin/install-ngxblocker -x
RUN /usr/local/sbin/setup-ngxblocker -x -e conf

COPY nginx.conf /etc/nginx/nginx.conf
COPY snippets/ssl-params.conf /etc/nginx/snippets/ssl-params.conf
COPY snippets/proxy-params.conf /etc/nginx/snippets/proxy-params.conf

EXPOSE 80 443

CMD ["nginx", "-g", "daemon off;"]
