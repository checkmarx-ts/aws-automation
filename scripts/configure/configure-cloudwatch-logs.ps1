<#
.SYNOPSIS
Downloads the cloud watch logs agent and configures log file collection

.NOTES
AWS recommends downloading the latest agent. 
#>

# Force TLS 1.2+ and hide progress bars to prevent slow downloads
Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; 
$ProgressPreference = "SilentlyContinue"

function log([string] $msg) { Write-Host "$(Get-Date -Format G) [$PSCommandPath] $msg" }

function CreateCollectListObject ([String] $log_group_name, [String] $filepath) {
    [hashtable]$properties = @{}
    $properties.Add("file_path", "$filepath")
    $properties.Add("log_group_name", "$log_group_name")
    $properties.Add("log_stream_name", "{instance_id}")
    $collect_list_object = New-Object -TypeName psobject -Property $properties
    return $collect_list_object
}

<###################################
  Check tag for environment name
###################################>
[String]$log_env = Get-EC2Tag -filter @{Name="resource-id";Value="${instance_id}"} | Where-Object { $_.Key -eq "Environment" } | Select-Object -ExpandProperty Value
if ([String]::IsNullOrEmpty($dns)) { 
    log "No Environment tag found, using default `"dev`""
    $log_env = "dev"
}
log "Environment: $log_env"

<###################################
 Build log file array
###################################>
$logfiles = [System.Collections.ArrayList]::new()

# CxSAST Engine Logs
$logfiles.Add((CreateCollectListObject "/checkmarx/$log_env/EngineAll.log" "C:\Program Files\Checkmarx\Checkmarx Engine Server\Logs\Trace\EngineAll.log"))
$logfiles.Add((CreateCollectListObject "/checkmarx/$log_env/EngineScanLogs" "C:\Program Files\Checkmarx\Checkmarx Engine Server\Engine Server\logs\ScanLogs\*\*.log"))

# CxManager logs
$logfiles.Add((CreateCollectListObject "/checkmarx/$log_env/CxJobsManagerAll.log" "C:\Program Files\Checkmarx\Logs\JobsManager\Trace\CxJobsManagerAll.log"))
$logfiles.Add((CreateCollectListObject "/checkmarx/$log_env/CxScanManagerAll.log" "C:\Program Files\Checkmarx\Logs\ScansManager\Trace\CxScanManagerAll.log"))
$logfiles.Add((CreateCollectListObject "/checkmarx/$log_env/CxSystemManagerAll.log" "C:\Program Files\Checkmarx\Logs\SystemManager\Trace\CxSystemManagerAll.log"))
$logfiles.Add((CreateCollectListObject "/checkmarx/$log_env/WebAPIAll.log" "C:\Program Files\Checkmarx\Logs\WebAPI\Trace\WebAPIAll.log"))
$logfiles.Add((CreateCollectListObject "/checkmarx/$log_env/ManagerWSAll.log" "C:\Program Files\Checkmarx\Logs\WebServices\Trace\ManagerWSAll.log"))

# CxWeb logs
$logfiles.Add((CreateCollectListObject "/checkmarx/$log_env/PortalAll.log" "C:\Program Files\Checkmarx\Logs\WebClient\Trace\PortalAll.log"))

# CxArm
$logfiles.Add((CreateCollectListObject "/checkmarx/$log_env/CxARM/Tomcat/cxarm.log" "C:\Program Files\Checkmarx\Logs\CxARM\Tomcat\cxarm.log"))
$logfiles.Add((CreateCollectListObject "/checkmarx/$log_env/CxARM/Tomcat/eventsReport.log" "C:\Program Files\Checkmarx\Logs\CxARM\Tomcat\eventsReport.log"))
$logfiles.Add((CreateCollectListObject "/checkmarx/$log_env/CxARM/ETL/SyncETL.log" "C:\Program Files\Checkmarx\Logs\CxARM\ETL\SyncETL.log"))
$logfiles.Add((CreateCollectListObject "/checkmarx/$log_env/CxARM/ETL/IncrementalSyncETL.log" "C:\Program Files\Checkmarx\Logs\CxARM\ETL\IncrementalSyncETL.log"))
# Todo: add activemq log

# IIS Logs
$logfiles.Add((CreateCollectListObject "/checkmarx/$log_env/iis/accesslogs" "C:\inetpub\logs\LogFiles\W3SVC1\u_ex*.log"))


<###################################
 Generate cloudwatch config file
###################################>
$configjson = $logfiles | ConvertTo-Json

$cloudwatch_config = @"
{
  "logs": {
    "logs_collected": {
      "files": {
	    "collect_list": ${configjson}
      }
    }	
  }
}
"@

log "Cloudwatch log config file generated is: "
$cloudwatch_config

md "C:\programdata\checkmarx\automation" -force 
$ConfigFile = "C:\programdata\checkmarx\automation\checkmarx-cloudwatch.json"
$cloudwatch_config | Set-Content $ConfigFile


If (-Not (Test-Path "C:\Program Files\Amazon\AmazonCloudWatchAgent\amazon-cloudwatch-agent-ctl.ps1")) {
    # Download the latest cloudwatch logs agent
    log "Downloading the latest cloudwatch logs agent..."
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072;
    $ProgressPreference = "SilentlyContinue"
    Invoke-WebRequest -Uri "https://s3.amazonaws.com/amazoncloudwatch-agent/windows/amd64/latest/amazon-cloudwatch-agent.msi" -OutFile "C:\programdata\checkmarx\automation\dependencies\amazon-cloudwatch-agent.msi" -UseBasicParsing

    # Install the agent
    Start-Process "C:\Windows\System32\msiexec.exe" -ArgumentList "/i `"C:\programdata\checkmarx\automation\dependencies\amazon-cloudwatch-agent.msi`" /QN /L*V `"C:\programdata\checkmarx\automation\dependencies\amazon-cloudwatch-agent.log`"" -Wait -NoNewWindow
    log "Cloudwatch agent installed. Log file:"
    cat "C:\programdata\checkmarx\automation\dependencies\amazon-cloudwatch-agent.log"
} else {
    log "The cloudwatch logs agent is already installed"
}

# Import the log configuration
log "Importing $ConfigFile"
$(powershell.exe -file 'C:\Program Files\Amazon\AmazonCloudWatchAgent\amazon-cloudwatch-agent-ctl.ps1' -a fetch-config -m ec2 -c file:"$($ConfigFile)" -s)
log "Finished configuring cloudwatch logs"
