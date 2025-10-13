#!/bin/bash

echo "Starting/Restarting BSCF..."
echo "Killing any existing process..."
pkill -f 'script/bscf'

echo "Checking if dependencies need to be updated..."
cpanm --installdeps -n .

PWD=`pwd`
STDOUT_LOG=../logs/bscf_server.log

echo "Starting BSCF..."
nohup ${PWD}/script/bscf >> $STDOUT_LOG 2>&1 &

echo "BSCF startup complete."
