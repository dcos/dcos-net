# DC/OS Networking Run Book Automation

This is a codified version of `dcos-net` part of the networking
runbook.

## Usage

```
$ net-runbook --help
usage: net-runbook [options]

a script for troubleshooting and collecting networking diagnostics data

options:
  --no-net-toolbox     do not use mesosphere/net-toolbox Docker image
                       to capture some data, and use ipvsadm and such
                       instead if they are available on the host
  --help               print this message
```

It should be run under root. If possible the tool pulls
`mesosphere/net-toolbox` Docker image that contains certain utilities
that it uses to capture diagnostics data. If it fails to do so, it is
expected that tools like `ipvsadm` and `ipset` are avaialbe on the
host.

After executing `net-runbook.sh`, there should be a tarball named like
`net-runbook-<ip-address>.tar.gz` containing diagnostics data.

## Recommendations

What nodes to run the script on, depend on the type of networking
issue being observed. By default it is good to run it on a master, an
agent and a public agent. If there are multiple host networking
subnets, then it is advised to have it run on at least one node from
each subnet. If an issue is observed only on some nodes, the best
approach is to run the script on those nodes and also on a node where
the issue is not observed. In any case, if possible, it should be
always executed on at least one master node, because some data is
collected only on masters.
