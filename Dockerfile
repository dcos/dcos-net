FROM alpine:3.6

ENV OTP_VERSION="20.1.7"

RUN set -xe \
    && OTP_DOWNLOAD_URL="https://github.com/erlang/otp/archive/OTP-${OTP_VERSION}.tar.gz" \
    && apk add --no-cache --virtual .fetch-deps \
        curl \
        ca-certificates \
    && curl -fSL -o otp-src.tar.gz "$OTP_DOWNLOAD_URL" \
    && apk add --no-cache --virtual .build-deps \
        dpkg-dev dpkg \
	gcc \
	g++ \
        libc-dev \
        linux-headers \
        make \
        autoconf \
        ncurses-dev \
        openssl-dev \
        unixodbc-dev \
        lksctp-tools-dev \
        tar \
    && export ERL_TOP="/usr/src/otp_src_${OTP_VERSION%%@*}" \
    && mkdir -vp $ERL_TOP \
    && tar -xzf otp-src.tar.gz -C $ERL_TOP --strip-components=1 \
    && rm otp-src.tar.gz \
    && ( cd $ERL_TOP \
      && ./otp_build autoconf \
      && gnuArch="$(dpkg-architecture --query DEB_BUILD_GNU_TYPE)" \
      && ./configure --build="$gnuArch" \
      && make -j$(getconf _NPROCESSORS_ONLN) \
      && make install ) \
    && rm -rf $ERL_TOP \
    && find /usr/local -regex '/usr/local/lib/erlang/\(lib/\|erts-\).*/\(man\|doc\|obj\|c_src\|emacs\|info\|examples\)' | xargs rm -rf \
    && find /usr/local -name src | xargs -r find | grep -v '\.hrl$' | xargs rm -v || true \
    && find /usr/local -name src | xargs -r find | xargs rmdir -vp || true \
    && scanelf --nobanner -E ET_EXEC -BF '%F' --recursive /usr/local | xargs -r strip --strip-all \
    && scanelf --nobanner -E ET_DYN -BF '%F' --recursive /usr/local | xargs -r strip --strip-unneeded \
    && runDeps="$( \
        scanelf --needed --nobanner --format '%n#p' --recursive /usr/local \
            | tr ',' '\n' \
            | sort -u \
            | awk 'system("[ -e /usr/local/lib/" $1 " ]") == 0 { next } { print "so:" $1 }' \
    )" \
    && apk add --virtual .erlang-rundeps $runDeps lksctp-tools \
    && apk del .fetch-deps .build-deps

CMD ["erl"]

RUN apk update; apk add \
	git\
	build-base\
	curl\
	libsodium-dev\
	ipvsadm\
	bind-tools\
	bridge-utils\
	iproute2\
	bash

ENV CC=gcc
WORKDIR /dcos-net
