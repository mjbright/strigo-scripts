#!/bin/bash

die() { echo "$0: die - $*" >&2; exit 1; }

cd $(dirname $0)

[   -z "$1" ] && die "Missing rc file argument"
[ ! -f "$1" ] && die "No such rc file <$1>"
RCFILE=$1

# Get eventId
echo "Searching for eventId of latest event:"
EVENTID=$(./get_strigo_info.sh $RCFILE -set-le -e 2>/dev/null | tail -1)

echo "eventId=$EVENTID"

echo "Building ssh_config_$EVENTID file"
set -x
./get_strigo_info.sh $RCFILE -set-e $EVENTID -ssh_config $SSH_KEY 2>/dev/null | tee ssh_config_$EVENTID
ls -al ssh_config_$EVENTID

exit 0


