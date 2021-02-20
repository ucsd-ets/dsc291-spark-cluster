#!/bin/bash
K8S_GROUPNAME=$2
. /software/common64/dsmlp/bin/kubevars.sh

# sets K8S_GID
get_gid () {

        K8S_TOK=$(kubectl config view --minify=true -o jsonpath='{.users[0].user.token}')

        echo -n "Fetching group membership... " >&2
JSON=$(curl -K - <<EOM
silent
header = "Authorization: AWSEd api_key=${K8S_TOK}"
url = https://awsed.ucsd.edu/api/teams?username=${K8S_USERNAME}
EOM
)
	echo "Done" >&2
	if [ -z "$K8S_GROUPNAME" ]; then
		NUMGROUPS=$( echo "$JSON" | jq '.teams | length' )
        	if [[ $NUMGROUPS == "0" || $NUMGROUPS == "" ]]; then
                	K8S_GROUPNAME=none
 			echo "No groups found. Please join a group in Canvas."
			exit 1
		elif [[ $NUMGROUPS == "1" ]]; then
			K8S_GROUPNAME=$( echo "$JSON" | jq -r '.teams[0].teamName' )
		else
			echo "$0: You are a member of $NUMGROUPS groups.  Please specify your desired group as the second argument on the command line"
			echo "Your groups:"
			echo "$JSON" | jq -r '.teams[] | .teamName'
			exit 1
		fi
	fi

        if [ "$K8S_GROUPNAME" != "none" ]; then
                MATCHES=$( echo "$JSON" | jq -r "[.teams[] | [ select(.teamName == \"$K8S_GROUPNAME\") ] | length] | add" )
                if [[ $MATCHES != 1 ]]; then
                        echo "$0: Group "$K8S_GROUPNAME" not found.  Please specify your desired group on the command line as argument 2"
                        echo "Your groups:"
                        echo "$JSON" | jq -r '.teams[] | .teamName'
                        exit 1
            	fi

            	K8S_GID=$( echo "$JSON" | jq -r ".teams[] | select(.teamName == \"$K8S_GROUPNAME\") | .gid" )
            	export K8S_EXTRA_SECURITY_CONTEXT=$( (echo ''; echo -n "    runAsGroup: ${K8S_GID}" ) | base64)
        fi
}


BASEDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
if [ "$#" -ge 1 ] && [ $1 == 'create' ]; then
        get_gid
	JUPYTER_TOKEN=$(openssl rand -hex 16)
	# Keeping this for 3. We cannot go beyond 3
	NUM_WORKERS=3
	cat $BASEDIR/spark-cluster-group.yaml.template | sed -e "s/\$JUPYTER_TOKEN/$JUPYTER_TOKEN/" -e "s/\$NUM_WORKERS/$NUM_WORKERS/" -e "s/\$K8S_GID/$K8S_GID/"  -e "s/\$K8S_UID/$K8S_UID/" -e "s/\$K8S_USERNAME/$K8S_USERNAME/" > $BASEDIR/spark-cluster.yaml
	echo $JUPYTER_TOKEN > $BASEDIR/jupyter_token
	status=$(cat $BASEDIR/spark-cluster.yaml | kubectl create -f - 2>&1 | grep Error)
	if [[ "$status" == *"Error"* ]]; then
	    echo $status
	    exit -1
        fi

	sleep 5
	kubectl get pods
	status="$(kubectl get pods 2>&1 | awk '/spark-/ {print $3}')"
	while [[ $status == *'ContainerCreating'* ]]
        do
            sleep 5
	    kubectl get pods
	    status="$(kubectl get pods 2>&1 | awk '/spark-worker/ {print $3}')"
        done

	MASTER_POD="$(kubectl get pods 2>&1 | awk '/spark-master/ {print $1}')"
	
	stdbuf -o0 kubectl port-forward --address 127.0.0.1 $MASTER_POD 0:8888 0:8080 0:4040 > $BASEDIR/port_forwarding  2>/dev/null &
	sleep 2
	temp=$(cat $BASEDIR/port_forwarding | wc -l)
	while [ $temp != 3 ]
	do
	    sync && sleep 2
            temp=$(cat $BASEDIR/port_forwarding | wc -l)
        done

	JUPYTER_PORT="$(cat $BASEDIR/port_forwarding | grep 8888 | grep 127.0.0.1 | awk '//{print $3}')"
        SPARK_MGR_PORT="$(cat $BASEDIR/port_forwarding | grep 8080 | grep 127.0.0.1 | awk '//{print $3}')"
	SPARK_JOB_PORT="$(cat $BASEDIR/port_forwarding | grep 4040 | grep 127.0.0.1 | awk '//{print $3}')"

	SSH_COMMAND="ssh -N -L 127.0.0.1:8888:$JUPYTER_PORT -L 127.0.0.1:8080:$SPARK_MGR_PORT -L 127.0.0.1:4040:$SPARK_JOB_PORT $(whoami)@dsmlp-login.ucsd.edu"

	echo ""
	echo "========================================================================="
	echo "=> Successfully initiated the Spark cluster"
	echo "=> Next create a SSH tunnel from your personal computer using the following command:"
        echo "        $SSH_COMMAND"
	echo ""
	echo "=> Link to PySpark/Jupyter UI: http://127.0.0.1:8888?token=$JUPYTER_TOKEN"
	echo "=> Link to Spark cluster manager UI: http://127.0.0.1:8080"
	echo "=> Link to Spark job UI: http://127.0.0.1:4040"
        echo "========================================================================="
