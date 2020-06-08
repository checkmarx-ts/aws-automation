# aws-automation
Resources and documentation on how to run Checkmarx in AWS.

# Requirements

* Powershell 5.1 or higher
* Windows Server 2016 or higher
* AWS Powershell Cmdlets

# Getting started
To begin, you should have access to an AWS account. This getting started guide will walk you through creating infrastructure to run Checkmarx. Your account must be able to provision the infrastructure needed. Using the resources in this repo will cause you to use AWS Services which will incur cost - be careful. This guide uses an organization name 'checkmarx-ts' to label resources - you should replace these references with your own organization label.

## Deploy the network
First, create a VPC with 2 public and 2 private subnets using the Cloud Formation Template ```100-network.yml```. If you already have a network set up that you want to deploy Checkmarx into then skip this step.

Use the AWS Console to create this Cloud Formation Template or use the AWS CLI as shown below. 

```powershell
# Create the network stack
aws cloudformation create-stack --stack-name checkmarx-ts-vpc --template-body file://100-network.yml --parameters ParameterKey=ClassB,ParameterValue=77 --tags Key=Environment,Value="Development"
```

## Deploy Directory Services
It is not required to run Checkmarx on a domain but most people do. We will use the AWS Managed AD service to obtain domain services. If you already have a domain then skip this step.

Deploy the Cloud Formation template ```200-DirectoryServicesMicrosoftAD.yml``` using the AWS Console or CLI. Using the CLI we will obtain many parameters values from our previously created stack.

```powershell
# Pull parameters from previous stacks, but you can also manually set values
$vpc = (aws cloudformation describe-stacks --stack-name checkmarx-ts-vpc | ConvertFrom-Json).Stacks[0].Outputs
$vpcid = $vpc | where-object {$_.OutputKey -eq "VPC"} | select -ExpandProperty OutputValue 
$subnet1 =  $vpc | where-object {$_.OutputKey -eq "SubnetAPrivate"} | select -ExpandProperty OutputValue 
$subnet2 = $vpc | where-object {$_.OutputKey -eq "SubnetBPrivate"} | select -ExpandProperty OutputValue 
$AdPassword = "use a strong password!"
$domainname = "corp.dev.checkmarx-ts.com" 
aws cloudformation create-stack --stack-name checkmarx-ts-active-directory --template-body file://200-DirectoryServicesMicrosoftAD.yml --parameters ParameterKey=pDomainName,ParameterValue=${domainname} ParameterKey=pMicrosoftADShortName,ParameterValue=corp ParameterKey=pMicrosoftADPW,ParameterValue=${AdPassword} ParameterKey=pEdition,ParameterValue=Standard ParameterKey=pCreateAlias,ParameterValue=false ParameterKey=pEnableSingleSignOn,ParameterValue=false ParameterKey=pPrivateSubnet1,ParameterValue="${subnet1}" ParameterKey=pPrivateSubnet2,ParameterValue="${subnet2}" ParameterKey=pVPCID,ParameterValue="${vpcid}" --tags Key=Environment,Value="Development"
```

## Deploy FSX shares
FSX provides a file share (NAS) that Checkmarx will use to satisfy part of its storage requirements. FSX also provides flexibility in deployment options. If you already have a plan for storage then skip this step. 

Deploy the Cloud Formation template ```210-fsx-windows.yml``` using the AWS Console or CLI. Using the CLI we will obtain many parameters values from our previously created stack.

```powershell
$vpc =(aws cloudformation describe-stacks --stack-name checkmarx-ts-vpc | ConvertFrom-Json).Stacks[0].Outputs
$vpcid = $vpc | where-object {$_.OutputKey -eq "VPC"} | select -ExpandProperty OutputValue 
$subnet1 =  $vpc | where-object {$_.OutputKey -eq "SubnetAPrivate"} | select -ExpandProperty OutputValue 
$subnet2 = $vpc| where-object {$_.OutputKey -eq "SubnetBPrivate"} | select -ExpandProperty OutputValue 
$fsx_connections_cidr = $vpc | where-object {$_.OutputKey -eq "CidrBlock"} | select -ExpandProperty OutputValue 

$ad = (aws cloudformation describe-stacks --stack-name checkmarx-ts-active-directory | ConvertFrom-Json).Stacks[0].Outputs
$ActiveDirectoryId =  $ad | where-object {$_.OutputKey -eq "DirectoryID"} | select -ExpandProperty OutputValue 
$domainsg = (aws ec2 describe-security-groups --filters Name=description,Values=*${ActiveDirectoryId}* | ConvertFrom-Json).SecurityGroups[0] | Select -ExpandProperty GroupId

aws cloudformation create-stack --stack-name checkmarx-ts-fsx --template-body file://210-fsx-windows.yml --parameters ParameterKey=PrivateSubnet1ID,ParameterValue="${subnet1}" ParameterKey=PrivateSubnet2ID,ParameterValue="${subnet2}" ParameterKey=VPCID,ParameterValue="${vpcid}" ParameterKey=ActiveDirectoryId,ParameterValue="${ActiveDirectoryId}" ParameterKey=FSxAllowedCIDR,ParameterValue="${fsx_connections_cidr}" ParameterKey=DomainMembersSG,ParameterValue="${domainsg}" --tags Key=Environment,Value="Development"
```

