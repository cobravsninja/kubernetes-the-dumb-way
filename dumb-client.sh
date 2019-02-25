#!/bin/bash

# docker, k8s versions
DOCKER_VERSION=18.06.0
K8S_VERSION=1.13.2

apt-get install -y apt-transport-https ca-certificates curl software-properties-common &&
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add - &&
  add-apt-repository "deb https://download.docker.com/linux/$(. /etc/os-release; echo "$ID") $(lsb_release -cs) stable" &&
  apt-get update &&
  apt-get install -y docker-ce=$(apt-cache madison docker-ce | grep $DOCKER_VERSION | head -1 | awk '{print $3}') &&
  curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add - &&
  echo 'deb http://apt.kubernetes.io/ kubernetes-xenial main' > /etc/apt/sources.list.d/kubernetes.list &&
  apt-get update &&
  CNI_VERSION=$(apt-cache show kubelet=$(apt-cache madison kubelet | fgrep $K8S_VERSION | head -1 | awk '{print $3}') | egrep -o 'kubernetes-cni.+' | awk '{print $3}' | cut -d
 ')' -f 1) &&
  apt-get install -y kubernetes-cni=$(apt-cache madison kubernetes-cni | fgrep $CNI_VERSION | head -1 | awk '{print $3}') &&
  apt-get install -y $(for i in kubelet kubeadm kubectl; do a=`apt-cache madison $i | fgrep $K8S_VERSION | head -1 | awk '{print $3}'`; echo -n "$i=$a "; done) &&
  apt-mark hold kubeadm kubectl kubelet kubernetes-cni docker-ce
