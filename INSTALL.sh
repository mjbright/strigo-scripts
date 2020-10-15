#!/bin/bash

SCRIPT_DIR=$(dirname $0)

CNI_YAMLS=${CNI_YAMLS:=https://docs.projectcalico.org/manifests/calico.yaml}
POD_CIDR=${POD_CIDR:=192.168.0.0/16}

WORKER_PREFIX=${WORKER_PREFIX:=worker}
END_USER=${END_USER:=ubuntu}
REF_USER=${REF_USER:=ubuntu} # Copy .ssh from here
ANSIBLE_INSTALL=${ANSIBLE_INSTALL:=0}
PRISMA_PCC_ACCESS=${PRISMA_PCC_ACCESS:=__PRISMA_ACCESS_KEY__}
REGISTER_URL=${REGISTER_URL:=__REGISTER_URL__}
INSTALL_KUBELAB=${INSTALL_KUBELAB:=1}
DOWNLOAD_PCC_TWISTLOCK=${DOWNLOAD_PCC_TWISTLOCK:=0}
INSTALL_PCC_TWISTLOCK=${INSTALL_PCC_TWISTLOCK:=0}
[ ! -z "$UNSET_API_FAILURE" ] && export SIMULATE_API_FAILURE=""

# Detect if interactive, mark if Strigo API working:
# Note: to test, export SIMULATE_API_FAILURE="1" in user-data
export STRIGO_API_FAILURE=0

BIN=/usr/local/bin

# Detect if interactive shell or not:
INTERACTIVE_SHELL=0
# Take defaults on apt-get commands: even in interactive mode
export DEBIAN_FRONTEND=noninteractive
if [ -t 0 ];then
    # Interactive running on 0th (master) node
    INTERACTIVE_SHELL=1
    [ -z "$OVERRIDE_NODE_IDX" ] && export NODE_IDX=0
fi

sudo mv $(readlink -f /var/lib/cloud/instance) /root/tmp/instance/

SECTION_LOG=/tmp/SECTION.log
EVENT_LOG=/root/tmp/event.log

[   -f ${SECTION_LOG}         ] && cp -a $SECTION_LOG ${SECTION_LOG}.$(date +'%Y-%m-%d_%H-%M-%S')
[ ! -f ${SECTION_LOG}.initial ] && [ -f $SECTION_LOG ] && mv $SECTION_LOG ${SECTION_LOG}.initial

#export PRIVATE_IP=$(hostname -i)
export PRIVATE_IP=$(ec2metadata --local-ipv4)
export PUBLIC_IP=$(ec2metadata --public-ipv4)
export NODE_NAME="unset"

# Add ip addresses/placeholder in /etc/hosts:
{
    grep -q $PRIVATE_IP   /etc/hosts || echo "$PRIVATE_IP THIS_NODE"
    grep -q $PUBLIC_IP    /etc/hosts || echo "$PUBLIC_IP THIS_NODE_pub"
} >> /etc/hosts

## Functions ----------------------------------------------------------------------------

ERROR() {
    echo "******************************************************"
    echo "** ERROR: $*"
    echo "******************************************************"
}

SECTION_LOG() {
    if [ -z "$1" ]; then
        tee -a ${SECTION_LOG}
    else
        echo "$*" >> ${SECTION_LOG}
    fi
}

SECTION() {
    SECTION="$*"

    echo;
    { 
        df -h / | grep -v ^Filesystem;
        echo "== [$(date)] ========== $SECTION =================================";
    } | SECTION_LOG
    $*
}

die() {
    ERROR $*
    echo "$0: die - Installation failed" >&2 | SECTION_LOG
    echo $* >&2
    exit 1
}

# MISC FUNCTIONS ========================================================

INIT_SHELL_PROFILE_HISTORY() {
    cat >> /root/.profile <<EOF
export HOME=/root
export PATH=~/bin:$PATH
EOF

    cat > /root/.jupyter.profile <<EOF
export HOME=/root
export PATH=~/bin:$PATH
EOF

    #echo 'watch -n 2 "kubectl get nodes; echo; kubectl get ns; echo; kubectl -n kubelab -o wide get cm,pods"' >> /home/$END_USER/.bash_history
    #echo 'watch -n 2 "kubectl get nodes; echo; kubectl get ns; echo; kubectl -n kubelab -o wide get cm,pods"' >> /root/.bash_history
    echo '. /root/.jupyter.profile; cd; echo HOME=$HOME' >> /root/.bash_history
    echo 'kubectl get nodes' >> /home/$END_USER/.bash_history
    echo 'tail -100f /tmp/SECTION.log' >> /home/$END_USER/.bash_history

    export HOME=/root
}

CREATE_USER() {
    local END_USER=$1; shift

    adduser $END_USER --disabled-password --gecos "Student $END_USER,,,"
    cp -a /home/$REF_USER/.ssh/ /home/$END_USER/
    ls -al /home/$REF_USER/.ssh/
    chown -R $END_USER:$END_USER /home/$END_USER/.ssh/
    ls -al /home/$END_USER/.ssh/
    echo "$END_USER ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/95-student-user
}

INSTALL_GITHUB_REPOS() {
    local END_USER=$1; shift
    local DIR=$1; shift

    [ -z "$1" ] && { echo "INSTALL_GITHUB_REPOS: No github repos to install"; return 0; }

    echo "INSTALL_GITHUB_REPOS: github repos to install - $*"
    mkdir -p $DIR

    for REPO in $*; do
        NEWDIR=$(echo $REPO | sed 's/\//./g')

        set -x; git clone https://github.com/$REPO $DIR/$NEWDIR; set +x
    done

    chown -R $END_USER:$END_USER $DIR/$NEWDIR
}

SETUP_INSTALL_PROFILE() {
    case $INSTALL_PROFILE in
        INSTALL_FN_*)
            echo "INSTALL_PROFILE: invoking $INSTALL_PROFILE"
            $INSTALL_PROFILE;;
        "")
            echo "INSTALL_PROFILE: UNSET ... skipping";;
        *)
            echo "INSTALL_PROFILE: Bad $INSTALL_PROFILE ... skipping";;
    esac
}

