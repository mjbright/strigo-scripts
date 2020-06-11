#!/bin/bash

## -- functions: ------------------------------------------------

die() {
    echo "$0: die - $*" >&2
    exit 1
}

## -- arguments: ------------------------------------------------

RCFILE=$1

[ -z "$RCFILE"   ] && die "Usage: $0 <rcfile>"
[ ! -f "$RCFILE" ] && die "Usage: No such rcfile as <$RCFILE>"

#TEMPFILE=$(tempfile).vars
#[ -f $TEMPFILE ] && rm -f $TEMPFILE

. $RCFILE

[ -z "$IP_TEMPLATE" ] && die "Input IP_TEMPLATE file unset"
[ -z "$OP_PRIVATE" ]  && die "Output OP_PRIVATE file unset"

## -- main: -----------------------------------------------------

#VARS="CLASSID ORG_ID API_KEY OWNER_ID_OR_EMAIL PRISMA_PCC_ACCESS PRISMA_PCC_LICENSE REGISTER_URL"
VARS="CLASSID ORG_ID API_KEY OWNER_ID_OR_EMAIL REGISTER_URL"

USE_SED1() {
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

    #echo
    #echo "sed '<commands>' < $IP_TEMPLATE >> $OP_PRIVATE"
    echo
    echo $CMD
    eval $CMD < $IP_TEMPLATE >> $OP_PRIVATE
}

USE_SED2() {
    cat <(sed '1,/__VARSFILE_RC__/d' < $IP_TEMPLATE) | wc -l
    cat <(sed '/__VARSFILE_RC__/,$d' < $IP_TEMPLATE) | wc -l
    wc -l $RCFILE
    # NO END RC BEG: cat <(sed '1,/__VARSFILE_RC__/d' < $IP_TEMPLATE) $RCFILE <(sed '/__VARSFILE_RC__/,$d' < $IP_TEMPLATE) >> $OP_PRIVATE
    cat <(sed '/__VARSFILE_RC__/,$d' < $IP_TEMPLATE) $RCFILE <(sed '1,/__VARSFILE_RC__/d' < $IP_TEMPLATE) >> $OP_PRIVATE
    wc -l $OP_PRIVATE
    echo "Press <enter>"
    read
    #exit 0
}

cp   /dev/null        $OP_PRIVATE
echo '#!/bin/bash' >> $OP_PRIVATE
echo               >> $OP_PRIVATE
#cat $RCFILE        >> $OP_PRIVATE

#[ -f $TEMPFILE ] && cat $TEMPFILE >> $OP_PRIVATE
#USE_SED1
USE_SED2

#
#echo
grep __ $OP_PRIVATE && die "ERROR: variable not replaced in $OP_PRIVATE"

echo
diff        $IP_TEMPLATE   $OP_PRIVATE

echo
#ls -altr $IP_TEMPLATE $OP_PRIVATE $TEMPFILE
wc -l $IP_TEMPLATE $OP_PRIVATE $TEMPFILE

#[ -f $TEMPFILE ] && rm -f $TEMPFILE
exit 0

> export CLASSID="__CLASSID__"
> export ORG_ID="__ORG_ID__"
> export API_KEY="__API_KEY__"
> export OWNER_ID_OR_EMAIL="__OWNER_ID_OR_EMAIL__"
> export PRISMA_PCC_ACCESS="__PRISMA_PCC_ACCESS__"
> export REGISTER_URL="__REGISTER_URL__"
