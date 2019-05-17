FROM erlang:22.0

RUN apt-get update && apt-get install -y \
        dnsutils ipvsadm \
 && rm -rf /var/lib/apt/lists/* \
 && git clone --branch stable https://github.com/jedisct1/libsodium.git \
 && git -C libsodium checkout b732443c442239c2e0184820e9b23cca0de0828c \
 && ( cd libsodium && ./autogen.sh && ./configure ) \
 && make -C libsodium -j$(getconf _NPROCESSORS_ONLN) install \
 && rm -r libsodium

CMD ["bash"]
