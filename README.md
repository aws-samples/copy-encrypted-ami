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
copy_encrypted_ami.sh -s profile -d profile -a ami_id [-k key] [-l source region] [-r destination region] [-n]
    -s,               AWS CLI profile name for AMI source account.
    -d,               AWS CLI profile name for AMI destination account.
    -a,               ID of AMI to be copied.
    -l,               Region of the AMI to be copied.
    -r,               Destination region for copied AMI.
    -n,               Enable ENA support on new AMI. (Optional)
    -t,               Copy Tags. (Optional)
    -k,               Specific AWS KMS Key ID for snapshot re-encryption in target AWS account. (Optional)
    -h,               Show this message.
```
By default, the currently specified region for the source and destination AWS CLI profile will be used, and the default Amazon-managed AWS KMS Key for Amazon EBS.

## Setting up the profiles

Use ```aws configure --profile profile_name``` to set up your profiles (source and destination). For more information about multiple profiles, please consult https://docs.aws.amazon.com/cli/latest/userguide/cli-multiple-profiles.html

## Example

```copy_encrypted_ami.sh -s mysrcprofile -d mydstprofile -a ami-61341708```

The line above copies the AMI ami-61341708 present in the account configured in the local mysrcprofile to the account configured in the local mydstprofile using the profile's default region.




```copy_encrypted_ami.sh -s mysrclocal -d mydstprofile -a ami-61341708 -k arn:aws:kms:eu-west-2:111122223333:key/1234abcd-12ab-34cd-56ef-1234567890ab -l ap-southeast-2 -r eu-west-2 -n```

The line above copies the AMI ami-61341708 present in the region ap-southeast-2 for the account configured in the local mysrcprofile to the account configured in the local mydstprofile in the region eu-west-2, using AWS KMS key arn:aws:kms:eu-west-2:111122223333:key/1234abcd-12ab-34cd-56ef-1234567890ab in the destination and enabling ENA Support.

## Known Limitations

This script will not work if the default AWS KMS key was used to encrypt the source snapshots.

This script will encrypt the snapshots at the destination, even if one of the source snapshots was unencrypted.