## Create your s3 bucket
Checkmarx automation will use s3 to store dependencies, installers, configuration files, write logs, etc. 

If you need to use an existing s3 bucket then continue to the inflation step but you may need to adjust some IAM policies if the paths that Checkmarx uses need to change.

Deploy the Cloud Formation template ```250-s3-bucket.yml``` using the AWS Console or CLI. 

```powershell
aws cloudformation create-stack --stack-name checkmarx-ts-s3 --template-body file://250-s3-bucket.yml --parameters ParameterKey=pBucketName,ParameterValue="checkmarx-ts" --tags Key=Owner,Value=Ben Key=Environment,Value=Development
```
## Inflate your s3 bucket
Now that your s3 bucket is up, you need to load it with dependencies - things that this Checkmarx automation will use. 

Follow the steps in [cloudformation/251-inflate-s3-bucket.md](cloudformation/251-inflate-s3-bucket.md) to populate your bucket.

## Deploy Checkmarx security
The security template includes things like security groups and IAM roles. These resources are required however you may customize them so long as you do not break component-to-component communication (e.g. you can - and should - lock down your users CIDR block). 

Deploy the Cloud Formation template ```300-checkmarx-security.yml``` using the AWS Console or CLI. Using the CLI we will obtain many parameters values from our previously created stack.

```powershell
# security/iam
$vpc =(aws cloudformation describe-stacks --stack-name checkmarx-ts-vpc | ConvertFrom-Json).Stacks[0].Outputs
$vpcid = $vpc | where-object {$_.OutputKey -eq "VPC"} | select -ExpandProperty OutputValue 
$key_arn = (aws kms describe-key --key-id alias/aws/ssm | ConvertFrom-Json).KeyMetaData | Select -ExpandProperty Arn
aws cloudformation create-stack --stack-name checkmarx-ts-security --template-body file://300-checkmarx-security.yml --parameters ParameterKey=pCheckmarxBucket,ParameterValue="arn:aws:s3:::checkmarx-ts" ParameterKey=pCxSASTUsersCIDR,ParameterValue="0.0.0.0/0" ParameterKey=pVPCID,ParameterValue="${vpcid}" ParameterKey=pParameterStoreKey,ParameterValue="${key_arn}" --capabilities CAPABILITY_NAMED_IAM --tags Key=Environment,Value="Development"
```

## Deploy Checkmarx Image Builder
Checkmarx will create AMIs using the EC2 Image Builder service. Create this stack manually or by deploying the ```400-image-builder.yml``` using the CLI. Many parameter inputs to this template will be sourced from previous templates. 

In case somehow you don't already have one, you will need a keypair at this point before you continue (this template takes a keypair as a parameter). See https://docs.aws.amazon.com/cli/latest/userguide/cli-services-ec2-keypairs.html#creating-a-key-pair. 


```powershell
# Image Builder
$vpc =(aws cloudformation describe-stacks --stack-name checkmarx-ts-vpc | ConvertFrom-Json).Stacks[0].Outputs
$vpcid = $vpc | where-object {$_.OutputKey -eq "VPC"} | select -ExpandProperty OutputValue 
$subnet1 =  $vpc | where-object {$_.OutputKey -eq "SubnetAPublic"} | select -ExpandProperty OutputValue 
aws cloudformation create-stack --stack-name checkmarx-ts-image-factory --template-body file://400-image-builder.yml --parameters ParameterKey=pS3Bucket,ParameterValue="checkmarx-ts" ParameterKey=pEngineBaseAmi,ParameterValue="arn:aws:imagebuilder:us-east-2:aws:image/windows-server-2016-english-core-base-x86/x.x.x" ParameterKey=pManagerBaseAmi,ParameterValue="arn:aws:imagebuilder:us-east-2:aws:image/windows-server-2016-english-full-base-x86/x.x.x" ParameterKey=pRemoteDesktopCIDR,ParameterValue="0.0.0.0/0" ParameterKey=pVpcId,ParameterValue="${vpcid}" ParameterKey=pBuilderSubnet,ParameterValue="${subnet1}" ParameterKey=pBuilderKeypair,ParameterValue="stokes" ParameterKey=pAmiDistributionRegion,ParameterValue="us-east-2" --tags Key=Environment,Value="Development"
```

## Deploy the Checkmarx Environment

