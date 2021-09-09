########################################################
#      Lambda Ami Bakery - Authored by Ryan Payne      #
# Please see README.md for important usage information #
########################################################
#
# PowerShell script file to be executed as a AWS Lambda function. 
# 
# When executing in Lambda the following variables will be predefined.
# $LambdaInput - A PSObject that contains the Lambda function input data.
# $LambdaContext - An Amazon.Lambda.Core.ILambdaContext object that contains information about the currently running Lambda environment.
#
# The last item in the PowerShell pipeline will be returned as the result of the Lambda function.
#
# To include PowerShell modules with your Lambda function, like the AWSPowerShell.NetCore module, add a "#Requires" statement 
# indicating the module and version.

#Requires -Modules @{ModuleName='AWSPowerShell.NetCore';ModuleVersion='3.3.422.0'}

# Uncomment to send the input event to CloudWatch Logs
# Write-Host (ConvertTo-Json -InputObject $LambdaInput -Compress -Depth 5)

Write-Host 'Function name:' $LambdaContext.FunctionName
Write-Host 'Remaining milliseconds:' $LambdaContext.RemainingTime.TotalMilliseconds
Write-Host 'Log group name:' $LambdaContext.LogGroupName
Write-Host 'Log stream name:' $LambdaContext.LogStreamName

function Check-Parameter {
    Param (
    )

    ### UPDATE w/ SSM Parameter Name That Stores The Base Instance ID ###
	$ssmParamName = ""
	$ssmParam = (Get-SSMParameterValue -Name $ssmParamName).Parameters
	$instanceId = $ssmParam.Value

	Write-Host "Found $ssmParamName contains $instanceId"

	Create-Ami -instanceId $instanceId
}

function Create-Ami {

    Param (
        $instanceId
    )

    ### UPDATE w/ OS Identifier and Description ###
    $os = ""
    $description = ""

    #Create an AMI
    $today = (Get-Date).ToString('yyyyMMddhhmmss')    
    $name = $os + $today
    Write-Host "Creating AMI from $instanceId"
    New-EC2Image -InstanceId $instanceId -Name $name -Description $description

    #Use AMI name to retrieve Image Id
    $image = Get-EC2Image -Filter @{ Name="name"; Values="$name" }
    $imageId = $image.ImageId

    #Wait until AMI is available before Copy
    Write-Host "Checking $imageId for Available Status"
    do {
        Start-Sleep -Seconds 30
        $getImageState = Get-EC2Image -ImageId $imageId
        $imageState = $getImageState.State
        Write-Host "$imageId status is $imageState"

    } While ($imageState -ne "available")

    Tag-LocalAmis -imageId $imageId -name $name -description $description    
}

