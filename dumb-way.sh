#!/bin/bash

# nodes
nodes[0]=master1
nodes[1]=master2
nodes[2]=master3

# nodes IP
nodes_ip[0]=192.168.150.52
nodes_ip[1]=192.168.151.52
nodes_ip[2]=192.168.152.52

# pod subnet & load balancer
POD_SUBNET=10.250.0.0/16
SERVICE_SUBNET=10.96.0.0/12
DNS_DOMAIN=cluster.local
LB=10.41.41.1

# etcd pki/bin dir
ETCD_PKI=/etc/etcd/pki
ETCD_DIR=/var/lib/etcd
ETCD_BIN=/usr/local/bin

# docker, etcd, k8s versions
DOCKER_VERSION=18.06.0
K8S_VERSION=1.13.2
ETCD_VERSION="v3.3.10"
CALICO_VERSION="v3.4"
CALICOCTL_VERSION="v3.4.0"

# cfssl stuff
curl -so cfssl https://pkg.cfssl.org/R1.2/cfssl_linux-amd64 || { echo "Can't fetch cfssl"; exit; }
curl -so cfssljson https://pkg.cfssl.org/R1.2/cfssljson_linux-amd64 || { echo "Can't fetch cfssljson"; exit; }
chmod +x cfssl cfssljson

# etcd daemon and utility
curl -sSL https://github.com/coreos/etcd/releases/download/${ETCD_VERSION}/etcd-${ETCD_VERSION}-linux-amd64.tar.gz \
  | tar -xz --strip-components=1 etcd-${ETCD_VERSION}-linux-amd64/etcdctl etcd-${ETCD_VERSION}-linux-amd64/etcd || { echo "Can't fetch etcd"; exit; }

# CA config and CSR
cat >ca-config.json <<EOF
{
   "signing": {
       "default": {
           "expiry": "43800h"
       },
       "profiles": {
           "server": {
               "expiry": "43800h",
               "usages": [
                   "signing",
                   "key encipherment",
                   "server auth",
                   "client auth"
               ]
           },
           "client": {
               "expiry": "43800h",
               "usages": [
                   "signing",
                   "key encipherment",
                   "client auth"
               ]
           },
           "peer": {
               "expiry": "43800h",
               "usages": [
                   "signing",
                   "key encipherment",
                   "server auth",
                   "client auth"
               ]
           }
       }
   }
}
EOF

cat >ca-csr.json <<EOF
{
   "CN": "etcd",
   "key": {
       "algo": "rsa",
       "size": 2048
   }
}
EOF

# CA certs
./cfssl gencert -initca ca-csr.json | ./cfssljson -bare ca -

# client certs
cat >client.json <<EOF
{
  "CN": "client",
  "key": {
      "algo": "ecdsa",
      "size": 256
  }
}
EOF
./cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json -profile=client client.json | ./cfssljson -bare client

