FROM erlang:21.1

RUN apt-get update && apt-get install -y \
        dnsutils ipvsadm \
 && rm -rf /var/lib/apt/lists/* \
 && curl -LO https://launchpad.net/ubuntu/+archive/primary/+files/libsodium18_1.0.13-1_amd64.deb \
 && curl -LO https://launchpad.net/ubuntu/+archive/primary/+files/libsodium-dev_1.0.13-1_amd64.deb \
 && dpkg -i libsodium18_1.0.13-1_amd64.deb \
 && dpkg -i libsodium-dev_1.0.13-1_amd64.deb \
 && rm libsodium18_1.0.13-1_amd64.deb libsodium-dev_1.0.13-1_amd64.deb

CMD ["bash"]
