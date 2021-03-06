#!/bin/bash

workers()
{
  aws ec2 describe-instances \
    --filters "Name=tag:cms_id,Values=${CLUSTER_ID}" "Name=tag:role,Values=worker" \
    --query 'Reservations[].Instances[].PublicIpAddress'
}

create_key_material()
{
  if ! shred -z -n5 -u "${KEYFILE}" 2>/dev/null
  then
    if -f "${KEYFILE}"
    then
      if ! rm -rf "${KEYFILE}" 2>/dev/null
      then
        echo >&2 "Unable to remove existing keyfile: ${KEYFILE}"
        return 55
      fi
    fi
  fi

  if ! touch "${KEYFILE}"; then
    echo >&2 "Unable to create (touch) new keyfile: ${KEYFILE}"
    return 65
  else
    if ! chmod 0600 "${KEYFILE}"; then
      echo >&2 "Unable to chmod 0600 ${KEYFILE}"
      return 60
    fi
  fi

  aws ec2 create-key-pair         \
    --key-name "${CLUSTER_ID}Key" \
    --query 'KeyMaterial'         \
    --output text >> "${KEYFILE}"
}

create_machines_yaml()
{
  # shellcheck disable=SC1091
  . ./configure > "${OUTDIR}/machines-$(date +%Y%m%dT%H%M%S).yaml"
}

[[ ! -x $(which jq) ]] && \
  {
    echo >&2 "Please install 'jq'. It is required for this script to work."
    exit 25
  }

if [ -z "${CLUSTER_ID}" ]; then
    echo "CLUSTER_ID must be set. Hint: export CLUSER_ID=<cluster_id>"
    exit 1
fi

if [ -z "${AVAILABILITY_ZONE}" ]; then
    echo "AVAILABILITY_ZONE must be set"
    exit 1
fi

# courtesy of SO (/questions/630372/determine-the-path-of-the-executing-bash-script)
BASEDIR=$(cd -P -- "$(dirname -- "$0")" && pwd -P)
OUTDIR=${BASEDIR}/out
INSTANCE_TYPE=${INSTANCE_TYPE:-m4.large}
DISK_SIZE_GB=${DISK_SIZE_GB:-40}
SSH_LOCATION=${SSH_LOCATION:-0.0.0.0/0}
K8S_NODE_CAPACITY=${K8S_NODE_CAPACITY:-1}
KEYFILE=${KEYFILE:-$HOME/.ssh/${CLUSTER_ID}Key.pem}
INSTANCE_OS_NAME=${INSTANCE_OS_NAME:-centos}
CLUSTER_USERNAME=${CLUSTER_USERNAME:-$INSTANCE_OS_NAME}
INSTANCE_OS_VER=${INSTANCE_OS_VER:-7.4}
CLUSTER_TEMPLATE="cluster-${INSTANCE_OS_NAME}-${INSTANCE_OS_VER}-cf.template"
CREATED=$(mktemp)
S_TIME=2

export CMS_ID=${CLUSTER_ID} SSH_USER=${CLUSTER_USERNAME}

if ! create_key_material; then
    echo >&2 """
    Unable to create key material. Was it already created? If so, this can likely be ignored.

    To delete the AWS key use the command:
    aws ec2 delete-key-pair --key-name ${CLUSTER_ID}Key

    """
fi

PARAMETER_OVERRIDES="CmsId=${CLUSTER_ID}"
PARAMETER_OVERRIDES="${PARAMETER_OVERRIDES} KeyName=${CLUSTER_ID}Key"
PARAMETER_OVERRIDES="${PARAMETER_OVERRIDES} username=${CLUSTER_USERNAME}"
PARAMETER_OVERRIDES="${PARAMETER_OVERRIDES} InstanceType=${INSTANCE_TYPE}"
PARAMETER_OVERRIDES="${PARAMETER_OVERRIDES} DiskSizeGb=${DISK_SIZE_GB}"
PARAMETER_OVERRIDES="${PARAMETER_OVERRIDES} AvailabilityZone=${AVAILABILITY_ZONE}"
PARAMETER_OVERRIDES="${PARAMETER_OVERRIDES} SSHLocation=${SSH_LOCATION}"
PARAMETER_OVERRIDES="${PARAMETER_OVERRIDES} K8sNodeCapacity=${K8S_NODE_CAPACITY}"

[[ ! -f "$CLUSTER_TEMPLATE" ]] && \
  {
    echo >&2 """
    The template '${CLUSTER_TEMPLATE}' does not exist in ${BASEDIR}.
    Please fix your '\$INSTANCE_OS_NAME' and/or '\$INSTANCE_OS_VER' env variables
    to match a template in ${BASEDIR}.
    """
    exit 20
  }

aws cloudformation deploy --stack-name="${CLUSTER_ID}" --template-file="${CLUSTER_TEMPLATE}" --capabilities CAPABILITY_IAM \
    --parameter-overrides \
    CmsId="${CLUSTER_ID}" \
    KeyName="${CLUSTER_ID}Key" \
    username="${CLUSTER_USERNAME}" \
    InstanceType="${INSTANCE_TYPE}" \
    DiskSizeGb="${DISK_SIZE_GB}" \
    AvailabilityZone="${AVAILABILITY_ZONE}" \
    SSHLocation="${SSH_LOCATION}" \
    K8sNodeCapacity="${K8S_NODE_CAPACITY}" | tee "${CREATED}"

while [[ "$(jq ". | length" <<< "$(workers)")" -lt "${K8S_NODE_CAPACITY}" ]]; do
    sleep ${S_TIME}
    S_TIME=$((S_TIME * S_TIME))
done

if [ -z "${KUBERNETES_SERVICE_HOST}" ]; then
    if create_machines_yaml; then
      echo "done. The machines.yaml file is located in $OUTDIR."
    fi
    echo

    cat "${KEYFILE}"
else
  # shellcheck disable=SC1091
    . ./configure | kubectl apply -f -
    kubectl create secret generic "${CLUSTER_ID}"PrivateKey --from-file="${KEYFILE}"
fi
