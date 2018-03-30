#!/bin/sh

set -e

DCOS_NET_DIR="$(dirname $(dirname $0))"
DCOS_NET_DIR="$(cd $DCOS_NET_DIR; pwd)"
DCOS_NET_IMAGE_REV=$(git log -n 1 --pretty=format:%h -- Dockerfile)
DCOS_NET_IMAGE="dcos-net-dev:$DCOS_NET_IMAGE_REV"

if [ -z "$(docker image ls -q $DCOS_NET_IMAGE)" ]; then
    echo "Building docker image..." >&2
    docker build -t ${DCOS_NET_IMAGE} ${DCOS_NET_DIR}
fi

mkdir -p ${DCOS_NET_DIR}/_build
docker run --rm -it --privileged \
    -v ${DCOS_NET_DIR}:/dcos-net \
    -v ${DCOS_NET_DIR}/_build:/root \
    -w /dcos-net \
    ${DCOS_NET_IMAGE} \
    "$@"