function Tag-LocalAmis{

    param(
        $imageId,
        $name,
        $description
    )

    # Get Previous AMI Values
    $goldssmAmiName = "ami.$os.gold"
    $goldssmAmi = (Get-SSMParameterValue -Name $goldssmAmiName).Parameters
    $goldAmiValue = $goldssmAmi.Value
    
    $silverssmAmiName = "ami.$os.silver"
    $silverssmAmi = (Get-SSMParameterValue -Name $silverssmAmiName).Parameters
    $silverAmiValue = $silverssmAmi.Value
    
    $bronzessmAmiName = "ami.$os.bronze"
    $bronzessmAmi = (Get-SSMParameterValue -Name $bronzessmAmiName).Parameters
    $bronzeAmiValue = $bronzessmAmi.Value


    # Update Gold with new AMI Id
    Write-Host "Updating SSM Parameters with Latest AMI, $imageId is now Gold"
    Write-SSMParameter -Name $goldssmAmiName -Type "String" -Value $imageId -Description $description -Overwrite $true

    $goldNameTag = New-Object Amazon.EC2.Model.Tag
    $goldNameTag.Key = "Name"
    $goldNameTag.Value = "gold-" + $name
    
    Write-Host "Tagging $imageId"
    New-EC2Tag -Resource $imageId -Tag $goldNameTag
    

    # Update Silver with previous Gold AMI Id
    Write-Host "Updating SSM Parameters, $goldAmiValue is now Silver"
    Write-SSMParameter -Name $silverssmAmiName -Type "String" -Value $goldAmiValue -Description "Silver RHEL7.9 AMI Id" -Overwrite $true

    $silverNameTag = New-Object Amazon.EC2.Model.Tag
    $silverNameTag.Key = "Name"
    $silverNameTag.Value = "silver-" + $name

    Write-Host "Tagging $goldAmiValue"
    New-EC2Tag -Resource $goldAmiValue -Tag $silverNameTag
    

    # Update Bronze with previous Silver AMI Id
    Write-Host "Updating SSM Parameters, $silverAmiValue is now Bronze"
    Write-SSMParameter -Name $bronzessmAmiName -Type "String" -Value $silverAmiValue -Description "Bronze RHEL7 AMI Id" -Overwrite $true

    $bronzeNameTag = New-Object Amazon.EC2.Model.Tag
    $bronzeNameTag.Key = "Name"
    $bronzeNameTag.Value = "bronze-" + $name
    
    Write-Host "Tagging $silverAmiValue"
    New-EC2Tag -Resource $silverAmiValue -Tag $bronzeNameTag
    

    # Deprecate previous Bronze to non-compliant
    Write-Host "Updating SSM Parameters, $bronzeAmiValue is now non-compliant, and is no longer tracked in Parameter Store"

    $ncNameTag = New-Object Amazon.EC2.Model.Tag
    $ncNameTag.Key = "Name"
    $ncNameTag.Value = "nc-" + $name
    
    Write-Host "Tagging $bronzeAmiValue"
    New-EC2Tag -Resource $bronzeAmiValue -Tag $ncNameTag

    Share-Amis -imageId $imageId -name $name
}

function Share-Amis{

    param(
        $imageId,
        $name
    )
    
    ### UPDATE ###
    $targetAccounts = @(
    ""
    ""
    )

    foreach ($i in $targetAccounts){
        Write-Host "Sharing $imageId to $i"
        Edit-EC2ImageAttribute -ImageId $imageId -Attribute launchPermission -OperationType add -UserId $i
        Tag-SharedAmis -goldAmiValue $goldAmiValue -silverAmiValue $silverAmiValue -bronzeAmiValue $bronzeAmiValue -imageId $imageId -goldNameTag $goldNameTag -silverNameTag $silverNameTag -bronzeNameTag $bronzeNameTag -ncNameTag $ncNameTag -targetAccount $i
    }
}

function Tag-SharedAmis {

    param(
        $goldAmiValue,
        $silverAmiValue,
        $bronzeAmiValue,
        $imageId,
        $goldNameTag,
        $silverNameTag,
        $bronzeNameTag,
        $ncNameTag,
        $targetAccount
    )

    # Set Credential for Target Account
    $roleName = "lambda_ami_share_role"
	$roleArn = "arn:aws-us-gov:iam::"+ $targetAccount + ":role/" + $roleName
    Write-Host "Generating a temporary credential using role $roleName for acccount $targetAccount"   
    $credential = (Use-STSRole -RoleArn $roleArn -DurationInSeconds 3600 -RoleSessionName "LambdaAmiShare").Credentials
    Set-AWSCredentials -AccessKey $credential.AccessKeyId -SecretKey $credential.SecretAccessKey -SessionToken $credential.SessionToken

    # Tag Shared AMIs in Target Account
    Write-Host "Tagging $imageId"
    New-EC2Tag -Resource $imageId -Tag $goldNameTag
    Write-Host "Tagging $goldAmiValue"
    New-EC2Tag -Resource $goldAmiValue -Tag $silverNameTag
    Write-Host "Tagging $silverAmiValue"
    New-EC2Tag -Resource $silverAmiValue -Tag $bronzeNameTag
    Write-Host "Tagging $bronzeAmiValue"
    New-EC2Tag -Resource $bronzeAmiValue -Tag $ncNameTag
}

Check-Parameter