# START: TIMER FUNCTIONS ================================================

TIMER_START() {
    START_S=`date +%s`
}

TIMER_STOP() {
    END_S=`date +%s`
    let TOOK=END_S-START_S

    TIMER_hhmmss $TOOK
    echo "$*Took $TOOK secs [${HRS}h${MINS}m${SECS}]"
}

TIMER_hhmmss() {
    _REM_SECS=$1; shift

    let SECS=_REM_SECS%60

    let _REM_SECS=_REM_SECS-SECS

    let MINS=_REM_SECS/60%60

    let _REM_SECS=_REM_SECS-60*MINS

    let HRS=_REM_SECS/3600

    [ $SECS -lt 10 ] && SECS="0$SECS"
    [ $MINS -lt 10 ] && MINS="0$MINS"
}

# END: TIMER FUNCTIONS ================================================

# UNINSTALL  FUNCTIONS ================================================

UNINSTALL_DOCKER_K8S_BITS() {
    set -x
    apt-get remove -y kubeadm kubectl kubelet vim docker.io
    rm -f /etc/apt/sources.list.d/kubernetes.list
    set +x
}

# STRIGO     FUNCTIONS ================================================

set_EVENT_WORKSPACE_NODES() {
    [ -z "$NUM_NODES" ] && die "Expected number of nodes is not set/exported from invoking user-data script"

    cp /dev/null $EVENT_LOG

    _NUM_NODES=$($SCRIPT_DIR/get_strigo_info.py -nodes | tee -a $EVENT_LOG)

    if [ "$SIMULATE_API_FAILURE" != "" ]; then
        echo "SIMULATE_API_FAILURE is set: so setting _NUM_NODES=''"
        _NUM_NODES=""
    fi

    # Strigo API data not available:
    if [ -z "$_NUM_NODES" ]; then
        export STRIGO_API_FAILURE=1
        echo "STRIGO_API data unavailable"
        USER_EMAIL="USER_EMAIL_unset"

        if [ $INTERACTIVE_SHELL -eq 1 ];then
            WORKER_IPS=""
            # Manually setting WORKER_IPS as calls to $SCRIPT_DIR/get_strigo_info.py are failing
            let NUM_WORKERS=NUM_NODES-1
            for NODE_NUM in $(seq 1 $NUM_WORKERS); do
                echo;
                NODE_NAME="${WORKER_PREFIX}${NODE_NUM}"
                sed 's/#.*//' /etc/hosts | grep -q " ${NODE_NAME}"     || die "Create private ip address entry for $NODE_NAME in /etc/hosts"
                sed 's/#.*//' /etc/hosts | grep -q " ${NODE_NAME}_pub" || die "Create public  ip address entry for $NODE_NAME in /etc/hosts"

                WORKER_PRIVATE_IP=$(sed -e 's/#.*//' -e 's/ *$//' /etc/hosts | grep " ${NODE_NAME}_pub" | awk '{ print $1; exit(0); }')
                WORKER_PUBLIC_IP=$( sed -e 's/#.*//' -e 's/ *$//' /etc/hosts | grep " ${NODE_NAME}$"    | awk '{ print $1; exit(0); }')

                [ ! -z "$WORKER_IPS" ] && WORKER_IPS="$WORKER_IPS,"
                WORKER_IPS+="$WORKER_PRIVATE_IP"
                WORKER_IPS+=",$WORKER_PUBLIC_IP"

                echo "Will launch RERUN_INSTALL.sh on worker nodes in background (from CONFIG_NODES_ACCESS_FROM_NODE0())" | SECTION_LOG
            done
        else
            echo "Running in non-interactive shell - exiting, you need to run $SCRIPT_DIR/RERUN_INSTALL.sh"
            echo "Remember to populate master/worker public/private ip addresses first in master:/etc/hosts"
            exit 1
        fi
        return
    fi

    while [ $_NUM_NODES -lt $NUM_NODES ]; do
        echo "[ '$_NUM_NODES' -lt '$NUM_NODES' ] - waiting for more nodes to become available ..."
        sleep 5
        _NUM_NODES=$($SCRIPT_DIR/get_strigo_info.py -nodes | tee -a $EVENT_LOG)
        [ -z "$_NUM_NODES" ] && _NUM_NODES=0
    done

    let NUM_WORKERS=NUM_NODES-NUM_MASTERS

    NODE_IDX=$($SCRIPT_DIR/get_strigo_info.py -idx | tee -a $EVENT_LOG)
    [ -z "$NODE_IDX"  ] && die "NODE_IDX is unset"

    EVENT=$($SCRIPT_DIR/get_strigo_info.py -e | tee -a $EVENT_LOG)
    [ -z "$EVENT"  ] && die "EVENT is unset"

    WORKSPACE=$($SCRIPT_DIR/get_strigo_info.py -w | tee -a $EVENT_LOG)
    [ -z "$WORKSPACE"  ] && die "WORKSPACE is unset"

    $SCRIPT_DIR/get_strigo_info.py -v -ips | tee -a $EVENT_LOG

    USER_EMAIL=$($SCRIPT_DIR/get_strigo_info.py -oem | tee -a $EVENT_LOG)
}

