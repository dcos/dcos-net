# Spartan

[![Circle CI](https://circleci.com/gh/dcos/spartan.svg?style=svg&circle-token=0ceb55609f1c418c58f779c4ca0310eeeab24b19)](https://circleci.com/gh/dcos/spartan)

## Background
DNS is an integral part of DCOS. Since tasks move around frequently in DCOS, and resources must be dynamically resolved, typically by some application protocol, they are referred to by name. Rather than implementing a Zookeeper, or Mesos client in every project, we've chosen DNS as the lingua franca for discovery amongst all of our components in DCOS. 

This is implemented by using Mesos DNS, which runs on each of the DCOS masters. In the client systems, we put each of the masters into the `/etc/resolv.conf`. If one of the masters goes down, DNS queries to that master will time out. This is problematic. Spartan solves this problem by dual-dispatching DNS queries to multiple masters and returning the first result.

In addition to this, in order to alleviate risk, Spartan routes queries to nodes that it believes are most optimal to do a query. Specifically, if a domain ends in `mesos`, it will only then dispatch queries to the Mesos masters. If it doesn't, it'll send it to 2 of the configured upstreams. 

# Implementation
Spartan itself is very simple. Spartan itself has the dual-dispatch logic, and also hosts a domain `spartan` which has only one record -- `ready.spartan`. The purpose of this record is to investigate the availability of Spartan. Many services (ICMP) ping this address prior to starting.

Spartan learns its information from Exhibitor. For this reason, it is critical that Exhibitor is configured correctly on the masters. Alternatively, if the cluster is configured using static masters, it will load them from the static configuration file. 

## Zookeeper
Spartan also enables high availability of Zookeepers. You can always use the addresses `zk-1.zk`, `zk-2.zk`, `zk-3.zk`, `zk-4.zk`, `zk-5.zk`. If there are fewer than 5 Zookeepers, we will point multiple records at a single Zookeeper. 

## Watchdog
Since DNS is such a specialized, sensitive subsystem we've chosen to protect it with a watchdog. There is a service installed on each node that runs every 5 minutes and checks whether or not it can query `ready.spartan`. To avoid harmonic effects, it sleeps for 1 minute past its initial start time to avoid racing spartan. 

In addition to this watchdog, we also run genresolv, which checks whether or not Spartan is alive to generate the resolv.conf. If it believe Spartan not to be alive, it then rewrites the resolv.conf with the upstream resolvers that you've configured into your DC/OS cluster. 

## Spartan Interface
Spartan creates its own network interface. This interface is actually a dummy device called `spartan`. This device hosts 3 IPs, `198.51.100.1/32`, `198.51.100.2/32`, `198.51.100.3/32`. 

## HTTP Interface

Spartan implements a simple REST API for service discovery over HTTP:

* GET /v1/version: lists the Spartan version
* GET /v1/config: lists the Spartan configuration info (not implemented)
* GET /v1/hosts/{host}: lists the IP address of a host
* GET /v1/services/{service}: lists the host, IP address, and port for a service
* GET /v1/enumerate: lists all DNS information (not implemented)
* GET /v1/records: lists all DNS records

This HTTP API is reachable at http://<host>:63053/. For more information please see Mesos-DNS [documentation](https://github.com/mesosphere/mesos-dns/blob/master/docs/docs/http.md).
