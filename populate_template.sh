#!/bin/bash

die() {
    echo "$0: die - $*" >&2
    exit 1
}

[ -z "$1"   ] && die "Usage: $0 <rcfile>"
[ ! -f "$1" ] && die "Usage: No such rcfile as <$1>"

. $1

VARS="CLASSID ORG_ID API_KEY OWNER_ID_OR_EMAIL PRISMA_PCC_ACCESS REGISTER_URL"

CMD="sed"
for VAR in $VARS; do
    eval VAL=\$$VAR
    # Works only for separate export lines:
    #CMD+=" -e 's?^ $VAR=\"[^\"]*\"?export $VAR=\"$VAL\"?'"

    # Works for single export line, but more complicated
    #CMD+=" -e 's? $VAR=\"[^\"]*\"? $VAR=\"$VAL\"?'"

    # Works for single export line, simpler
    CMD+=" -e 's?__${VAR}__?$VAL?'"
done

echo $CMD

eval $CMD < user_data.sh.TEMPLATE > user_data.sh.PRIVATE
grep __ user_data.sh.PRIVATE && die "ERROR: variable not replaced"
diff        user_data.sh.TEMPLATE   user_data.sh.PRIVATE
exit 0

> export CLASSID="__CLASSID__"
> export ORG_ID="__ORG_ID__"
> export API_KEY="__API_KEY__"
> export OWNER_ID_OR_EMAIL="__OWNER_ID_OR_EMAIL__"
> export PRISMA_PCC_ACCESS="__PRISMA_ACCESS_KEY__"
> export REGISTER_URL="__REGISTER_URL__"