START_DOCKER_plus() {
    systemctl start docker
    systemctl enable docker
    echo "root: docker ps"
    docker ps

    groupadd docker
    usermod -aG docker $END_USER
    { echo "$END_USER: docker ps"; sudo -u $END_USER docker ps; } | SECTION_LOG
    docker version -f "Docker Version Client={{.Client.Version}} Server={{.Server.Version}}" | SECTION_LOG
    echo "root: docker version"; sudo docker version
    # newgrp docker # In shell allow immediate joining of group / use of docker
}

GET_LAB_RESOURCES() {
    # CAREFUL THIS WILL EXPOSE YOUR API_KEY/ORG_ID
    curl -H "Authorization: Bearer ${ORG_ID}:${API_KEY}" -H "Accept: application/json" -H "Content-Type: application/json" "https://app.strigo.io/api/v1/classes/${CLASSID}/resources" | jq . | tee /tmp/LAB_RESOURCES.json
}

GET_EVENTS() {
    curl -H "Authorization: Bearer ${ORG_ID}:${API_KEY}" -H "Accept: application/json" -H "Content-Type: application/json" "https://app.strigo.io/api/v1/events" | jq . | tee /tmp/EVENTS.json
}

RANCHER_RKE_INIT() { # USE $POD_CIDR

    FILE=$BIN/rke
    URL=https://github.com/rancher/rke/releases/download/${RANCHER_RKE_RELEASE}/rke_linux-amd64
    wget -qO $BIN/rke $URL
}

KUBEADM_INIT() {
    #kubeadm init --kubernetes-version=$K8S_RELEASE --pod-network-cidr=$POD_CIDR --apiserver-cert-extra-sans=__MASTER1_IP__ | tee kubeadm-init.out
    export NODE_NAME="master"
    sudo hostnamectl set-hostname $NODE_NAME
    echo "local hostname=$(hostname)" | SECTION_LOG

    KUBERNETES_VERSION="--kubernetes-version $K8S_RELEASE"
    [ $UPGRADE_KUBE_LATEST -eq 1 ] && KUBERNETES_VERSION="--kubernetes-version $(kubeadm version -o short)"

    kubeadm init $KUBERNETES_VERSION --node-name $NODE_NAME \
            --pod-network-cidr=$POD_CIDR --kubernetes-version=$K8S_RELEASE \
            --apiserver-cert-extra-sans=$PUBLIC_IP | \
        tee /tmp/kubeadm-init.out
    #kubeadm init | tee /tmp/kubeadm-init.out
}

# To be done once .kubeconfig is configured (copied):
KUBEADM_POST_INIT() {
    kubectl get nodes | SECTION_LOG

    SECTION_LOG "UNTAINT_MASTER=$UNTAINT_MASTER"
    [ $UNTAINT_MASTER -ne 0 ] && kubectl taint node master node-role.kubernetes.io/master:NoSchedule- |& SECTION_LOG
}

