#!/bin/bash
#
# Copyright 2018 Amazon.com, Inc. or its affiliates. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License"). You
# may not use this file except in compliance with the License. A copy of
# the License is located at
#
# http://aws.amazon.com/apache2.0/
#
# or in the "license" file accompanying this file. This file is
# distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF
# ANY KIND, either express or implied. See the License for the specific
# language governing permissions and limitations under the License.

set -o errexit

usage()
{
    echo " Usage: ${0} -s profile -d profile -a ami_id [-k key] [-l source region] [-r destination region] [-n] [-u env tag value]
    -s,               AWS CLI profile name for AMI source account.
    -d,               AWS CLI profile name for AMI destination account.
    -a,               ID of AMI to be copied.
    -N,               Name for new AMI.
    -l,               Region of the AMI to be copied.
    -r,               Destination region for copied AMI.
    -n,               Enable ENA support on new AMI. (Optional)
    -t,               Copy Tags. (Optional)
    -k,               Specific KMS Key ID for snapshot re-encryption in target AWS account. (Optional)
    -u                Set this value to tag Env for the destination image (Optional). Valid only with -t
    -h,               Show this message.

By default, the currently specified region for the source and destination AWS CLI profile will be used, and the default Amazon-managed KMS Key for EBS
    "
}


die()
{
    BASE=$(basename -- "$0")
    echo -e "${RED} $BASE: error: $@ ${NC}" >&2
    exit 1
}

# Checking dependencies
command -v jq >/dev/null 2>&1 || die "jq is required but not installed. Aborting. See https://stedolan.github.io/jq/download/"
command -v aws >/dev/null 2>&1 || die "aws cli is required but not installed. Aborting. See https://docs.aws.amazon.com/cli/latest/userguide/installing.html"



while getopts ":s:d:a:N:l:r:k:u:nth" opt; do
    case $opt in
        h) usage && exit 1
        ;;
        s) SRC_PROFILE="$OPTARG"
        ;;
        d) DST_PROFILE="$OPTARG"
        ;;
        a) AMI_ID="$OPTARG"
        ;;
        N) AMI_NAME="$OPTARG"
        ;;
        l) SRC_REGION="$OPTARG"
        ;;
        r) DST_REGION="$OPTARG"
        ;;
        k) CMK_ID="$OPTARG"
        ;;
        u) UPDATE_ENV_TAG_OPT="$OPTARG"
        ;;
        n) ENA_OPT="--ena-support"
        ;;
        t) TAG_OPT="y"
        ;;
        \?) echo "Invalid option -$OPTARG" >&2
        ;;
    esac
done

COLOR='\033[1;36m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Validating Input parameters
if [ "${SRC_PROFILE}x" == "x" ] || [ "${DST_PROFILE}x" == "x" ] || [ "${AMI_ID}x" == "x" ]; then
    usage
    exit 1;
fi

# Get default regions if not supplied
if [ "${SRC_REGION}x" == "x" ]; then
    SRC_REGION=$(aws configure get region --profile ${SRC_PROFILE} ) || die "Unable to determine the source region"
fi
if [ "${DST_REGION}x" == "x" ]; then
    DST_REGION=$(aws configure get region --profile ${DST_PROFILE} ) || die "Unable to determine the destination region"

fi
echo -e "${COLOR}Source region:${NC}" ${SRC_REGION}
echo -e "${COLOR}Destination region:${NC}" ${DST_REGION}

# Gets the source and destination account ID
SRC_ACCT_ID=$(aws sts get-caller-identity --profile ${SRC_PROFILE} --query Account --output text || die "Unable to get the source account ID. Aborting.")
echo -e "${COLOR}Source account ID:${NC}" ${SRC_ACCT_ID}
DST_ACCT_ID=$(aws sts get-caller-identity --profile ${DST_PROFILE} --query Account --output text || die "Unable to get the destination account ID. Aborting.")
echo -e "${COLOR}Destination account ID:${NC}" ${DST_ACCT_ID}


# Check if optional destination CMK exists in target region
if [ "${CMK_ID}x" != "x" ]; then
    if [ "$(aws --profile ${DST_PROFILE} --region ${DST_REGION}  kms describe-key --key-id ${CMK_ID} --query 'KeyMetadata.Enabled' --output text)" == "True" ]; then
        echo -e "${COLOR}Validated destination KMS Key:${NC} ${CMK_ID}"
    else
        die "KMS Key ${CMK_ID} non existent, in the wrong region, or not enabled. Aborting."
    fi

    CMK_OPT="--kms-key-id ${CMK_ID}"
fi

# Describes the source AMI and stores its contents
AMI_DETAILS=$(aws ec2 describe-images --profile ${SRC_PROFILE} --region ${SRC_REGION} --image-id ${AMI_ID}  --query 'Images[0]')|| die "Unable to describe the AMI in the source account. Aborting."

