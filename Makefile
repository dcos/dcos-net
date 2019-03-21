PACKAGE         ?= dcos-net
VERSION         ?= $(shell git describe --tags)
BASE_DIR         = $(shell pwd)
ERLANG_BIN       = $(shell dirname $(shell which erl))
REBAR            = $(shell pwd)/rebar3

.PHONY: rel deps test

all: compile

##
## Compilation targets
##

compile:
	$(REBAR) compile

clean:
	$(REBAR) clean

##
## Test targets
##

check: test xref dialyzer lint cover edoc

test: ct eunit

lint:
	${REBAR} as lint lint

xref:
	${REBAR} as test xref

dialyzer:
	${REBAR} dialyzer

eunit:
	${REBAR} as test eunit

ct:
	${REBAR} as test ct -v

cover:
	${REBAR} as test cover

edoc:
	${REBAR} edoc

##
## Release targets
##

rel:
	${REBAR} as prod release

stage:
	${REBAR} release -d

##
## Docker
##

DOCKER_IMAGE_REV = $(shell git log -n 1 --pretty=format:%h -- ${BASE_DIR}/Dockerfile)
DOCKER_IMAGE     = "${PACKAGE}:${DOCKER_IMAGE_REV}"
BUILD_DIR        = "${BASE_DIR}/_build"

docker-image:
	@if [ -z "$(shell docker image ls -q ${DOCKER_IMAGE})" ]; then \
	    echo "Building docker image..." >&2; \
	    docker build -t ${DOCKER_IMAGE} ${BASE_DIR}; \
	fi

docker-%: docker-image
	@mkdir -p ${BUILD_DIR}
	@docker run --rm -it --privileged \
	    -v ${BASE_DIR}:/${PACKAGE} \
	    -v ${BUILD_DIR}:/root \
	    -w /${PACKAGE} \
	    ${DOCKER_IMAGE} \
	    make $(subst docker-,,$@)

docker: docker-image
	@mkdir -p ${BUILD_DIR}
	@docker run --rm -it --privileged \
	    -v ${BASE_DIR}:/${PACKAGE} \
	    -v ${BUILD_DIR}:/root \
	    -w /${PACKAGE} \
	    ${DOCKER_IMAGE}

##
## Dev
##

dev-install:
	@ which gcc g++ make dig ip ipvsadm > /dev/null 2> /dev/null || \
	  sudo yum install -y make gcc gcc-c++ bind-utils iproute2 ipvsadm

dev-stop:
	@ systemctl stop dcos-net.service && \
	  ( echo "options timeout:1" && \
	    echo "options attempts:3" && \
	    echo $(shell source /opt/mesosphere/etc/dns_config && \
	                 echo $${RESOLVERS} | \
	                 sed -e 's/\(^\|[,]\)/\nnameserver /g') \
	  ) > /etc/resolv.conf

dev-start:
	@ systemctl start dcos-net.service

dev-shell:
	@ CFLAGS="-I/opt/mesosphere/include -I/opt/mesosphere/active/libsodium/include" \
	  LDFLAGS="-L/opt/mesosphere/lib -L/opt/mesosphere/active/libsodium/lib -Wl,-rpath=/opt/mesosphere/active/libsodium/lib" \
	  $(REBAR) shell --config config/sys.config --name ${NAME} --setcookie minuteman \
	    --apps mnesia,dcos_dns,dcos_l4lb,dcos_overlay,dcos_rest,dcos_net,recon

console: dev-shell

dev: dev-install dev-stop
	@ export ENABLE_CHECK_TIME=false && \
	  export $(shell \
	        systemctl cat dcos-net \
	      | sed -ne 's/EnvironmentFile=-*//p' \
	      | while read f; do [ -f $$f ] && echo $$f; done \
	      | xargs grep -h '[^=]*=') && \
	  systemctl cat dcos-net | sed -ne 's/ExecStartPre=//p' | tr '\n' '\0' | \
	    xargs -0 -n 1 /opt/mesosphere/bin/dcos-shell bash -c
	@ DCOS_NET_ENV_CMD="make" \
	  DCOS_NET_EBIN="$(BUILD_DIR)/default/lib/dcos_net/ebin" \
	  /opt/mesosphere/bin/dcos-net-env console

##
## miniDC/OS
##