# Configure nodes access from master:
# - Add entries to /etc/hosts
# - Create .ssh/config entries
#
CONFIG_NODES_ACCESS_FROM_NODE0() {
    echo "local hostname=$(hostname)" | SECTION_LOG
    ENTRY="$PRIVATE_IP master"
    echo "Adding master entry: $ENTRY"
    echo $ENTRY | tee /tmp/hosts.add

    NODE_PRIVATE_IPS=""
    for NODE_NUM in $(seq 1 $NUM_NODES); do
        #XXX ??? let NODE_NUM=NUM_MASTERS+WORKER-1
        #let NODE_NUM=NODE_NUM-1

        [ $STRIGO_API_FAILURE -eq 0 ] && NODE_IPS=$($SCRIPT_DIR/get_strigo_info.py -ips $NODE_NUM)
        [ -z "$NODE_IPS" ] && die "[STRIGO_API_FAILURE=$STRIGO_API_FAILURE] Failed to get NODE_IPS"

        NODE_PRIVATE_IP=${NODE_IPS%,*};
        NODE_PUBLIC_IP=${NODE_IPS#*,};
        NODE_PRIVATE_IPS+=" $NODE_PRIVATE_IP"
	if [ $NODE_NUM -le $NUM_MASTERS ]; then
            NODE_NAME="master$NODE_NUM"
	    [ $NODE_NUM -eq 0 ] && NODE_NAME="master"
	else
            let WORKER_NODE_NUM=NODE_NUM-NUM_MASTERS
            NODE_NAME="${WORKER_PREFIX}$NODE_NUM"
	fi

        #echo "$NODE_PRIVATE_IP $NODE_NAME" | tee -a /tmp/hosts.add | SECTION_LOG
        ENTRY="$NODE_PRIVATE_IP $NODE_NAME"
        echo "Adding NODE$NODE_NUM entry: $ENTRY"
        echo $ENTRY | tee -a /tmp/hosts.add | SECTION_LOG

        mkdir -p ~/.ssh
        mkdir -p /home/$END_USER/.ssh
        touch /home/$END_USER/.ssh/config
        cp -a /home/$END_USER/.ssh/id_rsa /root/.ssh/
        chown $END_USER:$END_USER /home/$END_USER/.ssh/config
        {
            echo ""
            echo "Host $NODE_NAME"
            echo "    User     $END_USER"
            echo "    Hostname $NODE_PRIVATE_IP"
            echo "    IdentityFile ~/.ssh/id_rsa"
        } | tee -a /home/$END_USER/.ssh/config | sed 's?~?/root?' | tee -a ~/.ssh/config

        echo "NODE[$NODE_NUM] $NODE_NAME NODE_PRIVATE_IP=$NODE_PRIVATE_IP NODE_PUBLIC_IP=$NODE_PUBLIC_IP"

        _SSH_IP="sudo -u $END_USER ssh -o StrictHostKeyChecking=no $NODE_PRIVATE_IP"
        while ! $_SSH_IP uptime; do sleep 2; echo "Waiting for successful $NODE_NAME ssh conection ..."; done

        _SSH_ROOT_IP="ssh -l $END_USER -o StrictHostKeyChecking=no $NODE_PRIVATE_IP"
        $_SSH_ROOT_IP uptime

        {
            echo "From $END_USER to $END_USER@$NODE_NAME: hostname=$($_SSH_IP      hostname)";
            echo "From   root to $END_USER@$NODE_NAME: hostname=$($_SSH_ROOT_IP hostname)";
        } | SECTION_LOG
        $_SSH_ROOT_IP sudo hostnamectl set-hostname $NODE_NAME

        [ $STRIGO_API_FAILURE -eq 1 ] && {
            echo "[STRIGO_API_FAILURE=$STRIGO_API_FAILURE] Launching RERUN_INSTALL.sh on $NODE_NAME"

            # Setting NODE_IDX to NODE_NUM (so we know which worker node is running the script):
            # Unsetting STRIGO_API_FAILURE
            RERUN_LOG=/tmp/RERUN_INSTALL_${NODE_NAME}.log
            CMD="$_SSH_ROOT_IP sudo UNSET_API_FAILURE=1 OVERRIDE_NODE_IDX=$NODE_NUM $SCRIPT_DIR/RERUN_INSTALL.sh"
            echo "-- $CMD >$RERUN_LOG 2>&1 &" | SECTION_LOG
            $CMD >$RERUN_LOG 2>&1 &
        }
    done

    echo; echo "-- setting up /etc/hosts"
    cat /tmp/hosts.add >> /etc/hosts
    for NODE in $(seq 2 $NUM_NODES); do
	if [ $NODE_NUM -lt $NUM_MASTERS ]; then
            NODE_NAME="master$NODE"
	else
            let WORKER_NODE_NUM=NODE-NUM_MASTERS
            NODE_NAME="${WORKER_PREFIX}$NODE"
	fi

        cat /tmp/hosts.add | ssh $NODE_NAME "sudo tee -a /etc/hosts"
    done
}

EACH_WORKER_NODE() {
    for WORKER in $(seq $NUM_WORKERS); do
        WORKER_NODE_NAME="${WORKER_PREFIX}$WORKER"
        eval "$*"
        eval CMD="\"$*\""
    done
}

# TO use once CONFIG_NODES_ACCESS_FROM_NODE0() has run to setup ~/.ssh/config
SSH_EACH_WORKER_NODE() {
    for WORKER in $(seq $NUM_WORKERS); do
        WORKER_NODE_NAME="${WORKER_PREFIX}$WORKER"
        eval CMD="\"$*\""
        ssh $WORKER_NODE_NAME "$CMD"
    done
}

KUBEADM_JOIN() {
    JOIN_COMMAND=$(kubeadm token create --print-join-command)" --node-name $WORKER_NODE_NAME"

    echo; echo "-- performing join command on worker nodes"

    SSH_EACH_WORKER_NODE 'sudo $JOIN_COMMAND'
    SSH_EACH_WORKER_NODE 'echo '$WORKER_NODE_NAME' > /tmp/NODE_NAME; cat /tmp/NODE_NAME' | SECTION_LOG

    kubectl get nodes | SECTION_LOG

    MAX_LOOPS=10; LOOP=0;
    while ! kubectl get nodes | grep $WORKER_NODE_NAME; do
        echo "Waiting for worker nodes to join ..."
        let LOOP=LOOP+1; sleep 2; [ $LOOP -ge $MAX_LOOPS ] && die "Failed to join $WORKER_NODE_NAME"
    done
}

CNI_INSTALL() {
    kubectl get nodes

    for CNI_YAML in $CNI_YAMLS; do
        #kubectl create -f $CNI_YAML | SECTION_LOG
        kubectl create -f $CNI_YAML
    done
    kubectl get nodes
    kubectl get pods -n kube-system
    kubectl get pods -n kube-system | grep -i calico | SECTION_LOG

    echo "NEED TO WAIT - HOW TO HANDLE failure ... need to restart coredns, other?"
    kubectl get nodes | SECTION_LOG

    WAIT_NS_PODS kube-system
    if [ $BAD_PODS -ne 0 ]; then
        for BAD_POD_NAME in $BAD_PODS_NAME; do
            echo "bad pod: kubectl delete pod -n kube-system $BAD_POD_NAME"
            kubectl delete pod -n kube-system $BAD_POD_NAME
        done
    fi
    WAIT_NS_PODS kube-system
}

SETUP_KUBECONFIG() {
    #export KUBECONFIG=/etc/kubernetes/admin.conf
    export ADMIN_KUBECONFIG=/etc/kubernetes/admin.conf

    mkdir -p /root/.kube
    cp -a $ADMIN_KUBECONFIG /root/.kube/config
    echo "root: kubectl get nodes:"
    kubectl get nodes

    mkdir -p /home/$END_USER/.kube
    cp -a $ADMIN_KUBECONFIG /home/$END_USER/.kube/config
    chown -R $END_USER:$END_USER /home/$END_USER/.kube

    echo "$END_USER: kubectl get nodes:"
    #sudo -u $END_USER KUBECONFIG=/home/$END_USER/.kube/config kubectl get nodes
    sudo -u $END_USER HOME=/home/$END_USER kubectl get nodes

    ls -altr /root/.kube/config /home/$END_USER/.kube/config | SECTION_LOG
}

KUBECTL_VERSION() {
    kubectl version -o yaml
    #{ echo "kubectl version: $(kubectl version --short)" | tr '\n' ',' | sed 's/,/ /g'; echo; } | SECTION_LOG
    { echo "kubectl version: $(kubectl version --short)" | tr '\n' ' '; echo; } | SECTION_LOG
}

CHANGE_KUBELET_LIMITS() {
    cp -a /var/lib/kubelet/config.yaml /var/lib/kubelet/config.yaml.orig
    sed -i.bak '/evictionPressureTransitionPeriod:/a evictionHard:\n\ \ imagefs.available: "5%"\n\ \ memory.available: "5%"\n\ \ nodefs.available: "5%"\n\ \ nodefs.inodesFree: "5%"' /var/lib/kubelet/config.yaml
    diff -C 2 /var/lib/kubelet/config.yaml.orig /var/lib/kubelet/config.yaml
    systemctl daemon-reload
    systemctl restart kubelet
    ps -fade | grep -v grep | grep -v apiserver | grep kubelet || {
        set -x
        echo "FAILED to change kubelet limits"
        cp -a /var/lib/kubelet/config.yaml.orig /var/lib/kubelet/config.yaml
        systemctl daemon-reload
        systemctl restart kubelet
    } | SECTION_LOG
    ps -fade | grep -v grep | grep -v apiserver | grep kubelet || {
        echo "FAILED to reset kubelet limits"
    } | SECTION_LOG
}

INSTALL_JUPYTER() {
    JUPYTER_INSTALL_URL="${RAWREPO_URL}/master/INSTALL_JUPYTER.sh "

    wget -O /tmp/INSTALL_JUPYTER.sh $JUPYTER_INSTALL_URL
    chmod +x /tmp/INSTALL_JUPYTER.sh
    /tmp/INSTALL_JUPYTER.sh
}

INSTALL_KUBELAB() {
    CHANGE_KUBELET_LIMITS
    /tmp/kubelab.sh
}

CREATE_INSTALL_KUBELAB() {
    cat > /tmp/kubelab.sh << EOF

die() { echo "\$0: die - \$*" >&2; exit 1; }

[ \$(id -un) != 'root' ] && die "Must be run as root"

set -x

mkdir -p /root/github.com
git clone https://github.com/mjbright/kubelab /root/github.com/kubelab

# Create modified config.kubelab
# - needed so kubectl in cluster will use 'default' namespace not 'kubelab':

export KUBECONFIG=/etc/kubernetes/admin.conf

sed -e '/user: kubernetes-admin/a \ \ \ \ namespace: default' < /home/$END_USER/.kube/config  > /home/$END_USER/.kube/config.kubelab
chown $END_USER:$END_USER /home/$END_USER/.kube/config.kubelab

# Mount new kubeconfig as a ConfigMap/file:
kubectl create ns kubelab
kubectl -n kubelab create configmap kube-configmap --from-file=/home/$END_USER/.kube/config.kubelab

kubectl create -f /root/github.com/kubelab/kubelab.yaml

kubectl -n kubelab get cm
kubectl -n kubelab get pods -o wide | grep " Running " || sleep 10
kubectl -n kubelab get pods -o wide | grep " Running " || sleep 10
kubectl -n kubelab get pods -o wide | grep " Running " || sleep 10

kubectl -n kubelab cp /root/.jupyter.profile kubelab:.profile

SECTION_LOG=/tmp/SECTION.log

SECTION_LOG() {
    if [ -z "$1" ]; then
        tee -a ${SECTION_LOG}
    else
        echo "$*" >> ${SECTION_LOG}
    fi
}

kubectl -n kubelab get pods | SECTION_LOG

POD_SPEC="-n kubelab"
BAD_PODS=$(kubectl get pods $POD_SPEC --no-headers | grep -v Running | wc -l)
#WAIT_POD_RUNNING -n kubelab
while [ $BAD_PODS -ne 0 ]; do
    echo "Waiting for Pods [$POD_SPEC] to be Running" | SECTION_LOG
    kubectl get pods $POD_SPEC
    BAD_PODS=$(kubectl get pods $POD_SPEC --no-headers | grep -v Running | wc -l)
    sleep 5
done

kubectl -n kubelab cp /root/.jupyter.profile kubelab:.jupyter.profile

{ kubectl -n kubelab get pods;
  df -h / | grep -v ^Filesystem; } |
    SECTION_LOG
EOF

    chmod +x /tmp/kubelab.sh
}

INSTALL_PRISMACLOUD() {

    MAX_LOOPS=10; LOOP=0;
    NFS_CHECK=/var/nfs/general/MOUNTED_from_NODE_worker

    while !  ls -altrh ${NFS_CHECK}* 2>/dev/null ; do
        echo "Waiting for worker nodes to mount NFS share ... ${NFS_CHECK}*"
        let LOOP=LOOP+1; sleep 30; [ $LOOP -ge $MAX_LOOPS ] && die "Failed waiting for $WORKER_NODE_NAME to mount NFS share"
    done
    ls -altr ${NFS_CHECK}* | SECTION_LOG

    {
        echo export PRISMACLOUD_TAR="$PRISMACLOUD_TAR";
        echo export PRISMACLOUD_ACCESS="$PRISMACLOUD_ACCESS";
    } > /root/tmp/PRISMACLOUD.vars

    #wget -O /tmp/INSTALL_PRISMACLOUD.sh $INSTALL_PRISMACLOUD_SH_URL
    #chmod +x /tmp/INSTALL_PRISMACLOUD.sh
    #/tmp/INSTALL_PRISMACLOUD.sh --init-console
    $SCRIPT_DIR/INSTALL_PRISMACLOUD.sh --init-console
}

INSTALL_HELM() {
    RELEASE="v3.1.2"
    TAR_GZ="/tmp/helm.${RELEASE}.tar.gz"
    URL="https://get.helm.sh/helm-${RELEASE}-linux-amd64.tar.gz"

    wget -qO $TAR_GZ $URL

    mkdir -p   $BIN
    tar xf $TAR_GZ -C $BIN --strip-components 1 linux-amd64/helm

    helm repo add stable https://kubernetes-charts.storage.googleapis.com/

    #helm search hub ingress-nginx
    #helm install hub stable/nginx-ingress
    #kubectl create ns nginx-ingress; helm install -n nginx-ingress hub stable/nginx-ingress

    #helm search hub redis
    #kubectl create ns redis
    #helm install -n redis hub stable/redis-ha

    #helm search hub traefik
    #helm install hub stable/traefik
    ls -altrh $BIN/helm | SECTION_LOG
}

INSTALL_TERRAFORM() {
    RELEASE="0.12.24"

    ZIP=/tmp/terraform.${RELEASE}.zip
    URL="https://releases.hashicorp.com/terraform/${RELEASE}/terraform_${RELEASE}_linux_amd64.zip"

    wget -qO $ZIP $URL

    mkdir -p   $BIN/
    unzip $ZIP -d $BIN terraform
    ls -altrh $BIN/terraform | SECTION_LOG
}

DOWNLOAD_PRISMACLOUD() {
    wget -qO $PRISMACLOUD_TAR $PRISMACLOUD_URL
    ls -altrh $PRISMACLOUD_TAR | SECTION_LOG
}

REGISTER_INSTALL_START() {
    wget -qO - "$REGISTER_URL/${EVENT}_${WORKSPACE}_${NODE_NAME}_${PUBLIC_IP}_provisioning_START"
}

REGISTER_INSTALL_END() {
    wget -qO - "$REGISTER_URL/${EVENT}_${WORKSPACE}_${NODE_NAME}_${PUBLIC_IP}_provisioning_END"
}

KUBE_RECORD_POD_STARTUP_EVENTS() {
    #for NAME in $(kubectl get pods -n kube-system --no-headers | awk '{ print $1; }'); do kubectl describe -n kube-system pod/$NAME | sed -e "s?^Events:?Events: kube-system/$NAME?" | grep -A 10 Events: ; done
    #for NAME in $(kubectl get pods -n $NS --no-headers | awk '{ print $1; }'); do kubectl describe -n $NS pod/$NAME | sed -e "s?^Events:?Events: $NS/$NAME?" | grep -A 10 Events: ; done

    NS=kube-system

    for NAME in $(kubectl get pods -n $NS --no-headers | awk '{ print $1; }'); do
        echo
        kubectl get      -n $NS pod/$NAME
        kubectl describe -n $NS pod/$NAME | sed -e "s?^Events:?Events: $NS/$NAME?" | grep -A 10 Events:
    done | tee /tmp/${NS}.Pods.Events.log
}

INSTALL_KUBERNETES() {
    case $K8S_INSTALLER in
        "kubeadm")
            SECTION KUBEADM_INIT
            SECTION SETUP_KUBECONFIG
            SECTION KUBEADM_POST_INIT
            SECTION CNI_INSTALL
            SECTION KUBEADM_JOIN
            SECTION KUBECTL_VERSION
            SECTION KUBE_RECORD_POD_STARTUP_EVENTS
        ;;
        "rancher")
            SECTION RANCHER_INIT
        ;;
        *)
        ;;
    esac
}

