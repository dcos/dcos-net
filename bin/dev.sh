#!/bin/sh

if ! hostname | grep dcos-docker > /dev/null; then
    HOST=${1:-dcos-docker-master1}
    exec docker exec -it ${HOST} /bin/sh -c "cd $(pwd) && exec ./bin/dev.sh"
fi


### EnvironmentFile
eval $(
    systemctl cat dcos-net | \
        sed -nre 's/EnvironmentFile=-?//p' | \
        xargs sed -nre '/^[^# ]/s/^/export /p' 2> /dev/null | \
        sed -re 's/=([^"])/="\1/;s/([^"])$/\1"/'
)

### Environment
eval $(
    systemctl cat dcos-net | sed -nre 's/Environment=/export /p'
)


### Pre-Build
if ! which gcc g++ make dig ip ipvsadm > /dev/null 2> /dev/null; then
    yum install -y make gcc gcc-c++ bind-utils iproute2 ipvsadm || exit 2
fi
export CFLAGS="-I/opt/mesosphere/include -I/opt/mesosphere/active/libsodium/include"
export LDFLAGS="-L/opt/mesosphere/lib -L/opt/mesosphere/active/libsodium/lib -Wl,-rpath=/opt/mesosphere/active/libsodium/lib"
./rebar3 get-deps || exit 3

### Prepare to start
systemctl stop dcos-net.service dcos-net-watchdog.timer dcos-net-watchdog.service

### ExecStartPre
systemctl cat dcos-net | \
    sed -nre 's/ExecStartPre=-?//p' | \
    xargs -n 1 -I {} bash -c '{} | true'


### See dcos-net-env

APP_NAME=dcos-net
NODE_NAME=navstar

function valid_ip()
{
    local  ip=$1
    local  stat=1

    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        OIFS=$IFS
        IFS='.'
        ip=($ip)
        IFS=$OIFS
        [[ ${ip[0]} -le 255 && ${ip[1]} -le 255 \
            && ${ip[2]} -le 255 && ${ip[3]} -le 255 ]]
        stat=$?
    fi
    return $stat
}

function check_epmd() {
    if ! epmd -port ${ERL_EPMD_PORT} -names > /dev/null; then
        echo "EPMD is not reachable at port \"${ERL_EPMD_PORT}\"" >&2
        exit 1;
    fi
    APP_PORT=$(epmd -port ${ERL_EPMD_PORT} -names | awk "/${NODE_NAME}/{print \$5}")
    if [ "${APP_PORT}" ]; then
        read -r -d '' EVALCODE <<- EOM
            case gen_tcp:connect({127, 0, 0, 1}, ${APP_PORT}, [], 1000) of
                {ok, S} -> gen_tcp:close(S), halt(1);
                {error, Error} -> halt(0)
            end.
EOM
        if erl -boot start_clean -noinput -eval "${EVALCODE}"; then
            epmd -port ${ERL_EPMD_PORT} -stop ${NODE_NAME}
        fi
    fi
}

ENV_FILE="/opt/mesosphere/etc/${APP_NAME}.env"
if [ -f $ENV_FILE ]; then
  . $ENV_FILE
fi

## Try to ascertain the node IP based on some set of heuristics
IP=127.0.0.1
if [ -x /opt/mesosphere/bin/detect_ip ]; then
    IP=$(/opt/mesosphere/bin/detect_ip)
    if ! valid_ip $IP; then
        ## 192.88.99.0 was chosen because it's a anycast IP
        ## used for v6 tunnels
        IP=$(ip r g 192.88.99.0 | grep -Po 'src \K[\d.]+')
    fi
else
    IP=$(ip r g 192.88.99.0 | grep -Po 'src \K[\d.]+')
fi
NAME=${NODE_NAME}@${IP}

