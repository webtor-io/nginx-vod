# Pinned on purpose, not latest: nginx is compiled here and runs on the same
# base, so the build and runtime stages must share musl, OpenSSL and PCRE.
# self-hosted copies /usr/local/nginx onto its own Alpine (ALPINE_VER).
FROM alpine:3.24 AS base

FROM base AS build

ENV NGINX_VERSION=1.30.6 \
    VOD_MODULE_COMMIT_HASH=26f06877b0f2a2336e59cda93a3de18d7b23a3e2 \
    SECURE_TOKEN_MODULE_COMMIT_HASH=24f7b99d9b665e11c92e585d6645ed6f45f7d310

RUN apk add --no-cache curl build-base openssl openssl-dev zlib-dev linux-headers pcre-dev && \
    mkdir nginx nginx-vod-module nginx-secure-token-module && \
    curl -sL https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz | tar -C /nginx --strip 1 -xz && \
    curl -sL https://github.com/kaltura/nginx-vod-module/archive/${VOD_MODULE_COMMIT_HASH}.tar.gz | tar -C /nginx-vod-module --strip 1 -xz && \
    curl -sL https://github.com/kaltura/nginx-secure-token-module/archive/${SECURE_TOKEN_MODULE_COMMIT_HASH}.tar.gz | tar -C /nginx-secure-token-module --strip 1 -xz

WORKDIR /nginx
# -std=gnu17: gcc 15 defaults to C23, where nginx-vod-module's "void f()"
# exit handlers mean "void f(void)" and no longer match nginx's
# void (*)(ngx_cycle_t *) hooks; gcc 14+ makes that incompatible-pointer-types
# an error. gnu17 is gcc 14's default. The module has no newer upstream commit.
RUN ./configure --prefix=/usr/local/nginx \
    --add-module=../nginx-vod-module \
    --add-module=../nginx-secure-token-module \
    --with-http_ssl_module \
    --with-file-aio \
    --with-threads \
    --with-cc-opt="-O3 -std=gnu17" && \
    make && make install && \
    rm -rf /nginx /nginx-vod-module /nginx-secure-token-module && \
    rm -rf /usr/local/nginx/html /usr/local/nginx/conf/*.default

COPY ./conf/ /usr/local/nginx/conf/

FROM base
RUN apk add --no-cache ca-certificates openssl pcre zlib
COPY --from=build /usr/local/nginx /usr/local/nginx
# nginx is PID 1. SIGTERM, the default, is its fast shutdown: segments in
# flight are cut. SIGQUIT closes the listener and lets them finish. Docker
# and containerd send the image's STOPSIGNAL. worker_shutdown_timeout bounds
# the wait; the deployment passes it with -g, next to its grace period, so
# conf/nginx.conf must not set it (a duplicate fails the start).
# tests/graceful_stop.sh checks both.
STOPSIGNAL SIGQUIT
ENTRYPOINT ["/usr/local/nginx/sbin/nginx"]
CMD ["-g", "daemon off;"]