# Setup NFS share across nodes
# - https://www.digitalocean.com/community/tutorials/how-to-set-up-an-nfs-mount-on-ubuntu-18-04
CONFIGURE_NFS() {
    NODE_TYPE=$1; shift

    echo "Firewall(ufw status): $( ufw status )"

    NFS_CHECK_MASTER=/nfs/general/MOUNTED_from_NODE_master.txt

    case $NODE_TYPE in
        master)
            mkdir -p /var/nfs/general /nfs
            chown nobody:nogroup /var/nfs/general

            # for WIP in $WORKER_PRIVATE_IPS; do
            for WORKER in $(seq $NUM_WORKERS); do
                WORKER_NODE_NAME="${WORKER_PREFIX}$WORKER"
                grep -q $WORKER_NODE_NAME /etc/exports || echo "/var/nfs/general    $WORKER_NODE_NAME(rw,sync,no_subtree_check)" | tee -a /etc/exports
            done
            #EACH_WORKER_NODE echo '/var/nfs/general    $WORKER_NODE_NAME\(rw,sync,no_subtree_check\)' | tee -a /etc/exports
            grep '/var/nfs/general' /etc/exports | SECTION_LOG
            #for WORKER in $(seq $NUM_WORKERS); do
            #    #echo "/var/nfs/general    $WIP(rw,sync,no_subtree_check)"
            #    WORKER_NODE_NAME="${WORKER_PREFIX}$WORKER"
            #    echo "/var/nfs/general    $WORKER_NODE_NAME(rw,sync,no_subtree_check)"
            #    #/home       $PIP(rw,sync,no_root_squash,no_subtree_check)
            #done | tee -a /etc/exports

            systemctl restart nfs-kernel-server
            exportfs -a
            ln -s /var/nfs/general /nfs/

            date >> $NFS_CHECK_MASTER
            df -h     /var/nfs/general | SECTION_LOG
            ls -altrh /var/nfs/general | SECTION_LOG
            ;;
        *)
            mkdir -p /nfs/general

            mount master:/var/nfs/general /nfs/general
            MAX_LOOPS=10; LOOP=0;
            while [ ! -f $NFS_CHECK_MASTER ] ; do
                echo "Waiting for master node to initialize NFS share ...  $NFS_CHECK_MASTER"
                let LOOP=LOOP+1; sleep 30; [ $LOOP -ge $MAX_LOOPS ] && die "Failed waiting to mount share"
                mount master:/var/nfs/general /nfs/general
            done

            date >> /nfs/general/MOUNTED_from_NODE_$(hostname).txt
            df -h | grep /nfs/     | SECTION_LOG
            ls -alrh /nfs/general/ | SECTION_LOG
            ;;
    esac
}