```powershell
$vpc =(aws cloudformation describe-stacks --stack-name checkmarx-ts-vpc | ConvertFrom-Json).Stacks[0].Outputs
$vpcid = $vpc | where-object {$_.OutputKey -eq "VPC"} | select -ExpandProperty OutputValue 
$publicSubnets = $($vpc | where-object {$_.OutputKey -eq "SubnetsPublic"} | select -ExpandProperty OutputValue).Replace(",", "\,")
$privateSubnets = $($vpc | where-object {$_.OutputKey -eq "SubnetsPrivate"} | select -ExpandProperty OutputValue).Replace(",", "\,")
$ebsKey = (aws kms describe-key --key-id alias/aws/ebs | ConvertFrom-Json).KeyMetaData |Select -ExpandProperty Arn
$security = (aws cloudformation describe-stacks --stack-name checkmarx-ts-security | ConvertFrom-Json).Stacks[0].Outputs
$managerIam = "arn:aws:iam::275043232443:instance-profile/checkmarx-cxsast-manager"
$engineIam = "arn:aws:iam::275043232443:instance-profile/checkmarx-cxsast-engine"
$managerSg = $security | where-object {$_.OutputKey -eq "ManagerSecurityGroupId"} | select -ExpandProperty OutputValue 
$engineSg = $security | where-object {$_.OutputKey -eq "EngineSecurityGroupId"} | select -ExpandProperty OutputValue 

aws cloudformation create-stack --stack-name checkmarx-ts-sast89 --template-body file://500-cxsast.yml --parameters ParameterKey=pVpcId,ParameterValue="${vpcid}" ParameterKey=pManagerSubnets,ParameterValue="${publicSubnets}" ParameterKey=pEngineSubnets,ParameterValue="${privateSubnets}" ParameterKey=pEngineAvailabilityZones,ParameterValue="us-east-2a\,us-east-2b"  ParameterKey=pManagerAvailabilityZones,ParameterValue="us-east-2a\,us-east-2b" ParameterKey=pS3Bucket,ParameterValue="checkmarx-ts" ParameterKey=pEbsKey,ParameterValue="${ebsKey}" ParameterKey=pEc2Key,ParameterValue="stokes" ParameterKey=pManagerIamProfile,ParameterValue="${managerIam}" ParameterKey=pEngineIamProfile,ParameterValue="${engineIam}" ParameterKey=pManagerSecurityGroups,ParameterValue="${managerSg}" ParameterKey=pEngineSecurityGroups,ParameterValue="${engineSg}" ParameterKey=pManagerAmi,ParameterValue="ami-011eb19eeda1a763a" ParameterKey=pEngineAmi,ParameterValue="ami-01525ec5f040540fa" --tags Key=Environment,Value="Development"

```

# Guidance & Caveats

* Use the default installation location ```C:\Program Files\Checkmarx```, especially if will install BI
* Do not install BI


# Troubleshooting

These links are helpful:
* https://docs.aws.amazon.com/imagebuilder/latest/userguide/what-is-image-builder.html
* https://docs.aws.amazon.com/imagebuilder/latest/userguide/image-builder-troubleshooting.html
* https://docs.aws.amazon.com/systems-manager/latest/userguide/automation-troubleshooting.html

---

If EC2 Image Builder fails due to a timeout verifying SSM Agent availability like the following:

```
SSM execution '5ba529cb-bbb4-4e34-a2d5-19dbb42932ff' failed with status = 'TimedOut' and failure message = 'Step timed out while step is verifying the SSM Agent availability on the target instance(s). SSM Agent on Instances: [i-0a0c28557cf6936da] are not functioning. Please refer to Automation Service Troubleshooting Guide for more diagnosis details.'
```
Then, ensure you are building your images in a public subnet (not private), and ensure that the SSM agent is installed and up to date on your base image. Its possible the SSM agent is not present on custom base images not provided by Amazon. 

See https://docs.aws.amazon.com/imagebuilder/latest/userguide/image-builder-image-deployment-console.html where a public subnet is specified. 

---
If you get an error message like the following when deploying a cloud formation template:
```
Parameter validation failed:
Invalid type for parameter Parameters[3].ParameterValue, value: ['us-east-2a', 'us-east-2b'], type: <class 'list'>, valid types: <class 'str'>
```
Then, ensure you are escaping the commas in list parameters for cloud formation.

Wrong: ```"us-east-2a, us-east-2b"```

Correct: ```"us-east-2a\, us-east-2b"```

# FAQ

**Q:** Why are there so many cloud formation templates? Can they be combined?

**A:** Many organizations have policies around creating resources that must be adhered to. For example, not everyone can just create an S3 Bucket via self service and may need to request it be created for them. These templates are split up into infrastructure layers in order to be flexible. They can also be combined into one master template if that works better for you (watch out for limits though). 

# Options

A work in progress

* Storage
* SSL
* Patching

# Tags

Tags are used in this way.

checkmarx:dns
checkmarx:lets-encrypt-contact

# Todo

* Enhance cloudwatch logs config w/ time format specifications
* Add ActivMQ logs