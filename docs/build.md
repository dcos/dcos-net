# Building from the ground up

Going forward, it will be assumed that there are two machines available,
`node-1` and `node-2` respectively. They can be physical machines, virtual
machines, or even Docker containers. Let's assume that their IPv4 addressed are:

```sh
NODE_1_IP=192.168.0.1
NODE_2_IP=192.168.0.2
```

## Compiling Erlang

Firstly, the dependencies should be installed. Most of them can be installed
using the package manager of your Linux distribution. In case Erlang 22.x is not
available through it, please build one using [kerl](https://github.com/kerl/kerl):

```sh
KERL_CONFIGURE_OPTIONS=
KERL_CONFIGURE_OPTIONS+="--enable-dirty-schedulers "
KERL_CONFIGURE_OPTIONS+="--enable-kernel-poll "
KERL_CONFIGURE_OPTIONS+="--with-ssl"
KERL_CONFIGURE_OPTIONS+="--without-javac "
export KERL_CONFIGURE_OPTIONS

kerl build 22.0 22.0
kerl install 22.0 $HOME/erl
```

Once it is done, you may execute the following command to activate it:

```sh
source $HOME/erl/activate
```

## Compiling Mesos

Next step is to build Mesos itself. Firstly, please install its dependencies
that are mentioned in its
[docs](http://mesos.apache.org/documentation/latest/building/). Once they are
installed, it is really easy to compile Mesos using
[Mesos Version Manager](https://github.com/mesosphere/marathon/blob/master/tools/mvm.sh).
In order to install it, run:

```sh
curl -LO https://raw.githubusercontent.com/mesosphere/marathon/master/tools/mvm.sh
chmod +x mvm.sh
```

And build Mesos using it:

```sh
mvm.sh 1.7.0
exit
```

And then activate it too by running:

```sh
eval `mvm.sh --print-config`
```

After that, DC/OS Mesos module should be compiled:

```sh
cd dcos-mesos-modules
./bootstrap
mkdir build && cd build
../configure --prefix=/usr \
             --with-mesos=$HOME/.mesos/current \
             --with-protobuf=$HOME/.mesos/current/lib/mesos/3rdparty
```

If `libsodium` 1.0.12+ is not available in your Linux distro, fetch a tarball
from its official website, unpack it, and build it as follows:

```sh
cd libsodium-*
mkdir build && cd build
../configure --prefix=/usr
make
make install
```

All of the above steps should be performed on both machines.

## Starting up dependencies

### Starting up Exhibitor and Zookeeper

Now we are ready to start up the components. First, start Exhibitor with
ZooKeeper on `node-1`. Please refer to
[Running Exhibitor](https://github.com/soabase/exhibitor/wiki/Running-Exhibitor)
for instructions on how to run it. Alternatively, it can easily be started using
Docker:

```sh
docker run --rm -it \
     --name exhibitor \
     --net bridge \
     -p 2181:2181/tcp \
     -p 2888:2888/tcp \
     -p 3888:3888/tcp \
     -p 8181:8080/tcp \
     netflixoss/exhibitor:1.5.2 \
     --hostname $NODE_1_IP
```

### Starting up Mesos master

To start Mesos master on `node-1`, execute:

```sh
mesos-master \
     --cluster=dcos-net-cluster \
     --hostname=$NODE_1_IP \
     --ip=0.0.0.0 \
     --log_dir=/var/log/mesos \
     --port=5050 \
     --quorum=1 \
     --zk=zk://$NODE_1_IP:2181/mesos \
     --work_dir=/var/lib/mesos/master \
     --modules=file:///etc/mesos/master-modules.json
```

where the content of `/etc/mesos/master-modules.json` is:

```json
{
    "libraries": [{
        "file": "/usr/lib/mesos/libmesos_network_overlay.so",
        "modules": [{
            "name": "com_mesosphere_mesos_OverlayMasterManager",
            "parameters": [{
                "key": "master_config",
                "value": "/etc/mesos/overlay/master-config.json"
            }, {
                "key": "agent_config",
                "value": "/etc/mesos/overlay/master-agent-config.json"
            }]
        }]
    }]
}
```

And the content of `/etc/mesos/overlay/master-config.json` is:

```json
{
    "replicated_log_dir":"/var/lib/mesos/master",
    "network": {
        "vtep_mac_oui": "70:B3:D5:00:00:00",
        "overlays": [{
            "prefix": 24,
            "name": "dcos",
            "subnet": "9.0.0.0/8"
        }],
        "vtep_subnet": "44.128.0.0/20"
    }
}
```

And the content of `/etc/mesos/overlay/master-agent-config.json` is:

```json
{
    "cni_dir": "/etc/mesos/cni",
    "cni_data_dir": "/var/run/mesos/cni/networks",
    "network_config" : {
        "allocate_subnet": true,
        "mesos_bridge": false,
        "docker_bridge": false,
        "overlay_mtu": 1420,
        "enable_ipv6": false
    },
    "max_configuration_attempts": 5
}
```

### Starting up Mesos agent

Now let's start Mesos agent on `node-2`:

```sh
mesos-agent \
    --containerizers=mesos \
    --hostname=$NODE_2_IP \
    --image_providers=docker \
    --ip=0.0.0.0 \
    --isolation=docker/runtime,filesystem/linux,volume/sandbox_path \
    --log_dir=/var/log/mesos \
    --master=zk://$NODE_1_IP:2181/mesos \
    --port=5051 \
    --work_dir=/var/lib/mesos/agent \
    --no-systemd_enable_support \
    --modules=file:///etc/mesos/agent-modules.json
```

where the content of `/etc/mesos/agent-modules.json` is:

```json
{
    "libraries": [{
        "file": "/usr/lib/mesos/libmesos_network_overlay.so",
        "modules": [{
            "name": "com_mesosphere_mesos_OverlayAgentManager",
            "parameters": [{
                "key": "agent_config",
                "value": "/etc/mesos/overlay/agent-config.json"
            }]
        }]
    }]
}
```

And the content of `/etc/mesos/overlay/agent-config.json` is:

```json
{
    "master": "$NODE_1_IP:5050",
    "cni_dir":"/etc/mesos/cni",
    "cni_data_dir": "/var/run/mesos/cni/networks",
    "network_config": {
        "allocate_subnet": true,
        "mesos_bridge": true,
        "docker_bridge": false,
        "overlay_mtu": 1420,
        "enable_ipv6": false
    },
    "max_configuration_attempts": 5
}
```

### Starting up Mesos-DNS

`dcos-net` depends on Mesos-DNS, so let's tilt it up too. First, build it
following the following [instructions](https://github.com/mesosphere/mesos-dns),
and then run on `node-1`:

```sh
mesos-dns -config /etc/mesos-dns.json
```

where the content of `/etc/mesos-dns.json` is:

```json
{
    "zk": "zk://$NODE_1_IP:2181/mesos",
    "refreshSeconds": 30,
    "ttl": 60,
    "domain": "mesos",
    "port": 61053,
    "resolvers": ["8.8.8.8"],
    "timeout": 5,
    "listener": "0.0.0.0",
    "email": "root.mesos-dns.mesos",
    "IPSources": ["host", "netinfo"],
    "SetTruncateBit": true
}
```

## Configuring networking

`dcos-net` expects some network interfaces to be up and configured. Let's do
this on both nodes:

```sh
modprobe ip_vs_wlc
modprobe dummy

iptables --wait -A FORWARD -j ACCEPT
iptables --wait -t nat -I POSTROUTING -m ipvs --ipvs --vdir ORIGINAL \
         --vmethod MASQ -m comment \
         --comment Minuteman-IPVS-IPTables-masquerade-rule \
         -j MASQUERADE
ip link add minuteman type dummy
ip link set minuteman up
ip link add spartan type dummy
ip link set spartan up
ip addr add 198.51.100.1/32 dev spartan
ip addr add 198.51.100.2/32 dev spartan
ip addr add 198.51.100.3/32 dev spartan
```

And then add the following entries to `/etc/resolv.conf`:

```conf
nameserver 198.51.100.1
nameserver 198.51.100.2
nameserver 198.51.100.3
```


## Compiling and starting up dcos-net

Now that all the `dcos-net` dependencies are up and running, we can proceed to
launching `dcos-net` itself. First, execute the following on `node-1`:

```sh
cd dcos-net
export MASTER_SOURCE=exhibitor
export EXHIBITOR_ADDRESS=$NODE_1_IP
./rebar3 shell
        --config /etc/dcos-net/master.config \
        --name dcos-net@$NODE_1_IP \
        --setcookie dcos-net \
        --apps mnesia,recon,dcos_dns,dcos_l4lb,dcos_overlay,dcos_rest,dcos_net"
```

where the content of `/etc/dcos-net/master.config` is:

```erlang
[{lashup,
  [{work_dir, "/var/lib/dcos-net/lashup"}]},

 {mnesia,
  [{dir, "/var/lib/dcos-net/mnesia"}]},

{dcos_net,
  [{dist_port, 62501},
   {is_master, true}]},

 {dcos_dns,
  [{udp_port, 53},
   {tcp_port, 53},
   {zookeeper_servers, [{"$NODE_1_IP", 2181}]},
   {upstream_resolvers,
    [{{8,8,8,8}, 53}]},
   {zones,
    #{"component.thisdcos.directory" =>
          [#{
             type => cname,
             name => "registry",
             value => "master.dcos.thisdcos.directory"
            }]}}]},

 {dcos_l4lb,
  [{master_uri, "http://$NODE_1_IP:5050/master/state"},
   {enable_lb, true},
   {enable_ipv6, false},
   {min_named_ip, {11,0,0,0}},
   {max_named_ip, {11,255,255,255}},
   {min_named_ip6, {16#fd01,16#c,16#0,16#0,16#0,16#0,16#0,16#0}},
   {max_named_ip6, {16#fd01,16#c,16#0,16#0,16#ffff,16#ffff,16#ffff,16#ffff}},
   {agent_polling_enabled, false}]},

 {dcos_overlay,
  [{enable_overlay, true},
   {enable_ipv6, false}]},

 {dcos_rest,
  [{enable_rest, true},
   {ip, {0,0,0,0}},
   {port, 62080}]},

 {erldns,
  [{servers, []},
   {pools, []}]},

 {telemetry,
  [{forward_metrics, false}]}
].
```

And on `node-2`:

```sh
cd dcos-net
export MASTER_SOURCE=exhibitor
export EXHIBITOR_ADDRESS=$NODE_1_IP
./rebar3 shell
        --config /etc/dcos-net/agent.config \
        --name dcos-net@$NODE_2_IP \
        --setcookie dcos-net \
        --apps mnesia,recon,dcos_dns,dcos_l4lb,dcos_overlay,dcos_rest,dcos_net"
```

where the content of `/etc/dcos-net/agent.config` is:

```erlang
[{lashup,
  [{work_dir, "/var/lib/lashup"},
   {contact_nodes, ['dcos-net@$NODE_1_IP']}]},

 {mnesia,
  [{dir, "/var/lib/mnesia"}]},

 {dcos_net,
  [{dist_port, 62501},
   {is_master, false}]},

 {dcos_dns,
  [{udp_port, 53},
   {tcp_port, 53},
   {mesos_resolvers, []},
   {zookeeper_servers, [{"$NODE_1_IP", 2181}]},
   {upstream_resolvers,
    [{{8,8,8,8}, 53}]}]},

 {dcos_l4lb,
  [{master_uri, "http://$NODE_1_IP:5050/master/state"},
   {enable_networking, true},
   {enable_lb, true},
   {enable_ipv6, false},
   {min_named_ip, {11,0,0,0}},
   {max_named_ip, {11,255,255,255}},
   {min_named_ip6, {16#fd01,16#c,16#0,16#0,16#0,16#0,16#0,16#0}},
   {max_named_ip6, {16#fd01,16#c,16#0,16#0,16#ffff,16#ffff,16#ffff,16#ffff}},
   {agent_polling_enabled, true}]},

 {dcos_overlay,
  [{enable_overlay, true},
   {enable_ipv6, false}]},

 {dcos_rest,
  [{enable_rest, true},
   {ip, {0,0,0,0}},
   {port, 62080}]},

 {erldns,
  [{servers, []},
   {pools, []}]}
].
```