SHOWCMD() {
    CMD="$*"
    echo "-- $CMD"
    $CMD
    RET=$?
    [ $RET -ne 0 ] && echo "--> returned $RET"
}

WAIT_NS_PODS() {
    NS=$1; shift

    BAD_PODS=$(kubectl get pods -n $NS --no-headers | grep -v Running | wc -l)
    MAX_LOOPS=20; LOOP=0;
    while [ $BAD_PODS -ne 0 ]; do
        echo "Waiting for remaining (ns:$NS) Pods to be running" | SECTION_LOG
        let LOOP=LOOP+1; sleep 12; [ $LOOP -ge $MAX_LOOPS ] && die "Failed waiting for remaining Pods"

        kubectl get pods -n $NS --no-headers | grep -v Running | SECTION_LOG
        BAD_PODS=$(kubectl get pods -n $NS --no-headers | grep -v Running | wc -l)

        # Show status of none-Running Pods:
        BAD_PODS_NAME=$(kubectl get pods -n $NS --no-headers | grep -v Running | awk '{ print $1; }')
        for BAD_POD_NAME in $BAD_PODS_NAME; do
            kubectl describe pod -n $BAD_POD_NAME | grep -A 10 Events:
        done
    done
    BAD_PODS=$(kubectl get pods -n $NS --no-headers | grep -v Running | wc -l)
}

