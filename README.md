## Copy Encrypted AMI

Shell script that automates the copy of encrypted AMI across accounts and regions.

## License

This library is licensed under the Apache 2.0 License.

## Synopsis

This script copies an AMI and its associated snapshots (encrypted or not) in the account A (source) to an AMI with encrypted snapshots using account B (destination).

## Prerequisites

jq - https://stedolan.github.io/jq/download/

aws cli - https://docs.aws.amazon.com/cli/latest/userguide/installing.html


The source and destination profiles must be configured in the system where you are running the script from.


## Usage

```
copy_encrypted_ami.sh -s profile -d profile -a ami_id [-k key] [-l source region] [-r destination region] [-n] [-u tag:value]
    -s,               AWS CLI profile name for AMI source account.
    -S,               AWS source account ID (exclusive with -s, use to copy AMIs already shared).
    -d,               AWS CLI profile name for AMI destination account.
    -a,               ID of AMI to be copied.
    -N,               Name for new AMI.
    -l,               Region of the AMI to be copied.
    -r,               Destination region for copied AMI.
    -n,               Enable ENA support on new AMI. (Optional)
    -t,               Copy Tags. (Optional)
    -k,               Specific AWS KMS Key ID for snapshot re-encryption in target AWS account. (Optional)
    -u,               Update an existing or create a new tag with this value. Valid only with -t. (Optional)
    -h,               Show this message.
```
By default, the currently specified region for the source and destination AWS CLI profile will be used, and the default Amazon-managed AWS KMS Key for Amazon EBS.

## Setting up the profiles

Use ```aws configure --profile profile_name``` to set up your profiles (source and destination). For more information about multiple profiles, please consult https://docs.aws.amazon.com/cli/latest/userguide/cli-multiple-profiles.html

In cases where you need to copy an AMI that has been shared with you but you don't have credentials to the source account, use the `-S` option instead to specify the source account ID (and also specify the source region with `-l`).

## Example

```copy_encrypted_ami.sh -s mysrcprofile -d mydstprofile -a ami-61341708```

The line above copies the AMI ami-61341708 present in the account configured in the local mysrcprofile to the account configured in the local mydstprofile using the profile's default region.




```copy_encrypted_ami.sh -s mysrclocal -d mydstprofile -a ami-61341708 -k arn:aws:kms:eu-west-2:111122223333:key/1234abcd-12ab-34cd-56ef-1234567890ab -l ap-southeast-2 -r eu-west-2 -n```

The line above copies the AMI ami-61341708 present in the region ap-southeast-2 for the account configured in the local mysrcprofile to the account configured in the local mydstprofile in the region eu-west-2, using AWS KMS key arn:aws:kms:eu-west-2:111122223333:key/1234abcd-12ab-34cd-56ef-1234567890ab in the destination and enabling ENA Support.



```copy_encrypted_ami.sh -S 012345678 -d mydstprofile -a ami-61341708 -l us-east-1```

The line above copies the AMI ami-61341708 present in the region us-east-1 from the AWS account ID 012345678 to the account configured in the local mydstprofile in the default region defined for mydstprofile.

## Known Limitations

This script will not work if the default AWS KMS key was used to encrypt the source snapshots.

This script will encrypt the snapshots at the destination, even if one of the source snapshots was unencrypted.
