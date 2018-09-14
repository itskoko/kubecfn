NAME   ?= example
CONFIG ?= config/$(NAME).json
REGION ?= us-east-1

ifdef $$REGION
REGION=$$REGION
endif

ifdef $$NAME
NAME=$$NAME
endif

TOP := $(shell pwd)
TLS_CA_CSR ?= $(TOP)/cfssl/csr/ca-csr.json

BUILD         ?= generated/$(NAME)
BUILD_TLS     := $(BUILD)/tls
BUILD_KUBEADM := $(BUILD)/kubeadm

define config
$(shell jq -r '.[]|select(.ParameterKey == "$(1)").ParameterValue' $(CONFIG))
endef

DOMAIN_NAME                := $(call config,DomainName)
CONTROLLER_SUBDOMAIN       := $(call config,ControllerSubdomain)
CONTROLLER_FQDN            := $(CONTROLLER_SUBDOMAIN).$(DOMAIN_NAME)
ASSET_BUCKET               := $(call config,assetBucket)
CLUSTER_STATE              := $(call config,ClusterState)

OBJS := $(BUILD_TLS) $(BUILD_TLS)/ca.pem $(BUILD_TLS)/server-key.pem \
	$(BUILD_TLS)/peer-key.pem $(BUILD_KUBEADM)/ca.crt \
	$(BUILD_KUBEADM)/front-proxy-ca.crt $(BUILD_KUBEADM)/sa.pub \
	$(BUILD_KUBEADM)/admin.conf

all: $(OBJS)
upload: all
	aws s3 cp --recursive templates/       s3://$(ASSET_BUCKET)/$(DOMAIN_NAME)/templates
	aws s3 cp --recursive $(BUILD_TLS)     s3://$(ASSET_BUCKET)/$(DOMAIN_NAME)/etcd
	aws s3 cp --recursive $(BUILD_KUBEADM) s3://$(ASSET_BUCKET)/$(DOMAIN_NAME)/kubeadm

require-op:
ifndef OP
	$(error OP required)
endif

create-cluster:
	OP=create-stack make cloudformation

update-cluster:
	OP=update-stack make cloudformation

cloudformation: require-op upload
	aws --region $(REGION) cloudformation $(OP) \
		--stack-name $(NAME) \
		--capabilities CAPABILITY_IAM \
		--parameters "$$(cat $(CONFIG))" \
		--template-body "$$(cat kubernetes.yaml)" $(OPTS)

$(BUILD):
	mkdir -p $@

$(BUILD_TLS):
	mkdir -p $@

$(BUILD_TLS)/ca.pem:
	cd $(BUILD_TLS); cfssl gencert -initca $(TLS_CA_CSR) | cfssljson -bare ca -

$(BUILD_TLS)/server-key.pem:
	cd $(BUILD_TLS); \
		echo '{"CN":"$(CONTROLLER_FQDN)","hosts":["$(DOMAIN_NAME)","*.$(DOMAIN_NAME)","*.ec2.internal","localhost", "kubernetes", "kubernetes.default", "kubernetes.default.svc", "kubernetes.default.svc.cluster.local" ],"key":{"algo":"rsa","size":2048}}' \
		| cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=$(TOP)/cfssl/ca-config.json -profile=server -hostname="$(HOSTNAME_API)" - \
		| cfssljson -bare server

$(BUILD_TLS)/peer-key.pem:
	cd $(BUILD_TLS); \
		echo '{"CN":"$(CONTROLLER_FQDN)","hosts":["$(DOMAIN_NAME)","*.$(DOMAIN_NAME)","*.ec2.internal","localhost"],"key":{"algo":"rsa","size":2048}}' \
		| cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=$(TOP)/cfssl/ca-config.json -profile=peer -hostname="$(HOSTNAME_API)" - \
		| cfssljson -bare peer

$(BUILD_KUBEADM)/ca.crt:
	kubeadm alpha phase certs ca --cert-dir $(TOP)/$(dir $@)

$(BUILD_KUBEADM)/front-proxy-ca.crt:
	kubeadm alpha phase certs front-proxy-ca --cert-dir $(TOP)/$(dir $@)

$(BUILD_KUBEADM)/sa.pub:
	kubeadm alpha phase certs sa --cert-dir $(TOP)/$(dir $@)

$(BUILD_KUBEADM)/admin.conf: $(BUILD_KUBEADM)/ca.crt
	kubeadm alpha phase kubeconfig admin \
		--apiserver-advertise-address $(CONTROLLER_FQDN) \
		--cert-dir $(TOP)/$(dir $@)
	# FIXME: Somehow --apiserver-advertise-address isn't working so we need to
	# patch file manually.
	sed 's|\(server: https://\)[^:]*\(.*\)|\1$(CONTROLLER_FQDN)\2|' \
		/etc/kubernetes/admin.conf \
		| install -m600 /dev/stdin $(dir $@)/admin.conf
