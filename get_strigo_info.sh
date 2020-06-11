#!/bin/bash

DIR=$(dirname $0)

SSH_INIT_KEYS="-o StrictHostKeyChecking=no"

## -- usage: ----------------------------------------------------

# > ./get_strigo_info.sh nuaware_pcc_vars.rc -E
# eventId=YY4wZyFm6GyiD7EER status=live name=Untitled training event owner_email=michael.bright@nuaware.com
# eventId=2ZCXwpffECibjSLZB status=live name=Untitled training event owner_email=michael.bright@nuaware.com

# > ./get_strigo_info.sh nuaware_pcc_vars.rc --private-ip 172.31.10.64 -v -W
# eventId=jRLS35YPuBGdTYrJw
# workspaces={'result': 'success', 'data': [{'id': 'DAjXBsDJrW4NXRBiz', 'event_id': 'jRLS35YPuBGdTYrJw', 'created_at': '2020-06-04T08:24:59.267Z', 'type': 'student', 'owner': {'id': 'TQhtXqawCNLnMui2p', 'email': 'mjbrightfr@gmail.com'}, 'online_status': 'deprecated', 'last_seen': '2020-06-04T08:46:21.258Z', 'need_assistance': False}, {'id': 'g2NcRLH4J7T2TfYen', 'event_id': 'jRLS35YPuBGdTYrJw', 'created_at': '2020-06-04T08:21:41.786Z', 'type': 'host', 'owner': {'id': 'hX8PLJfBX4ojEKZxu', 'email': 'michael.bright@nuaware.com'}, 'online_status': 'deprecated', 'last_seen': '2020-06-04T09:03:23.029Z', 'need_assistance': False}]}
#
# > ./get_strigo_info.sh nuaware_pcc_vars.rc -W
# Traceback (most recent call last):
#   File "./get_strigo_info.py", line 223, in <module>
#       for w in workspaces['data']:
# 	      KeyError: 'data'

# > ./get_strigo_info.sh nuaware_pcc_vars.rc -IPS
# Traceback (most recent call last):
#   File "./get_strigo_info.py", line 276, in <module>
#     for ws_data in workspaces['data']:
#       KeyError: 'data'

## -- functions: ------------------------------------------------

die() {
    echo "$0: die - $*" >&2
    exit 1
}

## -- arguments: ------------------------------------------------

VERBOSE=""
SET_X=""
[ "$1" = "-v" ] && { VERBOSE="-v"; shift; }
[ "$1" = "-x" ] && { SET_X="-x"; set -x; shift; }

RCFILE=$1
shift

[ -z "$RCFILE"   ] && die "Usage: $0 <rcfile>"
[ ! -f "$RCFILE" ] && die "Usage: No such rcfile as <$RCFILE>"

export PRIVATE_IP="unset"
export PUBLIC_IP="unset"

# If running in an ec2 VM: assume the case if ec2metatdata present:
which ec2metadata >/dev/null 2>&1 && {
	# Check we're not running under WSL:
	uname -a | grep -q microsoft ||
	    export PRIVATE_IP=$(ec2metadata --local-ipv4) PUBLIC_IP=$(ec2metadata --public-ipv4)
}

# Allow to specify public or private ip to identify workspace (when running outside of EC2):
[ "$1" = "--private-ip" ] && { shift; export PRIVATE_IP="$1"; shift; }
[ "$1" = "--public-ip"  ] && { shift; export PUBLIC_IP="$1";  shift; }

. $RCFILE

# Canned ssh commands:
[ "$1" = "-tailsec"   ] && set -- -ssh tail /tmp/SECTION.log
[ "$1" = "-tailfsec"  ] && set -- -ssh tail -100f /tmp/SECTION.log
[ "$1" = "-tailuser"  ] && set -- -ssh tail /root/tmp/user-data.op
[ "$1" = "-tailfuser" ] && set -- -ssh tail -100f /root/tmp/user-data.op
[ "$1" = "-progress"  ] && set -- -ssh grep ==== /tmp/SECTION.log
[ "$1" = "-nodes"     ] && set -- -ssh0 kubectl get nodes
[ "$1" = "-pods"      ] && set -- -ssh0 kubectl get pods -A
[ "$1" = "-check"     ] && set -- -ssh sudo bash /root/tmp/strigo-scripts/check_cluster_status.sh

# Run on all nodes or just first node of each workspace:
SSH_ALL_NODES=1
if [ "$1" = "-ssh0" ]; then
    shift
    SSH_ALL_NODES=0
    set -- -ssh $*
fi

if [ "$1" = "-ssh" ]; then
    shift;

    [ ! -f $SSH_KEY ] && SSH_KEY=~/.ssh/id_rsa
    echo SSH_KEY=$SSH_KEY

    #cat > /tmp/XX <<EOF
    #workspaceId=zB4dyyJJPgE5RfiKS event_id=YY4wZyFm6GyiD7EER owner_email=michael.bright@nuaware.com created_at=2020-06-03T13:17:26.570Z
      #lab_id=FvHiScXeNxWmjAX2A private_ip=$172.31.7.120 public_ip=52.59.139.110
      #lab_id=dRYBKAaCZwF47T8YE private_ip=$172.31.11.229 public_ip=18.184.148.110
#EOF

    # Get IP addresses of nodes:
    for IP_INFO in $($DIR/get_strigo_info.py -set-le -IPS ); do
    #for IP_INFO in $(cat /tmp/XX); do
	[ "${IP_INFO#workspaceId}" != "$IP_INFO" ] && {
            WORKSPACE="${IP_INFO#workspace}"
	    NODE_IDX=-1
        }
	[ "${IP_INFO#private_ip}" != "$IP_INFO" ] && {
	    echo "workspace$WORKSPACE: $IP_INFO"
	}
	[ "${IP_INFO#public_ip}" != "$IP_INFO" ] && {
	    IP="${IP_INFO#public_ip=}"
	    let NODE_IDX=NODE_IDX+1

	    #echo "[ $SSH_ALL_NODES -eq 0 ] && [ $NODE_IDX -ne 0 ] && continue ($IP)"
	    # 0-th node or all nodes:
            [ $SSH_ALL_NODES -eq 0 ] && [ $NODE_IDX -ne 0 ] && continue

	    echo "workspace$WORKSPACE: ${IP}"

	    if [ -z "$1" ]; then
                set -x;
	        ssh $SSH_INIT_KEYS -qt -i $SSH_KEY ubuntu@$IP uptime
	    else
                set -x;
	        ssh $SSH_INIT_KEYS -qt -i $SSH_KEY ubuntu@$IP "$*"
	    fi
	}
        #echo "LINE: $IP_INFO"
    done
    exit
fi

#ARGS="$VERBOSE -oem $OWNER_ID_OR_EMAIL"

#$DIR/get_strigo_info.py $ARGS $*
$DIR/get_strigo_info.py $*

