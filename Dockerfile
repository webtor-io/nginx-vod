FROM alpine:3.12.1 AS base

FROM base AS build

RUN apk add --no-cache curl build-base openssl openssl-dev zlib-dev linux-headers pcre-dev
RUN mkdir nginx nginx-vod-module nginx-secure-token-module

ARG NGINX_VERSION=1.19.4
ARG VOD_MODULE_VERSION=8d2af4a35969e6e499208678662f93b0097827d5
ARG SECURE_TOKEN_MODULE_VERSION=95bdc0d1aca06ea7fe42555f71e65910bd74914d


RUN curl -sL https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz | tar -C /nginx --strip 1 -xz
RUN curl -sL https://github.com/kaltura/nginx-vod-module/archive/${VOD_MODULE_VERSION}.tar.gz | tar -C /nginx-vod-module --strip 1 -xz
RUN curl -sL https://github.com/kaltura/nginx-secure-token-module/archive/${SECURE_TOKEN_MODULE_VERSION}.tar.gz | tar -C /nginx-secure-token-module --strip 1 -xz

WORKDIR /nginx
RUN ./configure --prefix=/usr/local/nginx \
	--add-module=../nginx-vod-module \
	--add-module=../nginx-secure-token-module \
	--with-http_ssl_module \
	--with-file-aio \
	--with-threads \
	--with-cc-opt="-O3"
RUN make
RUN make install
RUN rm -rf /usr/local/nginx/html /usr/local/nginx/conf/*.default
COPY ./conf/ /usr/local/nginx/conf/

FROM base
RUN apk add --no-cache ca-certificates openssl pcre zlib
COPY --from=build /usr/local/nginx /usr/local/nginx
ENTRYPOINT ["/usr/local/nginx/sbin/nginx"]
CMD ["-g", "daemon off;"]
