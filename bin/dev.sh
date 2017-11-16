#!/bin/bash

if ! hostname | grep dcos-docker > /dev/null; then
    HOST=${1:-dcos-docker-master1}
    exec docker exec -it ${HOST} $(pwd)/bin/dev.sh ${@:2}
fi

# Now we are in docker

SCRIPT=$(readlink -f $0 || true)
cd $(dirname $(dirname $SCRIPT))

### Pre-Build
if ! which gcc g++ make dig ip ipvsadm > /dev/null 2> /dev/null; then
    yum install -y make gcc gcc-c++ bind-utils iproute2 ipvsadm || exit 2
fi

### Compile configuration
export CFLAGS="-I/opt/mesosphere/include -I/opt/mesosphere/active/libsodium/include"
export LDFLAGS="-L/opt/mesosphere/lib -L/opt/mesosphere/active/libsodium/lib -Wl,-rpath=/opt/mesosphere/active/libsodium/lib"

###
case "$1" in
    rebar3)
        exec /opt/mesosphere/bin/dcos-shell ./rebar3 "${@:2}"
        ;;
    make)
        exec /opt/mesosphere/bin/dcos-shell make "${@:2}"
        ;;
    systemctl)
        exec /opt/mesosphere/bin/dcos-shell systemctl "${@:2}"
        ;;
    console)
        exec ./rebar3 shell --config config/sys.config --name ${NAME} --setcookie minuteman \
            --apps mnesia,dcos_dns,dcos_l4lb,dcos_overlay,dcos_rest,dcos_net,recon
        ;;
    *)
        if [ -n "$1" ]; then
            echo "Usage: $0" >&2
            echo "       $0 dcos-docker-name" >&2
            echo "       $0 dcos-docker-name rebar3 args" >&2
            echo "       $0 dcos-docker-name make args" >&2
            exit 1
        fi
esac

### Prepare to start
systemctl stop dcos-net.service

### resolv.conf
source /opt/mesosphere/etc/dns_config || exit 1
( echo "options timeout:1" &&
  echo "options attempts:3" &&
  echo $RESOLVERS | sed -re 's/(^|[,])/\nnameserver /g' ) > /etc/resolv.conf

### ExecStartPre
export ENABLE_CHECK_TIME=false
systemctl cat dcos-net | sed -nre 's/ExecStartPre=//p' | tr '\n' '\0' | \
    xargs -0 -n 1 /opt/mesosphere/bin/dcos-shell bash -c

### Run
export DCOS_NET_EBIN="$(pwd)/_build/default/lib/dcos_net/ebin"
export DCOS_NET_ENV_CMD="${SCRIPT}"
exec /opt/mesosphere/bin/dcos-net-env console