## If ERLANG_DISTRIBUTION is unset, then set it to inet_tcp
ERLANG_DISTRIBUTION=${ERLANG_DISTRIBUTION:=inet_tcp}
export ERLANG_DISTRIBUTION
CLIENT_CACERTFILE=${CLIENT_CACERTFILE:=/run/dcos/pki/CA/certs/ca.crt}
export CLIENT_CACERTFILE
CLIENT_KEYFILE=${CLIENT_KEYFILE:=/run/dcos/pki/tls/private/${APP_NAME}.key}
export CLIENT_KEYFILE
CLIENT_CERTFILE=${CLIENT_CERTFILE:=/run/dcos/pki/tls/certs/${APP_NAME}.crt}
export CLIENT_CERTFILE
CLIENT_VERIFY=${CLIENT_VERIFY:=verify_peer}
export CLIENT_VERIFY
CLIENT_DEPTH=${CLIENT_DEPTH:=10}
export CLIENT_DEPTH
SERVER_CACERTFILE=${SERVER_CACERTFILE:=/run/dcos/pki/CA/certs/ca.crt}
export SERVER_CACERTFILE
SERVER_KEYFILE=${SERVER_KEYFILE:=/run/dcos/pki/tls/private/${APP_NAME}.key}
export SERVER_KEYFILE
SERVER_CERTFILE=${SERVER_CERTFILE:=/run/dcos/pki/tls/certs/${APP_NAME}.crt}
export SERVER_CERTFILE
SERVER_VERIFY=${SERVER_VERIFY:=verify_peer}
export SERVER_VERIFY
SERVER_FAIL_IF_NO_PEER_CERT=${SERVER_FAIL_IF_NO_PEER_CERT:=true}
export SERVER_FAIL_IF_NO_PEER_CERT
SERVER_DEPTH=${SERVER_DEPTH:=10}
export SERVER_DEPTH


## By default MESOS_STATE_SSL_ENABLED is false
MESOS_STATE_SSL_ENABLED=${MESOS_STATE_SSL_ENABLED:=false}
export MESOS_STATE_SSL_ENABLED

## SSL / Distributed Erlang config
export ERL_FLAGS="${ERL_FLAGS} -proto_dist ${ERLANG_DISTRIBUTION}"
export ERL_FLAGS="${ERL_FLAGS} -ssl_dist_opt client_cacertfile ${CLIENT_CACERTFILE}"
export ERL_FLAGS="${ERL_FLAGS} -ssl_dist_opt client_keyfile ${CLIENT_KEYFILE}"
export ERL_FLAGS="${ERL_FLAGS} -ssl_dist_opt client_certfile ${CLIENT_CERTFILE}"
export ERL_FLAGS="${ERL_FLAGS} -ssl_dist_opt client_verify ${CLIENT_VERIFY}"
export ERL_FLAGS="${ERL_FLAGS} -ssl_dist_opt client_depth ${CLIENT_DEPTH}"
export ERL_FLAGS="${ERL_FLAGS} -ssl_dist_opt server_cacertfile ${SERVER_CACERTFILE}"
export ERL_FLAGS="${ERL_FLAGS} -ssl_dist_opt server_keyfile ${SERVER_KEYFILE}"
export ERL_FLAGS="${ERL_FLAGS} -ssl_dist_opt server_certfile ${SERVER_CERTFILE}"
export ERL_FLAGS="${ERL_FLAGS} -ssl_dist_opt server_verify ${SERVER_VERIFY}"
export ERL_FLAGS="${ERL_FLAGS} -ssl_dist_opt server_fail_if_no_peer_cert ${SERVER_FAIL_IF_NO_PEER_CERT}"
export ERL_FLAGS="${ERL_FLAGS} -ssl_dist_opt server_depth ${SERVER_DEPTH}"

## Mesos state config (SSL)
export ERL_FLAGS="${ERL_FLAGS} -mesos_state ssl ${MESOS_STATE_SSL_ENABLED}"

### EPMD
export ERL_EPMD_PORT=61420
check_epmd

### Run
exec ./rebar3 shell --config config/sys.config --name ${NAME} --setcookie minuteman \
    --apps mnesia,dcos_dns,dcos_l4lb,dcos_overlay,dcos_rest,dcos_net,recon
