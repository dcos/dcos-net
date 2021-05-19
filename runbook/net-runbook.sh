#!/bin/bash
# -*- mode: shell-script; sh-basic-offset: 2 -*-

set -uo pipefail

SCRIPT="$0"

if [ -z "${DCOS_VERSION+x}" ]; then
  exec /opt/mesosphere/bin/dcos-shell "$SCRIPT" "$@"
fi

usage() {
  echo "usage: $SCRIPT [options]"
  echo
  echo "a script for troubleshooting and collecting networking diagnostics data"
  echo
  echo "options:"
  echo "  --no-net-toolbox     do not use mesosphere/net-toolbox Docker image"
  echo "                       to capture some data, and use ipvsadm and such"
  echo "                       instead if they are available on the host"
  echo "  --help               print this message"
}

USE_NET_TOOLBOX="true"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-net-toolbox)
      USE_NET_TOOLBOX="false"
      shift
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      echo "error: extra arguments"
      echo
      usage
      exit 1
      ;;
  esac
done

IP="$(/opt/mesosphere/bin/detect_ip)"
DATA_DIR="net-runbook-$IP"
SERVICE_AUTH_TOKEN=$(sed 's/^SERVICE_AUTH_TOKEN=//' /run/dcos/etc/dcos-net_auth.env)

major-version() {
  echo "$DCOS_VERSION" | cut -d. -f1 | cut -d- -f1
}

minor-version() {
  echo "$DCOS_VERSION" | cut -d. -f2 | cut -d- -f1
}

MAJOR_VERSION="$(major-version)"
MINOR_VERSION="$(minor-version)"

running-on-master() {
  if systemctl status dcos-mesos-master &> /dev/null; then
    echo yes
  else
    echo no
  fi
}

RUNNING_ON_MASTER="$(running-on-master)"

if [ "$USE_NET_TOOLBOX" == "true" ]; then
  if ! docker pull mesosphere/net-toolbox; then
    USE_NET_TOOLBOX="false"
    echo "*WARNING* could not download mesosphere/net-toolbox docker image"
    echo "*WARNING* the ipvsadm command must be installed before collection"
    echo "*WARNING* will succeed."
  fi
fi

wrap-toolbox() {
  cmd=$1
  shift

  if [ "${USE_NET_TOOLBOX}" == "false" ]; then
    if type "$cmd" &> /dev/null; then
      "$cmd" "$@"
    else
      echo "$cmd is not available"
    fi
  else
    docker run \
           --rm \
           --net=host \
           --privileged \
           mesosphere/net-toolbox:latest "$cmd" "$@"
  fi
}

wrap-curl() {
  curl --insecure --silent "$@"
}

wrap-dig() {
  wrap-toolbox dig "$@"
}

wrap-ipvsadm() {
  wrap-toolbox ipvsadm "$@"
}

wrap-net-eval() {
  if [ "$MAJOR_VERSION" -lt 2 ] && [ "$MINOR_VERSION" -lt "11" ]; then
    /opt/mesosphere/active/navstar/navstar/bin/navstar-env eval "$@"
  else
    /opt/mesosphere/bin/dcos-net-env eval "$@"
  fi
}

maybe-pprint-json() {
  if hash jq 2> /dev/null; then
    jq .
  else
    cat
  fi
}

dcos-version() {
  echo "======================================================================"
  (
    echo "DC/OS $DCOS_VERSION";
    if [ -n "${DCOS_VARIANT}" ]; then
      echo "Variant: $DCOS_VARIANT";
    fi
    echo "Image commit: $DCOS_IMAGE_COMMIT"
  ) | tee "$DATA_DIR/dcos-version.txt"
  echo
}

