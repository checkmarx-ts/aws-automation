md -force "C:\Program Files\Checkmarx\Logs\Automation"
Start-Transcript -Path "C:\Program Files\Checkmarx\Logs\Automation\register-asg-engines.log" 

# Force TLS 1.2
Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; 

$config = Import-PowerShellDataFile -Path C:\checkmarx-config.psd1
. $PSScriptRoot\..\CheckmarxAWS.ps1

function Get-JsonSsmParam ([string] $ssmpath) {
    $json = $(Get-SSMParameter -Name "$ssmpath" -WithDecryption $True).Value
    $ps_params = $json | ConvertFrom-Json
    return $ps_params
}

###############################################################################
# Get secrets
###############################################################################
$secrets = ""
$begin = (Get-Date)
$CxApiParams = Get-JsonSsmParam "$($config.Aws.SsmPath)/api"

$CxApiParams.username
$CxApiParams.url # URL is not used, instead we use the internal ec2 localhostname

$url = get-ec2instancemetadata -Category LocalHostname

[CxEnginesApiClient] $api = [CxEnginesApiClient]::new($CxApiParams.username, $CxApiParams.password, $url)
$api.Login()

# Unregister dead engines
$api.GetEngines() | ForEach-Object {
    if ($_.status.value.ToUpper() -eq "OFFLINE") {
        Write-Host "Unregistering engine $($_.name) because it is offline"
        $api.UnregisterEngine($_.id)
    }    
}

# Register live engines
(Get-Ec2Instance -Filter @{Name="tag:Environment";Value="$($env:CheckmarxEnvironment)"}, @{Name="tag-key";Value="checkmarx:engine:loc:min"}).Instances | ForEach-Object {

    if ([String]::IsNullOrEmpty($_.PrivateDnsName)) {
        return
    }

    $_.PrivateDnsName
    $_.State # "running"
    $min_loc = $_.Tags | where { $_.key -eq "checkmarx:engine:loc:min" } | select -ExpandProperty Value
    $max_loc = $_.Tags | where { $_.key -eq "checkmarx:engine:loc:max" } | select -ExpandProperty Value
    #$engineServer = @{ name=$_.PrivateDnsName; uri="https://$($_.PrivateDnsName)/CxSourceAnalyzerEngineWCF/CxEngineWebServices.svc"; minLoc=$min_loc; maxLoc=$max_loc; isBlocked=$False; maxScans = 2 }
    $engineServer = @{ name=$_.PrivateDnsName; uri="https://$($_.PrivateDnsName):8088"; minLoc=$min_loc; maxLoc=$max_loc; isBlocked=$False; maxScans = 2 }
    $existingEngine = $api.FindEngineIdByName($_.PrivateDnsName)
    if ($null -eq $existingEngine) { 
        Write-Host "Registering engine $($_.name)"
        $api.RegisterEngine($engineServer)
    } else {
        Write-Host "engine $($_.name) is already registered"
    }
  
    # Engine servers should upload their self signed certs to the checkmarx s3 bucket so that we can sync them onto the manager to trust their self signed certs        
    #$engineService = "https://$($_.PrivateDnsName)/CxSourceAnalyzerEngineWCF/CxEngineWebServices.svc"
    $engineService = "https://$($_.PrivateDnsName):8088"

    # IF the cert is not on the machine filesystem yet, then we haven't imported it, so download it from s3 and import.
    if (!(Test-Path -Path "C:\programdata\checkmarx\ssl\certs\$($_.PrivateDnsName).cer")) {
        try {
            Read-S3Object -BucketName $env:CheckmarxBucket -Key "ssl/certs/$($_.PrivateDnsName).cer" -File "C:\programdata\checkmarx\ssl\certs\$($_.PrivateDnsName).cer"
            Import-Certificate -FilePath "C:\programdata\checkmarx\ssl\certs\$($_.PrivateDnsName).cer" -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
            Import-Certificate -FilePath "C:\programdata\checkmarx\ssl\certs\$($_.PrivateDnsName).cer" -CertStoreLocation Cert:\LocalMachine\TrustedPublisher | Out-Null  
        } catch {
            Write-Host "Error downloading the cert from s3 and importing it to trust root"
            $_
        }
    }
}
