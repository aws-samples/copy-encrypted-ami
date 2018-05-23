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
    echo " Usage: ${0} -s profile -d profile -a ami_id [-k key] [-l source region] [-r destination region] [-n]
    -s,               AWS CLI profile name for AMI source account.
    -d,               AWS CLI profile name for AMI destination account.
    -a,               ID of AMI to be copied.
    -l,               Region of the AMI to be copied.
    -r,               Destination region for copied AMI.
    -n,               Enable ENA support on new AMI. (Optional)
    -t,               Copy Tags. (Optional)
    -k,               Specific KMS Key ID for snapshot re-encryption in target AWS account. (Optional)
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



while getopts ":s:d:a:l:r:k:nth" opt; do
    case $opt in
        h) usage && exit 1
        ;;
        s) SRC_PROFILE="$OPTARG"
        ;;
        d) DST_PROFILE="$OPTARG"
        ;;
        a) AMI_ID="$OPTARG"
        ;;
        l) SRC_REGION="$OPTARG"
        ;;
        r) DST_REGION="$OPTARG"
        ;;
        k) CMK_ID="$OPTARG"
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

# Gets the destination account ID
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
SNAPSHOT_IDS=$(echo ${AMI_DETAILS} | jq -r '.BlockDeviceMappings[].Ebs | .SnapshotId' || die "Unable to get the encrypted snapshot ids from AMI. Aborting.")
echo -e "${COLOR}Snapshots found:${NC}" ${SNAPSHOT_IDS}

KMS_KEY_IDS=$(aws ec2 describe-snapshots --profile ${SRC_PROFILE} --region ${SRC_REGION}  --snapshot-ids ${SNAPSHOT_IDS} --query 'Snapshots[?Encrypted==`true`]' | jq -r '[.[].KmsKeyId] | unique | .[]' || die "Unable to get KMS Key Ids from the snapshots. Aborting.")
echo -e "${COLOR}Customer managed KMS key(s) used on source AMI:${NC}" ${KMS_KEY_IDS}

# Iterate over the Keys and create the Grants
while read key; do
    KEY_MANAGER=$(aws kms describe-key --key-id ${key} --query "KeyMetadata.KeyManager" --profile ${SRC_PROFILE} --region ${SRC_REGION} --output text || die "Unable to retrieve the Key Manager information. Aborting.")
    if [ "${KEY_MANAGER}" == "AWS" ] ; then
        # Technically, we could copy and re-encrypt the snapshot, then continue.....
        die "The Default AWS/EBS key is being used by the snapshot. Unable to proceed. Aborting."
    fi
    aws kms --profile ${SRC_PROFILE} --region ${SRC_REGION} create-grant --key-id $key --grantee-principal $DST_ACCT_ID --operations DescribeKey Decrypt CreateGrant > /dev/null || die "Unable to create a KMS grant for the destination account. Aborting."
    echo -e "${COLOR}Grant created for:${NC}" ${key}
done <<< "$KMS_KEY_IDS"

# Iterate over the snapshots and add permissions for the destination account
i=0
while read snapshotid; do
    aws ec2 --profile ${SRC_PROFILE} --region ${SRC_REGION} modify-snapshot-attribute --snapshot-id $snapshotid --attribute createVolumePermission --operation-type add --user-ids $DST_ACCT_ID || die "Unable to add permissions on the snapshots for the destination account. Aborting."
    echo -e "${COLOR}Permission added to Snapshot:${NC} ${snapshotid}"
    SRC_SNAPSHOT[$i]=${snapshotid}
    DST_SNAPSHOT[$i]=$(aws ec2 copy-snapshot --profile ${DST_PROFILE} --region ${DST_REGION} --source-region ${SRC_REGION} --source-snapshot-id $snapshotid --description "Copied from $snapshotid" --encrypted ${CMK_OPT} --query SnapshotId --output text|| die "Unable to copy snapshot. Aborting.")
    i=$(( $i + 1 ))
done <<< "$SNAPSHOT_IDS"

# Wait 1 second to avoid issues with eventual consistency

sleep 1

# Wait for EBS snapshots to be completed
echo -e "${COLOR}Waiting for all EBS Snapshots copies to complete. It may take a few minutes.${NC}"
i=0
while read snapshotid; do
    aws ec2 wait snapshot-completed --snapshot-ids ${DST_SNAPSHOT[i]} --profile ${DST_PROFILE} --region ${DST_REGION} || die "Failed while waiting the snapshots to be copied. Aborting."
    i=$(( $i + 1 ))
done <<< "$SNAPSHOT_IDS"
echo -e "${COLOR}EBS Snapshots copies completed ${NC}"

# Prepares the json data with the new snapshot IDs and remove unecessary information
sLen=${#SRC_SNAPSHOT[@]}

for (( i=0; i<${sLen}; i++)); do
    echo -e "${COLOR}Snapshots${NC} ${SRC_SNAPSHOT[i]} ${COLOR}copied as${NC} ${DST_SNAPSHOT[i]}"
    AMI_DETAILS=$(echo ${AMI_DETAILS} | sed -e s/${SRC_SNAPSHOT[i]}/${DST_SNAPSHOT[i]}/g )
done

# Copy AMI structure while removing read-only / non-idempotent values
NEW_AMI_DETAILS=$(echo ${AMI_DETAILS} | jq '.Name |= "Copy of " + . + " \(now)" | del(.. | .Encrypted?) | del(.Tags,.Platform,.ImageId,.CreationDate,.OwnerId,.ImageLocation,.State,.ImageType,.RootDeviceType,.Hypervisor,.Public,.EnaSupport )')

# Create the AMI in the destination
CREATED_AMI=$(aws ec2 register-image --profile ${DST_PROFILE} --region ${DST_REGION} ${ENA_OPT} --cli-input-json "${NEW_AMI_DETAILS}" --query ImageId --output text || die "Unable to register AMI in the destination account. Aborting.")
echo -e "${COLOR}AMI created succesfully in the destination account:${NC} ${CREATED_AMI}"

# Copy Tags 
if [ "${TAG_OPT}x" != "x" ]; then
    AMI_TAGS=$(echo ${AMI_DETAILS} | jq '.Tags')"}"
    NEW_AMI_TAGS="{\"Tags\":"$(echo ${AMI_TAGS} | tr -d ' ')
    $(aws ec2 create-tags --resources ${CREATED_AMI} --cli-input-json ${NEW_AMI_TAGS} --profile ${DST_PROFILE} --region ${DST_REGION} || die "Unable to add tags to the AMI in the destination account. Aborting.") 
    echo -e "${COLOR}Tags added sucessfully${NC}"
fi
