# Pinned on purpose, not latest: nginx is compiled here and runs on the same
# base, so the build and runtime stages must share musl, OpenSSL and PCRE.
# self-hosted copies /usr/local/nginx onto its own Alpine (ALPINE_VER).
FROM alpine:3.24 AS base

FROM base AS build

ENV NGINX_VERSION=1.30.6 \
    VOD_MODULE_COMMIT_HASH=26f06877b0f2a2336e59cda93a3de18d7b23a3e2 \
    SECURE_TOKEN_MODULE_COMMIT_HASH=24f7b99d9b665e11c92e585d6645ed6f45f7d310

# kaltura/nginx-vod-module and kaltura/nginx-secure-token-module were removed
# from GitHub around 2026-11-07 (the repositories answer 404). webtor-io keeps
# unchanged mirrors. The modules are fetched by commit, so git checks what it
# gets against the pinned hash whichever host serves it; curl -f makes a
# failed download say so instead of feeding an error page to tar.
ARG VOD_MODULE_REPO=https://github.com/webtor-io/nginx-vod-module.git
ARG SECURE_TOKEN_MODULE_REPO=https://github.com/webtor-io/nginx-secure-token-module.git

RUN apk add --no-cache curl git build-base openssl openssl-dev zlib-dev linux-headers pcre-dev && \
    mkdir nginx && \
    curl -fsSL https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz | tar -C /nginx --strip 1 -xz && \
    for m in "/nginx-vod-module ${VOD_MODULE_REPO} ${VOD_MODULE_COMMIT_HASH}" \
             "/nginx-secure-token-module ${SECURE_TOKEN_MODULE_REPO} ${SECURE_TOKEN_MODULE_COMMIT_HASH}"; do \
        set -- $m && git init -q "$1" && git -C "$1" fetch -q --depth 1 "$2" "$3" && \
        git -C "$1" checkout -q FETCH_HEAD && test "$(git -C "$1" rev-parse HEAD)" = "$3" || exit 1; \
    done

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