FINISH() {
    SHOWCMD kubectl get pods -A | SECTION_LOG
    SHOWCMD kubectl get ns      | SECTION_LOG
    SHOWCMD kubectl describe nodes > /tmp/nodes.describe.txt

    SSH_EACH_WORKER_NODE 'echo $(hostname; df -h / | grep -v ^Filesystem)' | SECTION_LOG

    kubectl get pods -A --no-headers | grep -v Running
    kubectl get pods -A --no-headers | grep Evicted &&
            die "Error - some evicted Pods"

    #kubectl get pods -A -o json | jq '.items[] | select(.status.reason!=null)'
    #kubectl get pods -A -o json | jq '.items[] | select(.status.reason!=null)'  | grep Evicted &&
            #die "Error - some evicted Pods"
    #BAD_PODS=$(kubectl get pods -A -o json | jq '.items[] | select(.status.reason!=null)' | wc -l)

    BAD_PODS=$(kubectl get pods -A --no-headers | grep -v Running | wc -l)
    MAX_LOOPS=20; LOOP=0;
    while [ $BAD_PODS -ne 0 ]; do
        echo "Waiting for remaining Pods to be running" | SECTION_LOG
        let LOOP=LOOP+1; sleep 12; [ $LOOP -ge $MAX_LOOPS ] && die "Failed waiting for remaining Pods"

        #kubectl get pods -A -o json | jq '.items[] | select(.status.reason!=null)'
        #BAD_PODS=$(kubectl get pods -A -o json | jq '.items[] | select(.status.reason!=null)' | wc -l)
        kubectl get pods -A --no-headers | grep -v Running | SECTION_LOG
        BAD_PODS=$(kubectl get pods -A --no-headers | grep -v Running | wc -l)

        # Show status of none-Running Pods:
        BAD_PODS_NS_AND_NAME=$(kubectl get pods -A --no-headers | grep -v Running | awk '{ print $1, $2; }')
        for BAD_POD_NS_AND_NAME in $BAD_PODS_NS_AND_NAME; do
            kubectl describe pod -n $BAD_POD_NS_AND_NAME | grep -A 10 Events:
        done
    done

    scp worker1:/tmp/SECTION.log /tmp/SECTION.log.worker1

    {
      echo; echo "----"; kubectl get pods -n twistlock; kubectl get pods -n kubelab
      echo; echo "----"; echo "Connect to Console at [cat /tmp/PCC.console.url]:"; cat /tmp/PCC.console.url
      df -h / | grep -v ^Filesystem;
      SSH_EACH_WORKER_NODE 'echo $(hostname; df -h / | grep -v ^Filesystem)' | SECTION_LOG
      wc -l /tmp/SECTION.log*;

      kubectl describe nodes | grep -iE "^(  name:|taint:)" | SECTION_LOG

      CHECK_FINISH_STATE
    } | SECTION_LOG
}

WAIT_POD_RUNNING() {
    POD_SPEC=$*
    # eg. -A
    # -n <namespace>
    # -n <namespace> podname
    # -n <namespace> -l LABEL=VALUE

    BAD_PODS=$(kubectl get pods $POD_SPEC --no-headers | grep -v Running | wc -l)
    kubectl get pods $POD_SPEC

    MAX_LOOPS=10; LOOP=0;
    while [ $BAD_PODS -ne 0 ]; do
        echo "Waiting for Pods [$POD_SPEC] to be Running" | SECTION_LOG

        let _MOD=${LOOP}%3; [ $_MOD -eq 0 ] &&
        kubectl describe pods $POD_SPEC 2>/dev/null |& grep -A 20 ^Events:
        let LOOP=LOOP+1; sleep 12; [ $LOOP -ge $MAX_LOOP ] && die "Failed waiting for Pods [$POD_SPEC]"

        #kubectl get pods -A -o json | jq '.items[] | select(.status.reason!=null)'
        #BAD_PODS=$(kubectl get pods -A -o json | jq '.items[] | select(.status.reason!=null)' | wc -l)
        kubectl get pods $POD_SPEC --no-headers | grep -v Running | SECTION_LOG
        BAD_PODS=$(kubectl get pods $POD_SPEC --no-headers | grep -v Running | wc -l)
    done
}

