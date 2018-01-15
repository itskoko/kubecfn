NAME                 ?= int
DOMAIN_ROOT          ?= example.com
DOMAIN_NAME          := $(NAME).$(DOMAIN_ROOT)
CONTROLLER_SUBDOMAIN := api
CONTROLLER_FQDN      := $(CONTROLLER_SUBDOMAIN).$(DOMAIN_NAME)
CONTROLLER_POOL_SIZE := 3

REGION       ?= us-east-1
ASSET_BUCKET ?= example-asset-bucket

TOP := $(shell pwd)
TLS_CA_CSR ?= $(TOP)/cfssl/csr/ca-csr.json

BUILD         ?= generated/$(NAME)
BUILD_TLS     := $(BUILD)/tls
BUILD_KUBEADM := $(BUILD)/kubeadm

PUBLIC_SUBNET_CIDR_PREFIX  ?= 172.20.15
PRIVATE_SUBNET_CIDR_PREFIX ?= 172.20.16

PARENT_ZONEID ?= ZABCD

VPCID ?= vpc-1234
IGW   ?= igw-1234

CLUSTER_STATE ?= existing

define kv_pair
{ "ParameterKey": "$(1)", "ParameterValue": "$(2)" }
endef

define cfn_params
[
	$(call kv_pair,DomainName,$(DOMAIN_NAME)),
	$(call kv_pair,ControllerSubdomain,$(CONTROLLER_SUBDOMAIN)),
	$(call kv_pair,assetBucket,$(ASSET_BUCKET)),
	$(call kv_pair,PrivateSubnetCidrPrefix,$(PRIVATE_SUBNET_CIDR_PREFIX)),
	$(call kv_pair,PublicSubnetCidrPrefix,$(PUBLIC_SUBNET_CIDR_PREFIX)),
	$(call kv_pair,VPCID,$(VPCID)),
	$(call kv_pair,InternetGateway,$(IGW)),
	$(call kv_pair,ParentZoneID,$(PARENT_ZONEID)),
	$(call kv_pair,ClusterState,$(CLUSTER_STATE))
]
endef
export cfn_params

OBJS := $(BUILD_TLS) $(BUILD_TLS)/ca.pem $(BUILD_TLS)/server-key.pem \
	$(BUILD_TLS)/peer-key.pem $(BUILD_KUBEADM)/ca.crt \
	$(BUILD_KUBEADM)/front-proxy-ca.crt $(BUILD_KUBEADM)/sa.pub \
	$(BUILD_KUBEADM)/admin.conf

all: $(OBJS)
upload: all
	aws s3 cp --recursive $(BUILD_TLS) s3://$(ASSET_BUCKET)/$(DOMAIN_NAME)/etcd
	aws s3 cp --recursive $(BUILD_KUBEADM) s3://$(ASSET_BUCKET)/$(DOMAIN_NAME)/kubeadm

require-op:
ifndef OP
	$(error OP required)
endif

params:
	echo $$cfn_params

create-cluster:
	OP=create-stack CLUSTER_STATE=new make cloudformation

update-cluster:
	OP=update-stack make cloudformation

cloudformation: require-op upload
	aws --region $(REGION) cloudformation $(OP) \
		--stack-name $(NAME) \
		--capabilities CAPABILITY_IAM \
		--parameters "$$cfn_params" \
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