os-data() {
  echo "======================================================================"
  echo "Capturing OS release and version..."

  for f in /etc/*-release; do
    cp "$f" "$DATA_DIR/$(basename "$f").txt"
  done
  uname -a > "$DATA_DIR/uname.txt"

  echo "Captured OS release and version."
  echo

  echo "Capturing system state..."
  systemctl -a > "$DATA_DIR/systemctl.txt"

}

docker-version() {
  echo "======================================================================"
  echo "Capturing Docker version..."

  docker version > "$DATA_DIR/docker-version.txt"

  echo "Captured Docker version."
  echo
}

logs() {
  echo "======================================================================"
  echo "Capturing logs using journald..."

  if [ "$RUNNING_ON_MASTER" == "yes" ]; then
    echo "Capturing dcos-mesos-master logs..."
    journalctl -u dcos-mesos-master.service > "$DATA_DIR/dcos-mesos-master-logs.txt"
    echo "Capturing dcos-mesos-dns logs..."
    journalctl -u dcos-mesos-dns.service > "$DATA_DIR/dcos-mesos-dns-logs.txt"
  else
    echo "Capturing dcos-mesos-slave logs..."
    journalctl -u dcos-mesos-slave.service > "$DATA_DIR/dcos-mesos-slave-logs.txt"
  fi

  if [ "$MAJOR_VERSION" -lt 2 ] && [ "$MINOR_VERSION" -lt "11" ]; then
    echo "Capturing dcos-navstar logs..."
    journalctl -u dcos-navstar.service > "$DATA_DIR/dcos-navstar-logs.txt"
    if [ -f /opt/mesosphere/active/navstar/navstar/erl_crash.dump ]; then
      echo "Capturing dcos-navstar crash dump..."
      cp /opt/mesosphere/active/navstar/navstar/erl_crash.dump \
         "$DATA_DIR/dcos-navstar-crash-dump.txt"
    fi
    echo "Capturing dcos-spartan logs..."
    journalctl -u dcos-spartan.service > "$DATA_DIR/dcos-spartan-logs.txt"
    if [ -f /opt/mesosphere/active/spartan/spartan/erl_crash.dump ]; then
      echo "Capturing dcos-navstar crash dump..."
      cp /opt/mesosphere/active/spartan/spartan/erl_crash.dump \
         "$DATA_DIR/dcos-navstar-crash-dump.txt"
    fi
  else
    echo "Capturing dcos-net logs..."
    journalctl -u dcos-net.service > "$DATA_DIR/dcos-net-logs.txt"
    if [ -f /opt/mesosphere/active/dcos-net/dcos-net/erl_crash.dump ]; then
      echo "Capturing dcos-net crash dump..."
      cp /opt/mesosphere/active/dcos-net/dcos-net/erl_crash.dump \
         "$DATA_DIR/dcos-net-crash-dump.txt"
    fi
  fi

  echo "Capturing dcos-gen-resolvconf logs..."
  journalctl -u dcos-gen-resolvconf.service > "$DATA_DIR/dcos-gen-resolvconf-logs.txt"

  echo "Capturing kernel logs..."
  journalctl -k > "$DATA_DIR/kernel-logs.txt"
  dmesg -T > "$DATA_DIR/kernel-dmesg.txt"

  echo "Captured logs using journald."
  echo
}

dcos-configs() {
  echo "======================================================================"
  echo "Capturing DC/OS configuration files..."

  echo "Capturing DC/OS user config..."
  cp /opt/mesosphere/etc/user.config.yaml "$DATA_DIR/dcos-user.config.yaml"

  echo "Captured DC/OS configuration files."
  echo
}

mesos-master-state() {
  ADDR="master.mesos"
  if [ "$RUNNING_ON_MASTER" == "yes" ]; then
    ADDR="$IP"
  fi
  wrap-curl "https://$ADDR:5050/state" | maybe-pprint-json
}

mesos-agent-state() {
  if [ "$MAJOR_VERSION" -lt 2 ] && [ "$MINOR_VERSION" -lt "11" ]; then
    wrap-net-eval 'mesos_state_client:poll(mesos_state:ip(), 5051).'
  elif [ "$MAJOR_VERSION" -lt 2 ] && [ "$MINOR_VERSION" -lt "12" ]; then
    wrap-net-eval 'false = dcos_dns:is_master(), dcos_net_mesos:poll("/state").'
  else
    wrap-curl \
      -H 'Content-Type: application/json' \
      -H "Authorization: token=$SERVICE_AUTH_TOKEN" \
      -d '{"type": "GET_STATE"}' \
      "https://$IP:5051/api/v1" | maybe-pprint-json
  fi
}

mesos-state() {
  echo "======================================================================"
  echo "Capturing the Mesos state..."

  echo "Capturing the Mesos master state..."
  mesos-master-state > "$DATA_DIR/mesos-master-state.json"

  if [ "$RUNNING_ON_MASTER" == "no" ]; then
    echo "Capturing the Mesos agent state..."
    mesos-agent-state > "$DATA_DIR/mesos-agent-state.json"
  fi

  echo "Captured the Mesos state."
  echo
}

sockets() {
  echo "======================================================================"
  echo "Capturing listening and non-listening sockets..."

  # Check the ports that dcos-net (and others) are listening on, make sure that
  # dcos-net is listening on 53 for spartan
  netstat -nap > "$DATA_DIR/netstat.txt"

  echo "Captured listening and non-listening sockets."
  echo
}

l4lb-data() {
  echo "======================================================================"
  echo "Capturing L4LB data..."

  echo "Capturing VIPs..."
  # The list of VIPs that dcos-net knows about and should be configured
  wrap-curl 'http://localhost:62080/v1/vips' \
    | maybe-pprint-json > "$DATA_DIR/l4lb-vips.json"

  echo "Capturing IPVS state..."
  # The actual configuration that ipvs has, this will show the backends and
  # their weight
  wrap-ipvsadm -L -n > "$DATA_DIR/ipvsadm.txt"
  cp /proc/net/ip_vs "$DATA_DIR/ip-vs.txt"
  if hash perl 2>/dev/null; then
    perl -lpe \
         's/([0-9A-F]{2})([0-9A-F]{2})([0-9A-F]{2})([0-9A-F]{2}):([0-9A-F]{4})/hex($1).".".hex($2).".".hex($3).".".hex($4).":".hex($5)/eg' \
         "$DATA_DIR/ip-vs.txt" > "$DATA_DIR/ip-vs-readable.txt"
  fi

  echo "Capturing IPVS timeouts..."
  # The TCP timeouts for TCP sessions
  wrap-ipvsadm -L --timeout > "$DATA_DIR/ipvsadm-timeout.txt"

  echo "Capturing IPVS connection state..."
  # The state of each connection / finding out how VIP traffic is getting forwarded
  # Protocol / Src IP / Src Port/ Target IP (VIP) / Target Port / Dst IP, Dst Port
  cp /proc/net/ip_vs_conn "$DATA_DIR/ip-vs-conn.txt"
  if hash perl 2>/dev/null; then
    perl -lpe \
         's/([0-9A-F]{2})([0-9A-F]{2})([0-9A-F]{2})([0-9A-F]{2})/hex($1).".".hex($2).".".hex($3).".".hex($4)/eg;s/([0-9A-F]{4})/hex($1)/eg' \
         "$DATA_DIR/ip-vs-conn.txt" > "$DATA_DIR/ip-vs-conn-readable.txt"
  fi

  echo "Capturing kernel state..."
  # Things to check:
  # ip forwarding is on globally and for each interface
  sysctl -a > "$DATA_DIR/sysctl.txt"

  echo "Capturing iptables configuration..."
  # Mkae sure that the PREROUTING and OUTPUT chains have the match for L4LB traffic
  iptables-save > "$DATA_DIR/iptables-save.txt"
  ip6tables-save > "$DATA_DIR/ip6tables-save.txt"

  echo "Capturing ipset configuration..."
  # Make sure that the dcos-l4lb set has the vips in it that are expected
  ipset list > "$DATA_DIR/ipset.txt"

  echo "Capturing netfilter conntrack table..."
  # Contrack should have an entry for each connection
  cp /proc/net/nf_conntrack "$DATA_DIR/nf-conntrack.txt"

  echo "Capturing minuteman routing table..."
  # Every vip should have a local entry
  ip route show table local dev minuteman scope host > "$DATA_DIR/minuteman-routes.txt"

  echo "Capturing lashup membership..."
  # The lashup view from this node, every node should have a similar view.
  # the active_view is the list of nodes that the node is peer'd with
  # each node will only peer with a few other nodes, but a complete mesh is formed
  wrap-net-eval 'lashup_gm:gm().' > "$DATA_DIR/lashup-membership.txt"

  echo "Captured L4LB data"
  echo
}

overlay-data() {
  echo "======================================================================"
  echo "Capturing overlay data..."

  echo "Capturing network configuration..."

  # Every container will have a forwarding entry forcing the mac over the vtep
  bridge fdb > "$DATA_DIR/bridge-fdb.txt"
  ifconfig -a > "$DATA_DIR/ifconfig.txt"
  ip addr > "$DATA_DIR/ip-addr.txt"
  ip link > "$DATA_DIR/ip-link.txt"
  ip neigh > "$DATA_DIR/ip-neigh.txt"
  ip ntable > "$DATA_DIR/ip-ntable.txt"
  # Every overlay /24 will have a route to its host on the vtep
  ip route > "$DATA_DIR/ip-route.txt"
  # Every container participating in the overlay will have a route entry
  ip route show table 42 > "$DATA_DIR/ip-route-42.txt" 2>&1
  # If overlay is enabled, there should be a rule from 9.0.0.0/8 lookup 42
  ip rule > "$DATA_DIR/ip-rule.txt"

  echo "Capturing lashup overlay state..."
  # shows the subnet, mac address, overlay address, and host address of every agent
  wrap-net-eval \
    '[{Key, lashup_kv:value(Key)} || Key = [navstar, overlay, _Subnet] <- mnesia:dirty_all_keys(kv2)].' \
    > "$DATA_DIR/lashup-overlays.txt"
  # Nclock values are carried along with updates. If a node has replicated
  # data to another node and suddenly the nclock value "jumps", the node
  # is shunned and no updates are commited.
  # This shows the value of the latest value from each peer and itself, the
  # value for itself *should* be similar the the value reported on other nodes
  # for it.
  # That is if this host is 10.1.1.1 and has the value 2000, then other hosts
  # should also have a similar (although not exact) value for 10.1.1.1.
  # Commonly a node will get out of sync during an upgrade and will fail to join
  # back up to the other nodes. Wiping the nclock values cluster wide will reset
  # them:
  # /opt/mesosphere/bin/dcos-net-env eval 'lists:foreach(fun (K) -> mnesia:dirty_delete(nclock, K) end, mnesia:dirty_all_keys(nclock)).'
  wrap-net-eval \
      'mnesia:dirty_select(nclock, ets:fun2ms(fun(A) -> A end)).' \
      > "$DATA_DIR/lashup-nclock.txt"

  echo "Capturing Mesos overlay information..."
  # Shows the configuration of the overlay for this node, and if it was
  # successfully setup
  if [ "$RUNNING_ON_MASTER" == "yes" ];then
    wrap-curl \
      "https://$IP:5050/overlay-master/state" > "$DATA_DIR/overlay-master-state.json" \
      | maybe-pprint-json
  else
    wrap-curl \
      "https://$IP:5051/overlay-agent/overlay" > "$DATA_DIR/overlay-agent-state.json" \
      | maybe-pprint-json
  fi

  echo "Captured overlay data"
  echo
}

docker-networks() {
  echo "======================================================================"
  echo "Capturing Docker networks..."

  docker network ls > "$DATA_DIR/docker-networks.txt"

  for n in $(docker network ls -q); do
    docker network inspect "$n" > "$DATA_DIR/docker-network-$n.json"
  done

  echo "Captured Docker networks."
  echo
}

dns-data() {
  echo "======================================================================"
  echo "Capturing DNS data..."

  echo "Copying resolv.conf ..."
  # The resolv.conf should have three entries for spartan in it:
  # nameserver 198.51.100.1
  # nameserver 198.51.100.2
  # nameserver 198.51.100.3
  # Common issues are when another process such as puppet replaces
  # /etc/resolv.conf with other values causes sporadic resolution failures
  # inside containers.
  cat /etc/resolv.conf > "$DATA_DIR/resolv.conf"

  # This just verifies that spartain is resolving, errors here usually mean
  # dcos-net can't reach the leader or mesos stream
  echo "Resovling ready.spartan ..."
  wrap-dig ready.spartan > "$DATA_DIR/dig-ready.spartan.txt"
  echo "Resovling ready.spartan through 198.51.100.1 ..."
  wrap-dig ready.spartan @198.51.100.1 > "$DATA_DIR/dig-ready.spartan-at-198.51.100.1.txt"
  echo "Resovling leader.mesos through 198.51.100.1 ..."
  wrap-dig leader.mesos @198.51.100.1 > "$DATA_DIR/dig-leader.mesos-at-198.51.100.1.txt"
  echo "Resovling dcos.io through 198.51.100.1 ..."
  wrap-dig dcos.io @198.51.100.1 > "$DATA_DIR/dig-dcos.io-at-198.51.100.1.txt"

  # checking the latenency directly to the upstream servers, resolution
  # time should be the same as the above, if it varies, then spartan is lagging
  echo "Resolving dcos.io through upstream servers..."
  (
    # shellcheck disable=SC1091
    source /opt/mesosphere/etc/dns_config;
    for server in $(echo "$RESOLVERS" | tr ',' '\n'); do
      echo "===    Upstream DNS server: $server ===";
      wrap-dig dcos.io @"$server";
    done
  ) > "$DATA_DIR/dig-dcos.io-at-upstream-servers.txt"

  echo "Copying Mesos DNS configuration..."
  maybe-pprint-json < /opt/mesosphere/etc/mesos-dns.json > "$DATA_DIR/mesos-dns-config.json"
  echo "Fetching Mesos DNS records..."
  if [ "$RUNNING_ON_MASTER" == "yes" ]; then
    wrap-curl http://localhost:8123/v1/enumerate \
      | maybe-pprint-json > "$DATA_DIR/mesos-dns-records.json"
  fi

  echo "Fetching dcos-dns records..."
  wrap-curl http://localhost:62080/v1/records \
    | maybe-pprint-json > "$DATA_DIR/dcos-dns-records.json"

  echo "Captured DNS data"
  echo
}

# dig <yourapp>.<yourframework>.mesos @127.0.0.1 -p 61053

main() {
  mkdir "$DATA_DIR"

  dcos-version
  os-data
  docker-version
  logs
  dcos-configs
  sockets
  mesos-state
  l4lb-data
  overlay-data
  docker-networks
  dns-data

  chmod 644 "$DATA_DIR"/*
  tar czf "$DATA_DIR.tar.gz" "$DATA_DIR"
  rm -Rf "$DATA_DIR"
}

main
