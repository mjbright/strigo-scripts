#!/bin/bash

HOSTNAME=$(hostname)

[ $HOSTNAME = "master" ] && kubectl get pods -A 

grep "====" /tmp/SECTION.log


