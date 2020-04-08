#!/bin/bash

CNI_YAMLS="https://docs.projectcalico.org/manifests/calico.yaml"
POD_CIDR="192.168.0.0/16"

ERROR() {
    echo "******************************************************"
    echo "** ERROR: $*"
    echo "******************************************************"
}

[ -z "$API_KEY" ] && ERROR "API_KEY is unset"
[ -z "$ORG_ID"  ] && ERROR "ORG_ID is unset"
[ -z "$OWNER_ID_OR_EMAIL" ] && ERROR "OWNER_ID_OR_EMAIL is unset"P

#export PRIVATE_IP=$(hostname -i)
export PRIVATE_IP=$(ec2metadata --local-ipv4)
export PUBLIC_IP=$(ec2metadata --public-ipv4)

[ -z "$PRIVATE_IP" ] && ERROR "PRIVATE_IP is unset"P
[ -z "$PUBLIC_IP"  ] && ERROR "PUBLIC_IP is unset"P

SCRIPT_DIR=$(dirname $0)

echo "Checking for Events owned by '$OWNER_ID_OR_EMAIL'"

set -x
NODE_IDX=$($SCRIPT_DIR/get_workspaces_info.py -idx)
set +x
[ -z "$NODE_IDX"  ] && ERROR "NODE_IDX is unset"P
NUM_MASTERS=1

apt-get update && apt-get install -y jq

id -un

#ping -c 1 $LAB_Virtual_Machine_1_PRIVATE_IP #ping -c 1 $LAB_Virtual_Machine_2_PRIVATE_IP 
#sudo -u ubuntu ssh -o StrictHostKeyChecking=no $LAB_Virtual_Machine_1_PRIVATE_IP  uptime

START_DOCKER_plus() {
    systemctl start docker
    systemctl enable docker
    echo "root: docker ps"
    docker ps

    groupadd docker
    usermod -aG docker ubuntu
    echo "ubuntu: docker ps"
    sudo -u ubuntu docker ps
    echo "ubuntu: docker version"
    sudo -i docker version
    #newgrp docker
}

GET_LAB_RESOURCES() {
    # CAREFUL THIS WILL EXPOSE YOUR API_KEY/ORG_ID
    curl -H "Authorization: Bearer ${ORG_ID}:${API_KEY}" -H "Accept: application/json" -H "Content-Type: application/json" "https://app.strigo.io/api/v1/classes/${CLASSID}/resources" | jq . | tee /tmp/LAB_RESOURCES.json
}

GET_EVENTS() {
    curl -H "Authorization: Bearer ${ORG_ID}:${API_KEY}" -H "Accept: application/json" -H "Content-Type: application/json" "https://app.strigo.io/api/v1/events" | jq . | tee /tmp/EVENTS.json
}

KUBEADM_INIT() { # USE $POD_CIDR
    #kubeadm init --kubernetes-version=$K8S_RELEASE --pod-network-cidr=$POD_CIDR --apiserver-cert-extra-sans=__MASTER1_IP__ | tee kubeadm-init.out
    #kubeadm init --pod-network-cidr=$POD_CIDR --apiserver-cert-extra-sans=$(ec2metadata --public-ip) | tee kubeadm-init.out
    kubeadm init | tee /tmp/kubeadm-init.out
}

KUBEADM_JOIN() {

    set -x
        NUM_NODES=$($SCRIPT_DIR/get_workspaces_info.py -nodes)
    set +x

    JOIN_COMMAND=$(kubeadm token create --print-join-command)

    let WORKER_NUM=NUM_NODES-NUM_MASTERS
    for WORKER in $(seq $WORKER_NUM); do
        let NODE_NUM=NUM_MASTERS+WORKER-1

        set -x
            WORKER_IPS=$($SCRIPT_DIR/get_workspaces_info.py -ips $NODE_NUM)
        set +x
	PRIVATE_IP=${WORKER_IPS%,*};
	PUBLIC_IP=${WORKER_IPS#*,};

	echo "WORKER[$WORKER]=NODE[$NODE_NUM] PRIVATE_IP=$PRIVATE_IP PUBLIC_IP=$PUBLIC_IP"

        while ! sudo -u ubuntu ssh -o StrictHostKeyChecking=no $PRIVATE_IP uptime; do sleep 2; echo "Waiting for successful Worker$WORKER ssh conection ..."; done

        CMD="sudo -u ubuntu ssh $PRIVATE_IP sudo $JOIN_COMMAND"
	echo "-- $CMD"
	$CMD
    done
}

CNI_INSTALL() {
    kubectl get nodes

    for CNI_YAML in $CNI_YAMLS; do
        kubectl create -f $CNI_YAML
    done
    kubectl get nodes
    kubectl get pods -n kube-system

    echo "NEED TO WAIT - HOW TO HANDLE failure ... need to restart coredns, other?"
}

SETUP_KUBECONFIG() {
    export KUBECONFIG=/etc/kubernetes/admin.conf

    mkdir -p /home/ubuntu/.kube
    cp -a $KUBECONFIG /home/ubuntu/.kube/config
    chown -R ubuntu:ubuntu /home/ubuntu/.kube

    #sudo -u ubuntu KUBECONFIG=/home/ubuntu/.kube/config kubectl get nodes
    sudo -u ubuntu kubectl get nodes
}

KUBECTL_VERSION() {
    kubectl version -o yaml
}

SECTION() {
    SECTION="$*"

    echo; echo "============ $SECTION ================================="
    $*
}

SECTION START_DOCKER_plus
# SECTION GET_LAB_RESOURCES - CAREFUL THIS WILL EXPOSE YOUR API_KEY/ORG_ID

# Perform all kubeadm operations from Master1:
if [ $NODE_IDX -eq 0 ] ; then
    SECTION KUBEADM_INIT
    SECTION SETUP_KUBECONFIG
    SECTION CNI_INSTALL
    SECTION KUBEADM_JOIN
    SECTION KUBECTL_VERSION
fi


