[![CircleCI][circleci badge]][circleci]
[![Coverage][coverage badge]][covercov]
[![Jira][jira badge]][jira]
[![License][license badge]][license]
[![Erlang Versions][erlang version badge]][erlang]

# dcos-net

DC/OS Net (or dcos-net) is a networking layer of The Datacenter Operating System
(or [DC/OS](http://dcos.io/)).

## Features

dcos-net is responsible for the following:

* Distributed CRDT [store](https://github.com/dcos/lashup) with multicast and
  failure detector capabilities

* DNS [resolver](https://github.com/aetrion/erl-dns) and [forwarder](docs/dcos_dns.md)

* Orchestration of virtual overlay networks using
  [VXLAN](https://tools.ietf.org/html/rfc7348)

* Distributed [Layer 4](http://www.linuxvirtualserver.org/software/ipvs.html)
  virtual IP load balancing

* Network metrics ([Enterprise DC/OS](https://mesosphere.com/product/) only)

For more information please see DC/OS [documentation](https://dcos.io/docs/latest/networking/).

## Dependencies

* Erlang/OTP 21.x
* C compiler
* GNU make
* [libsodium](https://libsodium.org/) 1.0.12+

To run common tests you can run `make test` on any Linux-based system with the
following list of additional dependencies:

* dig (dnsutils or bind-utils)
* iproute2
* ipvsadm

To run `dcos-net`, Exhibitor, Apache ZooKeeper, Apache Mesos, and Mesos-DNS are
required too.

## Development

You can build, check, and test dcos-net in a development image using
`make docker-compile`, `make docker-check`, and `make docker-test` respectively.
All makefile targets with `docker-` prefix build development image with all
dependencies and run `rebar3` in that image on the host directory.

To check your dcos-net build on DC/OS you can use [minidcos](https://dcos-e2e-cli.readthedocs.io/en/latest/). In order to do so please repeat the following steps:

1. Download a DC/OS build:

   ```sh
   curl -O https://downloads.dcos.io/dcos/testing/master/dcos_generate_config.sh
   ```

1. Create a DC/OS cluster with 3 agent nodes (the minimum for development would
   be 1 node):

   ```sh
   make dcos-docker-create DCOS_DOCKER_AGENTS=3
   ```

1. Build and run `dcos-net` off you local repository on a particular node, in
   this case it is `master_0`:

   ```sh
   make dcos-docker-dev DCOS_DOCKER_NODE=master_0
   ```

1. Open `dcos-shell` on a node (`agent_0`, `agent_1`, `...` `agent_n`):

   ```sh
   make dcos-docker-shell DCOS_DOCKER_NODE=agent_1
   ```

1. Destroy the cluster:

   ```sh
   make dcos-docker-destroy
   ```

Alternatively, you may build and run all the components yourself. Please refer
to the [instructions](docs/build.md) on how to build, configure, and run
`dcos-net` locally.

<!-- Badges -->
[circleci badge]: https://img.shields.io/circleci/project/github/dcos/dcos-net/master.svg?style=flat-square
[coverage badge]: https://img.shields.io/codecov/c/github/dcos/dcos-net/master.svg?style=flat-square
[jira badge]: https://img.shields.io/badge/issues-jira-yellow.svg?style=flat-square
[license badge]: https://img.shields.io/github/license/dcos/dcos-net.svg?style=flat-square
[erlang version badge]: https://img.shields.io/badge/erlang-21.x-blue.svg?style=flat-square

<!-- Links -->
[circleci]: https://circleci.com/gh/dcos/dcos-net
[covercov]: https://codecov.io/gh/dcos/dcos-net
[jira]: https://jira.dcos.io/issues/?jql=component+%3D+networking+AND+project+%3D+DCOS_OSS
[license]: ./LICENSE
[erlang]: http://erlang.org/
