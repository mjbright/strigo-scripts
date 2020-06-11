

USER_DATA_LOG=/root/tmp/user-data.op

[   -f ${USER_DATA_LOG}         ] && cp -a $USER_DATA_LOG ${USER_DATA_LOG}.$(date +'%Y-%m-%d_%H-%M-%S')
[ ! -f ${USER_DATA_LOG}.initial ] && [ -f $USER_DATA_LOG ] && mv $USER_DATA_LOG ${USER_DATA_LOG}.initial

bash -x /root/tmp/instance/user-data.txt > ${USER_DATA_LOG}.rerun 2>&1




