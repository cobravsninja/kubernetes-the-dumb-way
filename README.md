# Kubernetes The Dumb Way
A simple script, which installs etcd, kubernetes and calico CNI (which will use etcd as datastore and CrossSubnet mode for pod communication) on 3 nodes. Should be used ONLY ON CLEAN SYSTEMS, cause it tries to delete target directories and uninstall/reset k8s cluster and etcd DB. Couple of variables which should be modified are:

- nodes
- nodes_ip
- POD_SUBNET
- LB (load balancer)
- DOCKER_VERSION
- K8S_VERSION
- ETCD_VERSION
- CALICO_VERSION
- CALICOCTL_VERSION

The reason of using LB is simple - without usage of advertiseAddress during cluster initialization last master will advertise itself in configmap. Output of kubeadm initialization will be saved to $node-kubeadm-init.log. This script tested on Debian 9 and Ubuntu 16.04.