elif [ $# -eq 1 ] && [ $1 == 'delete' ]; then
	process=$(ps u | grep port-forward | grep spark-master | awk '//{print $2}')
	if [ $process ]; then
            kill -9 $process
	fi

	kubectl delete -f $BASEDIR/spark-cluster-group.yaml.template
        sleep 5
        status="$(kubectl get pods 2>&1 | awk '/Terminating/ {print $3}')"
	while [[ $status == *'Terminating'* ]]
        do
            sleep 5
            kubectl get pods
            status="$(kubectl get pods 2>&1 | awk '/Terminating/ {print $3}')"
        done
        echo "========================================================================="
        echo "=> Successfully stopped the Spark cluster"
        echo "========================================================================="
elif [ $# -eq 1 ] && [ $1 == 'port-forward' ]; then
        MASTER_POD="$(kubectl get pods 2>&1 | awk '/spark-master/ {print $1}')"
        if [ $MASTER_POD ]; then
            process=$(ps u | grep port-forward | grep spark-master | awk '//{print $2}')
            if [ $process ]; then
                kill -9 $process
            fi
	    
            stdbuf -o0 kubectl port-forward --address 127.0.0.1 $MASTER_POD 0:8888 0:8080 0:4040 > $BASEDIR/port_forwarding 2> /dev/null &
            #sleep 2
            temp=$(cat $BASEDIR/port_forwarding | wc -l)
            while [ $temp != 3 ]
            do
                sync && sleep 2
                temp=$(cat $BASEDIR/port_forwarding | wc -l)
            done

	    JUPYTER_PORT="$(cat $BASEDIR/port_forwarding | grep 8888 | grep 127.0.0.1 | awk '//{print $3}')"
            SPARK_MGR_PORT="$(cat $BASEDIR/port_forwarding | grep 8080 | grep 127.0.0.1 | awk '//{print $3}')"
            SPARK_JOB_PORT="$(cat $BASEDIR/port_forwarding | grep 4040 | grep 127.0.0.1 | awk '//{print $3}')"

            SSH_COMMAND="ssh -N -L 127.0.0.1:8888:$JUPYTER_PORT -L 127.0.0.1:8080:$SPARK_MGR_PORT -L 127.0.0.1:4040:$SPARK_JOB_PORT $(whoami)@dsmlp-login.ucsd.edu"

            echo ""
            echo "========================================================================="
            echo "=> Port forwarded successfully"
            echo "=> Next create a SSH tunnel from your personal computer using the following command:"
            echo "        $SSH_COMMAND"
            echo "========================================================================="
         else
	    echo ""
            echo "========================================================================="
            echo "=> No spark cluster running"
            echo "=> To start a cluster run: cluster_manager.sh create"
            echo "========================================================================="
	 fi
else
    echo 'Valid arguments are: create, delete, and port-forward'
fi