# Safer version of apt-get when locking is blocking us:
safe_apt_get() {
    set -x; apt-get $*; RET=$?; set +x

    local _MAX_LOOP=12
    while [ $RET -ne 0 ]; do
        for lock in /var/lib/dpkg/lock*; do
            echo "lsof $lock:"; lsof $lock
        done

        sleep 10
        let _MAX_LOOP=_MAX_LOOP-1
        [ $_MAX_LOOP -le 0 ] && { echo "Failed apt-get $* ... continuing"; return 1; }
        set -x; apt-get $*; RET=$?; set +x
    done
    return 0
}

## Main START ---------------------------------------------------------------------------

. $SCRIPT_DIR/INSTALL_PROFILES.fn.rc

TIMER_START

INIT_SHELL_PROFILE_HISTORY

## -- Get node/event info --------------------------------------
SECTION_LOG "PUBLIC_IP=$PUBLIC_IP"

[ -z "$API_KEY"           ] && die "API_KEY is unset"
[ -z "$ORG_ID"            ] && die "ORG_ID is unset"
[ -z "$OWNER_ID_OR_EMAIL" ] && die "OWNER_ID_OR_EMAIL is unset"

[ -z "$PRIVATE_IP"        ] && die "PRIVATE_IP is unset"
[ -z "$PUBLIC_IP"         ] && die "PUBLIC_IP is unset"

echo "Checking for Events owned by '$OWNER_ID_OR_EMAIL'"
set_EVENT_WORKSPACE_NODES
[ -z "$USER_EMAIL" ]        && die "USER_EMAIL is unset"

## -- Set install profile --------------------------------------

SETUP_INSTALL_PROFILE
SET_MISSING_DEFAULTS

CREATE_USER $END_USER
INSTALL_GITHUB_REPOS $END_USER /home/$END_USER/src/github.com $GITHUB_REPOS

## -- Start install --------------------------------------------
[ ! -z "$REGISTER_URL"    ] && SECTION REGISTER_INSTALL_START

APT_INSTALL_PACKAGES="jq zip"

[ $ANSIBLE_INSTALL     -eq 1 ] && APT_INSTALL_PACKAGES+=" ansible ansible-lint ansible-tower-cli ansible-tower-cli-doc"
[ $UPGRADE_KUBE_LATEST -eq 1 ] && APT_INSTALL_PACKAGES+=" kubeadm kubelet kubectl"

SECTION START_DOCKER_plus
# SECTION GET_LAB_RESOURCES - CAREFUL THIS WILL EXPOSE YOUR API_KEY/ORG_ID

# Perform all kubeadm operations from Master1:
let NUM_WORKERS=NUM_NODES-NUM_MASTERS

if [ $NODE_IDX -eq 0 ] ; then
    [ $CONFIGURE_NFS   -ne 0 ]        && APT_INSTALL_PACKAGES+=" nfs-kernel-server"
    SECTION CONFIG_NODES_ACCESS_FROM_NODE0
else
    [ $CONFIGURE_NFS   -ne 0 ]        && APT_INSTALL_PACKAGES+=" nfs-common"
fi
safe_apt_get update
safe_apt_get upgrade -y
safe_apt_get install -y $APT_INSTALL_PACKAGES

if [ $NODE_IDX -lt $NUM_MASTERS ] ; then

    if [ $NODE_IDX -eq 0 ] ; then
        [ $CONFIGURE_NFS   -ne 0 ]        && SECTION CONFIGURE_NFS master on $NODE_NAME
        [ $INSTALL_KUBERNETES -ne 0 ]     && SECTION INSTALL_KUBERNETES
        [ $INSTALL_KUBELAB -ne 0 ]        && CREATE_INSTALL_KUBELAB
        [ $INSTALL_KUBELAB -ne 0 ]        && SECTION INSTALL_KUBELAB
        [ $INSTALL_JUPYTER -ne 0 ]        && SECTION INSTALL_JUPYTER

        [ $DOWNLOAD_PRISMACLOUD -ne 0 ]   && SECTION DOWNLOAD_PRISMACLOUD
        [ $INSTALL_PRISMACLOUD -ne 0 ]    && SECTION INSTALL_PRISMACLOUD
        [ $INSTALL_TERRAFORM -ne 0 ]      && SECTION INSTALL_TERRAFORM
        [ $INSTALL_HELM -ne 0 ]           && SECTION INSTALL_HELM
    else
        while [ ! -f /tmp/NODE_NAME ]; do sleep 5; done
        [ $CONFIGURE_NFS -ne 0 ]          && SECTION CONFIGURE_NFS master on $(hostname)
    fi
else
    #[ $NUM_MASTERS -gt 1 ] && die "Not implemented NUM_MASTERS > 1" XXX??

    while [ ! -f /tmp/NODE_NAME ]; do sleep 5; done
    #NODE_NAME=$(cat /tmp/NODE_NAME)
    [ $CONFIGURE_NFS -ne 0 ]          && SECTION CONFIGURE_NFS worker on $(hostname)
fi

#echo "export PS1='\u@\h:\w\$'"
exp_PS1="export PS1='\u@'$(hostname)':\w\$ '"
echo "$exp_PS1" >> /home/$END_USER/.bashrc
echo "$exp_PS1" >> /root/.bashrc

[ ! -z "$REGISTER_URL" ] && SECTION REGISTER_INSTALL_END

[ $NODE_IDX -eq 0 ] && SECTION FINISH
TIMER_STOP "$0: " | SECTION_LOG
SECTION_LOG "$0: exit 0"

