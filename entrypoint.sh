#!/bin/sh

send_cpu_usage () {

    NODE_NAME_DESC=$1
    CLUSTER=$2

    EC2_AVAIL_ZONE=`curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone`
    EC2_REGION="`echo \"$EC2_AVAIL_ZONE\" | sed 's/[a-z]$//'`"

    while [ 1 ]
        do
        TOTAL=$(kubectl describe nodes $NODE_NAME_DESC | grep -A 4 "Allocated resources" | tail -n 1 | awk '{print $2}' | tr -d '(,),%')
        MEM_TOTAL=$(kubectl describe nodes $NODE_NAME_DESC | grep -A 4 "Allocated resources" | tail -n 1 | awk '{print $6}' | tr -d '(,),%')
        /usr/bin/aws cloudwatch put-metric-data --region ${EC2_REGION} --metric-name CpuUsage --namespace k8s --unit None --value ${TOTAL} --dimensions ClusterName=${CLUSTER},NodeGroupName=${NODE_GROUP_NAME}
        /usr/bin/aws cloudwatch put-metric-data --region ${EC2_REGION} --metric-name MemoryUsage --namespace k8s --unit None --value ${MEM_TOTAL} --dimensions ClusterName=${CLUSTER},NodeGroupName=${NODE_GROUP_NAME}
        echo "Sending metric node ${NODE_NAME_DESC} value: ${TOTAL}"
        sleep 60
    done

}

# How to test:
#  NAMESPACE=default POD_NAME=kubesh-3976960141-b9b9t ./this_script

# Set VERBOSE=1 to get more output
VERBOSE=${VERBOSE:-0}
function verbose () {
  [[ ${VERBOSE} -eq 1 ]] && return 0 || return 1
}

echo 'This script polls the "EC2 Spot Instance Termination Notices" endpoint to gracefully stop and then reschedule all the pods running on this Kubernetes node, up to 2 minutes before the EC2 Spot Instance backing this node is terminated.'
echo 'See https://aws.amazon.com/blogs/aws/new-ec2-spot-instance-termination-notices/ for more information.'

if [ "${NAMESPACE}" == "" ]; then
  echo '[ERROR] Environment variable `NAMESPACE` has no value set. You must set it via PodSpec like described in http://stackoverflow.com/a/34418819' 1>&2
  exit 1
fi

if [ "${POD_NAME}" == "" ]; then
  echo '[ERROR] Environment variable `POD_NAME` has no value set. You must set it via PodSpec like described in http://stackoverflow.com/a/34418819' 1>&2
  exit 1
fi

NODE_NAME=$(kubectl --namespace ${NAMESPACE} get pod ${POD_NAME} --output jsonpath="{.spec.nodeName}")

if [ "${NODE_NAME}" == "" ]; then
  echo "[ERROR] Unable to fetch the name of the node running the pod \"${POD_NAME}\" in the namespace \"${NAMESPACE}\". Maybe a bug?: " 1>&2
  exit 1
fi

# Gather some information
AZ_URL=${AZ_URL:-http://169.254.169.254/latest/meta-data/placement/availability-zone}
AZ=$(curl -s ${AZ_URL})
INSTANCE_ID_URL=${INSTANCE_ID_URL:-http://169.254.169.254/latest/meta-data/instance-id}
INSTANCE_ID=$(curl -s ${INSTANCE_ID_URL})
if [ -z $CLUSTER ]; then
  echo "[WARNING] Environment variable CLUSTER has no name set. You can set this to get it reported in the Slack message." 1>&2
else
  CLUSTER_INFO=" (${CLUSTER})"
fi

echo "\`kubectl drain ${NODE_NAME}\` will be executed once a termination notice is made."

POLL_INTERVAL=${POLL_INTERVAL:-5}

NOTICE_URL=${NOTICE_URL:-http://169.254.169.254/latest/meta-data/spot/termination-time}

echo "Polling ${NOTICE_URL} every ${POLL_INTERVAL} second(s)"

#Loop send cpu
send_cpu_usage ${NODE_NAME} ${CLUSTER} &

# To whom it may concern: http://superuser.com/questions/590099/can-i-make-curl-fail-with-an-exitcode-different-than-0-if-the-http-status-code-i
while http_status=$(curl -o /dev/null -w '%{http_code}' -sL ${NOTICE_URL}); [ ${http_status} -ne 200 ]; do
  verbose && echo $(date): ${http_status}
  sleep ${POLL_INTERVAL}
done

echo $(date): ${http_status}
MESSAGE="Spot Termination${CLUSTER_INFO}: ${NODE_NAME}, Instance: ${INSTANCE_ID}, AZ: ${AZ}"

# Notify Hipchat
# Set the HIPCHAT_ROOM_ID & HIPCHAT_AUTH_TOKEN variables below.
# Further instructions at https://www.hipchat.com/docs/apiv2/auth
if [ "${HIPCHAT_AUTH_TOKEN}" != "" ]; then
  curl -H "Content-Type: application/json" \
     -H "Authorization: Bearer $HIPCHAT_AUTH_TOKEN" \
     -X POST \
     -d "{\"color\": \"purple\", \"message_format\": \"text\", \"message\": \"${MESSAGE}\" }" \
     https://api.hipchat.com/v2/room/$HIPCHAT_ROOM_ID/notification
fi

# Notify Slack incoming-webhook
# Docs: https://api.slack.com/incoming-webhooks
# Setup: https://slack.com/apps/A0F7XDUAZ-incoming-webhooks
#
# You will have to set SLACK_URL as an environment variable via PodSpec.
# The URL should look something like: https://hooks.slack.com/services/T67UBFNHQ/B4Q7WQM52/1ctEoFjkjdjwsa22934
#
if [ "${SLACK_URL}" != "" ]; then
  curl -X POST --data "payload={\"text\": \":warning: ${MESSAGE}\"}" ${SLACK_URL}
fi

# Drain the node.
# https://kubernetes.io/docs/tasks/administer-cluster/safely-drain-node/#use-kubectl-drain-to-remove-a-node-from-service
kubectl drain ${NODE_NAME} --force --ignore-daemonsets --delete-local-data

# Sleep for 300 seconds to prevent this script from looping.
# The instance should be terminated by the end of the sleep.
sleep 300