# Retrieve the snapshots and key ID's
SNAPSHOT_IDS=$(echo ${AMI_DETAILS} | jq -r '.BlockDeviceMappings[] | select(has("Ebs")) | .Ebs.SnapshotId' || die "Unable to get the encrypted snapshot ids from AMI. Aborting.")
echo -e "${COLOR}Snapshots found:${NC}" ${SNAPSHOT_IDS}

KMS_KEY_IDS=$(aws ec2 describe-snapshots --profile ${SRC_PROFILE} --region ${SRC_REGION}  --snapshot-ids ${SNAPSHOT_IDS} --query 'Snapshots[?Encrypted==`true`]' | jq -r '[.[].KmsKeyId] | unique | .[]' || die "Unable to get KMS Key Ids from the snapshots. Aborting.")

if [ "${KMS_KEY_IDS}x" != "x" ] ; then
  echo -e "${COLOR}Customer managed KMS key(s) used on source AMI:${NC}" ${KMS_KEY_IDS}
  # Iterate over the Keys and create the Grants
  while read key; do
      KEY_MANAGER=$(aws kms describe-key --key-id ${key} --query "KeyMetadata.KeyManager" --profile ${SRC_PROFILE} --region ${SRC_REGION} --output text || die "Unable to retrieve the Key Manager information. Aborting.")
      if [ "${KEY_MANAGER}" == "AWS" ] ; then
          die "The Default AWS/EBS key is being used by the snapshot. Unable to proceed. Aborting."
      fi
      aws kms --profile ${SRC_PROFILE} --region ${SRC_REGION} create-grant --key-id $key --grantee-principal $DST_ACCT_ID --operations DescribeKey Decrypt CreateGrant > /dev/null || die "Unable to create a KMS grant for the destination account. Aborting."
      echo -e "${COLOR}Grant created for:${NC}" ${key}
  done <<< "$KMS_KEY_IDS"
else
  echo -e "${COLOR}No encrypted EBS Volumes were found in the source AMI!${NC}"
fi

# Iterate over the snapshots, adding permissions for the destination account and copying
i=0
while read snapshotid; do
    aws ec2 --profile ${SRC_PROFILE} --region ${SRC_REGION} modify-snapshot-attribute --snapshot-id $snapshotid --attribute createVolumePermission --operation-type add --user-ids $DST_ACCT_ID || die "Unable to add permissions on the snapshots for the destination account. Aborting."
    echo -e "${COLOR}Permission added to Snapshot:${NC} ${snapshotid}"
    SRC_SNAPSHOT[$i]=${snapshotid}
    echo -e "${COLOR}Copying Snapshot:${NC} ${snapshotid}"
    DST_SNAPSHOT[$i]=$(aws ec2 copy-snapshot --profile ${DST_PROFILE} --region ${DST_REGION} --source-region ${SRC_REGION} --source-snapshot-id $snapshotid --description "Copied from $snapshotid (${SRC_ACCT_ID}|${SRC_REGION})" --encrypted ${CMK_OPT} --query SnapshotId --output text|| die "Unable to copy snapshot. Aborting.")
    i=$(( $i + 1 ))
    SIM_SNAP=$(aws ec2 describe-snapshots --profile "${DST_PROFILE}" --region "${DST_REGION}" --filters Name=status,Values=pending --query 'Snapshots[].SnapshotId' --output text | wc -w)
    while [ $SIM_SNAP -ge 5 ]; do
        echo -e "${COLOR}Too many concurrent Snapshots, waiting...${NC}"
        sleep 30
        SIM_SNAP=$(aws ec2 describe-snapshots --profile "${DST_PROFILE}" --region "${DST_REGION}" --filters Name=status,Values=pending --query 'Snapshots[].SnapshotId' --output text | wc -w)
    done
done <<< "$SNAPSHOT_IDS"

# Wait 1 second to avoid issues with eventual consistency
sleep 1

# Wait for EBS snapshots to be completed
echo -e "${COLOR}Waiting for all EBS Snapshots copies to complete. It may take a few minutes.${NC}"
i=0
while read snapshotid; do
    snapshot_progress="0%"
    snapshot_state=""
    while [ "$snapshot_progress" != "100%" ]; do
        snapshot_result=$(aws ec2 describe-snapshots --region ${DST_REGION} \
                                                     --snapshot-ids ${DST_SNAPSHOT[i]} \
                                                     --profile ${DST_PROFILE} \
                                                     --no-paginate \
                                                     --query "Snapshots[*].[Progress, State]" \
                                                     --output text)
        snapshot_progress=$(echo $snapshot_result | awk '{print $1}')
        snapshot_state=$(echo $snapshot_result | awk '{print $2}')
        if [ "${snapshot_state}" == "error" ]; then
            die "Error copying snapshot"
        else
        echo -e "${COLOR} Snapshot progress: ${DST_SNAPSHOT[i]} $snapshot_progress"
        fi
        sleep 20
    done
    aws ec2 wait snapshot-completed --snapshot-ids ${DST_SNAPSHOT[i]} --profile ${DST_PROFILE} --region ${DST_REGION} || die "Failed while waiting the snapshots to be copied. Aborting."
    i=$(( $i + 1 ))