MINIDCOS_TRANSPORT ?= docker-exec
MINIDCOS_CUSTOM_VOLUME ?= "$(BASE_DIR):$(BASE_DIR):rw"
MINIDCOS_CLUSTER_ID ?= default
MINIDCOS_MASTERS ?= 1
MINIDCOS_AGENTS ?= 1
MINIDCOS_PUBLIC_AGENTS ?= 0
MINIDCOS_NODE ?= master_0
MINIDCOS_WEB_PORT ?= 443
MINIDCOS_INTALLER ?= dcos_generate_config.sh

minidcos-create:
	@ minidcos docker inspect \
	      --cluster-id $(MINIDCOS_CLUSTER_ID) \
	      > /dev/null 2> /dev/null || \
	( minidcos docker create $(MINIDCOS_INTALLER) \
	      --transport $(MINIDCOS_TRANSPORT) \
	      --masters $(MINIDCOS_MASTERS) \
	      --agents $(MINIDCOS_AGENTS) \
	      --public-agents $(MINIDCOS_PUBLIC_AGENTS) \
	      --cluster-id $(MINIDCOS_CLUSTER_ID) \
	      --custom-volume $(MINIDCOS_CUSTOM_VOLUME) \
	      $(MINIDCOS_OPTS) && \
	  minidcos docker wait \
	      --transport $(MINIDCOS_TRANSPORT) \
	      --cluster-id $(MINIDCOS_CLUSTER_ID) \
	      --skip-http-checks )

minidcos-destroy:
	@ docker ps \
	    --filter label=dcos_e2e.cluster_id=$(MINIDCOS_CLUSTER_ID) \
	    --filter label=dcos_e2e.web_port \
	    --format '{{.ID}}' \
	| while read id; do [ -z "$$id" ] || docker kill $$id; done > /dev/null
	@ minidcos docker destroy --cluster-id $(MINIDCOS_CLUSTER_ID)

minidcos-web: minidcos-create
	@ docker ps \
	    --filter label=dcos_e2e.cluster_id=$(MINIDCOS_CLUSTER_ID) \
	    --filter label=dcos_e2e.web_port=$(MINIDCOS_WEB_PORT) \
	    --format '{{.ID}}' \
	| while read id; do [ -z "$$id" ] || docker kill $$id; done > /dev/null
	@ docker run \
	    --rm --detach \
	    --publish $(MINIDCOS_WEB_PORT):$(MINIDCOS_WEB_PORT) \
	    --name $(shell minidcos docker inspect --cluster-id $(MINIDCOS_CLUSTER_ID) | \
	                   jq -r .Nodes.masters[0].docker_container_name | \
	                   sed -e 's/-master-0/-web-$(MINIDCOS_WEB_PORT)/') \
	    --label dcos_e2e.cluster_id=$(MINIDCOS_CLUSTER_ID) \
	    --label dcos_e2e.web_port=$(MINIDCOS_WEB_PORT) \
	    alpine/socat TCP4-LISTEN:$(MINIDCOS_WEB_PORT),bind=0.0.0.0,reuseaddr,fork,su=nobody \
	                 TCP4:$(shell minidcos docker inspect --cluster-id $(MINIDCOS_CLUSTER_ID) | \
	                              jq '.Nodes | .[] | .[]' | \
	                              jq 'select (.e2e_reference == "$(MINIDCOS_NODE)")' | \
	                              jq -r .ip_address \
	                       ):$(MINIDCOS_WEB_PORT),bind=0.0.0.0 \
	    > /dev/null
	open https://localhost:$(MINIDCOS_WEB_PORT)/

minidcos-shell: minidcos-create
	@ minidcos docker run \
	    --transport $(MINIDCOS_TRANSPORT) \
	    --cluster-id $(MINIDCOS_CLUSTER_ID) \
	    --node $(MINIDCOS_NODE) \
	    -- 'cd $(BASE_DIR) && exec /opt/mesosphere/bin/dcos-shell'

minidcos-dev: minidcos-create
	@ minidcos docker run \
	    --transport $(MINIDCOS_TRANSPORT) \
	    --cluster-id $(MINIDCOS_CLUSTER_ID) \
	    --node $(MINIDCOS_NODE) \
	    -- '(which make > /dev/null 2> /dev/null || sudo yum install -y make) ' \
	    '&& (cd $(BASE_DIR) && exec make dev)'