# k8s installation & init function
k8s() {
    echo
    read -p "k8s installation on $1, press enter to continue"
    scp $1.yaml $2:/tmp
    # remove docker & k8s
    ssh $2 "kubeadm reset > /dev/null 2>&1; apt-get remove -y --allow-change-held-packages docker-ce kubelet kubeadm kubectl kubernetes-cni 2> /dev/null"
    # install docker & k8s
    ssh $2 "apt-get update && 
      apt-get install -y apt-transport-https ca-certificates curl software-properties-common && 
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add - && 
      add-apt-repository \"deb https://download.docker.com/linux/\$(. /etc/os-release; echo \"\$ID\") \$(lsb_release -cs) stable\" && 
      apt-get update && 
      apt-get install -y docker-ce=\$(apt-cache madison docker-ce | grep $DOCKER_VERSION | head -1 | awk '{print \$3}')"
    ssh $2  "curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add - && 
      echo 'deb http://apt.kubernetes.io/ kubernetes-xenial main' > /etc/apt/sources.list.d/kubernetes.list && 
      apt-get update && 
      CNI_VERSION=\$(apt-cache show kubelet=\$(apt-cache madison kubelet | fgrep $K8S_VERSION | head -1 | awk '{print \$3}') | egrep -o 'kubernetes-cni.+' | awk '{print \$3}' | cut -d ')' -f 1) && 
      apt-get install -y kubernetes-cni=\$(apt-cache madison kubernetes-cni | fgrep \$CNI_VERSION | head -1 | awk '{print \$3}') &&
      apt-get install -y \$(for i in kubelet kubeadm kubectl; do a=\`apt-cache madison \$i | fgrep $K8S_VERSION | head -1 | awk '{print \$3}'\`; echo -n \"\$i=\$a \"; done) && 
      apt-mark hold kubeadm kubectl kubelet kubernetes-cni docker-ce"
    # copy pki stuff from 1st node to 2nd & 3rd nodes
    [ "$1" != "${nodes[0]}" ] && scp -rp pki $2:/etc/kubernetes

    # execute kubeadm init and save its output to node-kubeadm-init.log
    ssh $2 "kubeadm init --config /tmp/$1.yaml" | tee $1-kubeadm-init.log

    # copy pki from master node
    [ "$1" = "${nodes[0]}" ] && scp -rp $2:/etc/kubernetes/pki/ . 
}

# certificates stuff
for i in "${!nodes[@]}"; do
    echo
    read -p "etcd installation on ${nodes[$i]}, press enter to continue"
    ./cfssl print-defaults csr > "${nodes[$i]}".json
    sed -i '0,/CN/{s/example\.net/'"${nodes[$i]}"'/}' ${nodes[$i]}.json
    sed -i '/"example\.net/a "127\.0\.0\.1",' ${nodes[$i]}.json
    sed -i 's/www\.example\.net/'"${nodes_ip[$i]}"'/' ${nodes[$i]}.json
    sed -i 's/example\.net/'"${nodes[$i]}"'/' "${nodes[$i]}".json

    ./cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json -profile=server "${nodes[$i]}".json | ./cfssljson -bare "${nodes[$i]}"-server
    ./cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json -profile=peer "${nodes[$i]}".json | ./cfssljson -bare "${nodes[$i]}"-peer

    # removing pki & data dir
    ssh ${nodes_ip[$i]} "rm -rf $ETCD_PKI; mkdir -p $ETCD_PKI; rm -rf $ETCD_DIR; rm -rf /var/lib/kubelet; rm -rf /etc/kubernetes"

    # etcd systemd unit file
    cat > ${nodes[$i]}.service <<EOF
[Unit]
Description=etcd
Documentation=https://github.com/coreos/etcd
Conflicts=etcd.service
Conflicts=etcd2.service
After=network.target

[Service]
Type=notify
Restart=always
RestartSec=10s
LimitNOFILE=40000
TimeoutStartSec=0

ExecStart=$ETCD_BIN/etcd --name ${nodes[$i]} \\
    --data-dir $ETCD_DIR \\
    --listen-client-urls https://${nodes_ip[$i]}:2379,https://127.0.0.1:2379 \\
    --advertise-client-urls https://${nodes_ip[$i]}:2379 \\
    --listen-peer-urls https://${nodes_ip[$i]}:2380 \\
    --initial-advertise-peer-urls https://${nodes_ip[$i]}:2380 \\
    --cert-file=$ETCD_PKI/${nodes[$i]}-server.pem \\
     --key-file=$ETCD_PKI/${nodes[$i]}-server-key.pem \\
    --client-cert-auth \\
    --trusted-ca-file=$ETCD_PKI/ca.pem \\
    --peer-cert-file=$ETCD_PKI/${nodes[$i]}-peer.pem \\
    --peer-key-file=$ETCD_PKI/${nodes[$i]}-peer-key.pem \\
    --peer-client-cert-auth \\
    --peer-trusted-ca-file=$ETCD_PKI/ca.pem \\
    --initial-cluster 
EOF
    for node in "${!nodes[@]}"; do
        sed -i '$s#$#'"${nodes[$node]}=https://${nodes_ip[$node]}:2380,"'#' "${nodes[$i]}".service
    done
    sed -i '$s/.$/'" --initial-cluster-token my-etcd-token --initial-cluster-state new"'/' ${nodes[$i]}.service
    cat >> ${nodes[$i]}.service <<EOF

[Install]
WantedBy=multi-user.target
EOF

    # copy certs
    for file in ca.pem ca-key.pem client.pem client-key.pem \
        ${nodes[$i]}-peer.pem ${nodes[$i]}-peer-key.pem \
        ${nodes[$i]}-server.pem ${nodes[$i]}-server-key.pem; do
            scp $file ${nodes_ip[$i]}:$ETCD_PKI
    done

    # copy unit file & etcd binaries
    scp ${nodes[$i]}.service ${nodes_ip[$i]}:/tmp/etcd.service
    scp etcd ${nodes_ip[$i]}:$ETCD_BIN
    scp etcdctl ${nodes_ip[$i]}:$ETCD_BIN

    # force stop or kill in case of active etcd
    ssh ${nodes_ip[$i]} "systemctl -f stop etcd 2> /dev/null; mv /tmp/etcd.service /etc/systemd/system/etcd.service && systemctl daemon-reload && pkill -9 etcd; systemctl enable etcd > /dev/null 2>&1; systemctl start etcd" & > /dev/null 2>&1

    # k8s installation
    cat > ${nodes[$i]}.yaml <<EOF
apiVersion: kubeadm.k8s.io/v1alpha3
kind: InitConfiguration
apiEndpoint:
  advertiseAddress: $LB
---
apiVersion: kubeadm.k8s.io/v1alpha3
kind: ClusterConfiguration
etcd:
  external:
    endpoints:
    - https://${nodes_ip[0]}:2379
    - https://${nodes_ip[1]}:2379
    - https://${nodes_ip[2]}:2379
    caFile: $ETCD_PKI/ca.pem
    certFile: $ETCD_PKI/client.pem
    keyFile: $ETCD_PKI/client-key.pem
networking:
  serviceSubnet: $SERVICE_SUBNET
  podSubnet: $POD_SUBNET
  dnsDomain: $DNS_DOMAIN
apiServerCertSANs:
- "${nodes_ip[0]}"
- "${nodes_ip[1]}"
- "${nodes_ip[2]}"
- "${nodes[0]}"
- "${nodes[1]}"
- "${nodes[2]}"
- "127.0.0.1"
- "$LB"
apiServerExtraArgs:
  apiserver-count: "3"
EOF
done

# k8s installation on 1st node
k8s ${nodes[0]} ${nodes_ip[0]}

# calico installation on 1st node
curl -sSL -o calicoctl https://github.com/projectcalico/calicoctl/releases/download/$CALICOCTL_VERSION/calicoctl-linux-amd64
cat > calico.sh << EOF
#!/bin/bash
export KUBECONFIG=/etc/kubernetes/admin.conf
export ETCD_ENDPOINTS=https://127.0.0.1:2379
export ETCD_KEY_FILE=$ETCD_PKI/client-key.pem
export ETCD_CERT_FILE=$ETCD_PKI/client.pem
export ETCD_CA_CERT_FILE=$ETCD_PKI/ca.pem
curl -s https://docs.projectcalico.org/$CALICO_VERSION/getting-started/kubernetes/installation/hosted/calico.yaml -O

# replace default etcd address
sed -i 's#http://10.96.232.136:6666#https://${nodes_ip[0]}:2379,https://${nodes_ip[1]}:2379,https://${nodes_ip[2]}:2379#' calico.yaml
# enable etcd_ca, etcd_cert, etcd_key TLS
sed -ri 's/".+#//' calico.yaml
# etcd client key
sed -ri "s/# (etcd-key:) null/\1 \$(cat $ETCD_PKI/client-key.pem | base64 -w 0)/" calico.yaml
# etcd client cert
sed -ri "s/# (etcd-cert:) null/\1 \$(cat $ETCD_PKI/client.pem | base64 -w 0)/" calico.yaml
# etcd ca crt
sed -ri "s/# (etcd-ca:) null/\1 \$(cat $ETCD_PKI/ca.pem | base64 -w 0)/" calico.yaml
# replaces default 192.168.0.0/16 subnet
sed -i 's#192.168.0.0/16#$POD_SUBNET#' calico.yaml
# install calico
kubectl apply -f calico.yaml
echo "Sleeping for a while"
sleep 5
until \$(./calicoctl get ippool | grep -q default-ipv4-ippool); do echo "Waiting for Calico initialization"; sleep 5; done
# enables CrossSubnet instead of ipipMode
./calicoctl apply -f - << ASD
\$(./calicoctl get ippool -o yaml | sed "s/Always/CrossSubnet/")
ASD
EOF
scp calicoctl calico.sh ${nodes_ip[0]}:
ssh ${nodes_ip[0]} "chmod +x calicoctl calico.sh; ./calico.sh"

# k8s installation on other nodes
for i in 1 2; do
    k8s ${nodes[$i]} ${nodes_ip[$i]}
done
