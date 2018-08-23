FROM debian:sid

ENV KUBE_VERSION v1.11.2
ENV KUBEADM_URL https://storage.googleapis.com/kubernetes-release/release/$KUBE_VERSION/bin/linux/amd64/kubeadm

RUN apt-get -qy update && apt-get -qy install curl make awscli golang-cfssl jq \
  && useradd -m user \
  && curl -Lfo /usr/bin/kubeadm "$KUBEADM_URL" \
  && chmod a+x  /usr/bin/kubeadm

COPY  . /usr/src
WORKDIR /usr/src
ENTRYPOINT [ "make" ]
