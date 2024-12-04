FROM alpine:3.18 AS base

FROM base AS build

ENV NGINX_VERSION=1.26.2 \
    VOD_MODULE_COMMIT_HASH=26f06877b0f2a2336e59cda93a3de18d7b23a3e2 \
    SECURE_TOKEN_MODULE_COMMIT_HASH=24f7b99d9b665e11c92e585d6645ed6f45f7d310

RUN apk add --no-cache curl build-base openssl openssl-dev zlib-dev linux-headers pcre-dev && \
    mkdir nginx nginx-vod-module nginx-secure-token-module && \
    curl -sL https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz | tar -C /nginx --strip 1 -xz && \
    curl -sL https://github.com/kaltura/nginx-vod-module/archive/${VOD_MODULE_COMMIT_HASH}.tar.gz | tar -C /nginx-vod-module --strip 1 -xz && \
    curl -sL https://github.com/kaltura/nginx-secure-token-module/archive/${SECURE_TOKEN_MODULE_COMMIT_HASH}.tar.gz | tar -C /nginx-secure-token-module --strip 1 -xz

WORKDIR /nginx
RUN ./configure --prefix=/usr/local/nginx \
    --add-module=../nginx-vod-module \
    --add-module=../nginx-secure-token-module \
    --with-http_ssl_module \
    --with-file-aio \
    --with-threads \
    --with-cc-opt="-O3" && \
    make && make install && \
    rm -rf /nginx /nginx-vod-module /nginx-secure-token-module && \
    rm -rf /usr/local/nginx/html /usr/local/nginx/conf/*.default

COPY ./conf/ /usr/local/nginx/conf/

FROM base
RUN apk add --no-cache ca-certificates openssl pcre zlib
COPY --from=build /usr/local/nginx /usr/local/nginx
ENTRYPOINT ["/usr/local/nginx/sbin/nginx"]
CMD ["-g", "daemon off;"]