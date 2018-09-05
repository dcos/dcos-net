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

## Development

You can build, check, and test dcos-net in development image using
`make docker-compile`, `make docker-check`, and `make docker-test` respectively.
All makefile targets with `docker-` prefix will build development image with all
dependencies and run rebar3 commands in that image on the host directory.

To check your dcos-net build on DC/OS you can use DC/OS E2E a.k.a.
[dcos-docker CLI](http://dcos-e2e.readthedocs.io/en/latest/cli.html):

```
$ curl -O https://downloads.dcos.io/dcos/testing/master/dcos_generate_config.sh
$ make dcos-docker-create DCOS_DOCKER_AGENTS=3
$ make dcos-docker-dev DCOS_DOCKER_NODE=master_0
$ make dcos-docker-shell DCOS_DOCKER_NODE=agent_1
$ make dcos-docker-destroy
```

### Dependencies

* Erlang/OTP 21.x

* C compiler

* GNU make

* [libsodium](https://libsodium.org/) 1.0.12+

To run common tests you can run `make test` on any linux-based system with the
following list of additional dependencies:

* dig (dnsutils or bind-utils)

* iproute2

* ipvsadm

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
