#!/bin/bash


if [ $# -eq 0 ]
  then
    echo "Please supply the leader's username"
    exit 1
fi

RAW_MASTER_POD=$(kubectl get pods -n $1 | grep master)

if [ $? -eq 1 ]; then
	echo "Spark master isn't running! Please contact leader $1"
fi

MASTER_POD=$(echo $RAW_MASTER_POD | cut -d ' ' -f1)


stdbuf -o0 kubectl port-forward -n $1 --address 127.0.0.1 $MASTER_POD 0:8888 0:8080 0:4040 > port_forwarding  2>/dev/null &
PORT_FORWARD_PID=$!
sleep 2
temp=$(cat port_forwarding | wc -l)
while [ $temp != 3 ]
	do
		echo "here"
	    sync && sleep 2
            temp=$(cat port_forwarding | wc -l)
  	done

SPARK_MGR_PORT="$(cat port_forwarding | grep 8080 | grep 127.0.0.1 | awk '//{print $3}')"
SPARK_JOB_PORT="$(cat port_forwarding | grep 4040 | grep 127.0.0.1 | awk '//{print $3}')"
SSH_COMMAND="ssh -N -L 127.0.0.1:8080:$SPARK_MGR_PORT -L 127.0.0.1:4040:$SPARK_JOB_PORT $(whoami)@dsmlp-login.ucsd.edu"

echo ""
echo "========================================================================="
echo "=> Successfully connected to the Spark cluster"
echo "=> Next create a SSH tunnel from your personal computer using the following command:"
echo "        $SSH_COMMAND"
echo ""
echo "=> Link to Spark cluster manager UI: http://127.0.0.1:8080"
echo "=> Link to Spark job UI: http://127.0.0.1:4040"
echo "========================================================================="


trap 'kill $PORT_FORWARD_PID' INT
sleep inf
wait

echo "All port-forward processes have ended. Exiting.."