done <<< "$SNAPSHOT_IDS"
echo -e "${COLOR}EBS Snapshots copies completed ${NC}"

sLen=${#SRC_SNAPSHOT[@]}

# Copy Snapshots Tags
if [ "${TAG_OPT}x" != "x" ]; then
    for (( i=0; i<${sLen}; i++)); do
        # Describes the source AMI and stores its contents
        SNAPSHOT_DETAILS=$(aws ec2 describe-snapshots --profile ${SRC_PROFILE} --region ${SRC_REGION} --snapshot-id ${SRC_SNAPSHOT[i]}  --query 'Snapshots[0]')|| die "Unable to describe the Snapshot in the source account. Aborting."
        SNAPSHOT_TAGS=$(echo ${SNAPSHOT_DETAILS} | jq '.Tags')"}"
        if [ "${SNAPSHOT_TAGS}" != "null}" ]; then
            NEW_SNAPSHOT_TAGS="{\"Tags\":"$(echo ${SNAPSHOT_TAGS} | tr -d ' ')
            $(aws ec2 create-tags --resources ${DST_SNAPSHOT[i]} --cli-input-json ${NEW_SNAPSHOT_TAGS} --profile ${DST_PROFILE} --region ${DST_REGION} || die "Unable to add tags to the Snapshot ${DST_SNAPSHOT[i]} in the destination account. Aborting.")
            if [ "${UPDATE_ENV_TAG_OPT}x" != "x" ]; then
                $(aws ec2 create-tags --resources ${DST_SNAPSHOT[i]} --tags Key=Env,Value=${UPDATE_ENV_TAG_OPT} --profile ${DST_PROFILE} --region ${DST_REGION} || die "Unable to change tag 'env' to the Snapshot ${DST_SNAPSHOT[i]} in the destination account. Aborting.")
            fi
            echo -e "${COLOR}Tags added sucessfully for snapshot ${DST_SNAPSHOT[i]}${NC}"
        fi
    done
fi

# Prepares the json data with the new snapshot IDs and remove unecessary information
for (( i=0; i<${sLen}; i++)); do
    echo -e "${COLOR}Snapshots${NC} ${SRC_SNAPSHOT[i]} ${COLOR}copied as${NC} ${DST_SNAPSHOT[i]}"
    AMI_DETAILS=$(echo ${AMI_DETAILS} | sed -e s/${SRC_SNAPSHOT[i]}/${DST_SNAPSHOT[i]}/g )
done

# define a name for the new AMI
NAME=$(echo ${AMI_DETAILS} | jq -r '.Name')
if [ "${AMI_NAME}x" != "x" ]; then
    # use the name supplied
    NEW_NAME=${AMI_NAME}
else
    now="$(date +%s)"
    NEW_NAME="Copy of ${NAME} ${now}"
fi

# Copy AMI structure while removing read-only / non-idempotent values
NEW_AMI_DETAILS=$(echo ${AMI_DETAILS} | jq --arg NAME "${NEW_NAME}" '.Name = $NAME | del(.. | .Encrypted?) | del(.Tags,.Platform,.PlatformDetails,.UsageOperation,.ImageId,.CreationDate,.OwnerId,.ImageLocation,.State,.ImageType,.RootDeviceType,.Hypervisor,.Public,.EnaSupport,.ProductCodes )')

# Create the AMI in the destination
CREATED_AMI=$(aws ec2 register-image --profile ${DST_PROFILE} --region ${DST_REGION} ${ENA_OPT} --cli-input-json "${NEW_AMI_DETAILS}" --query ImageId --output text || die "Unable to register AMI in the destination account. Aborting.")
echo -e "${COLOR}AMI created succesfully in the destination account:${NC} ${CREATED_AMI}"

# Copy AMI Tags
if [ "${TAG_OPT}x" != "x" ]; then
    AMI_TAGS=$(echo ${AMI_DETAILS} | jq '.Tags')"}"
    if [ "${AMI_TAGS}" != "null}" ]; then
        NEW_AMI_TAGS="{\"Tags\":"$(echo ${AMI_TAGS} | tr -d ' ')
        $(aws ec2 create-tags --resources ${CREATED_AMI} --cli-input-json ${NEW_AMI_TAGS} --profile ${DST_PROFILE} --region ${DST_REGION} || die "Unable to add tags to the AMI in the destination account. Aborting.")
        if [ "${UPDATE_ENV_TAG_OPT}x" != "x" ]; then
            $(aws ec2 create-tags --resources ${CREATED_AMI} --tags Key=Env,Value=${UPDATE_ENV_TAG_OPT} --profile ${DST_PROFILE} --region ${DST_REGION} || die "Unable to change tag 'env' to the AMI in the destination account. Aborting.")
        fi
        echo -e "${COLOR}Tags added sucessfully for AMI ${CREATED_AMI}${NC}"
    fi
fi
