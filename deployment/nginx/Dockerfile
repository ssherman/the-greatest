FROM nginx:alpine

RUN apk add --no-cache bash curl

RUN mkdir -p /etc/nginx/bots.d && \
    cd /etc/nginx/bots.d && \
    curl -O https://raw.githubusercontent.com/mitchellkrogza/nginx-ultimate-bad-bot-blocker/master/bots.d/blockbots.conf && \
    curl -O https://raw.githubusercontent.com/mitchellkrogza/nginx-ultimate-bad-bot-blocker/master/bots.d/ddos.conf

RUN mkdir -p /etc/nginx/conf.d /etc/nginx/snippets /etc/nginx/templates

COPY nginx.conf /etc/nginx/nginx.conf
COPY snippets/ssl-params.conf /etc/nginx/snippets/ssl-params.conf
COPY snippets/proxy-params.conf /etc/nginx/snippets/proxy-params.conf

EXPOSE 80 443

CMD ["nginx", "-g", "daemon off;"]
