<#
.SYNOPSIS
  Allows an EC2 instance, using it's IAM Role, to update its own R53 DNS record.

  If the EC2 instance has a tag "dns" then this script will upsert R53 to route
  the name to the EC2 instance. The dns tag value must match a hosted zone in route 53.
#>

param (
 [Parameter(Mandatory = $False)] [String] $TTL = "180"
)

# Force TLS 1.2+ and hide progress bars to prevent slow downloads
Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; 
$ProgressPreference = "SilentlyContinue"

function log([string] $msg) { Write-Host "$(Get-Date -Format G) [$PSCommandPath] $msg" }

<####################################################
  Search for the dns name specified by the dns tag
#####################################################>
$tags = Get-EC2Tag -filter @{Name="resource-id";Value="$(Get-EC2InstanceMetaData -Category InstanceId)"}
[string]$dns = $tags | Where-Object { $_.Key -eq "checkmarx:dns" } | Select-Object -ExpandProperty Value
if ([String]::IsNullOrEmpty($dns)) { log "No dns tag found"; exit 1 }
log "Found dns tag: $dns"

<####################################################
  Search for matching hosted zone of the domain
#####################################################>
log "Searching for hosted zone..."
$hosted_zones = Get-R53HostedZoneList
$matched_zone = $hosted_zones | Where-Object { $dns.Contains($_.Name.TrimEnd(".")) } | Select-Object -First 1

if ($null -eq $matched_zone) { log "No hosted zone found."; exit 1 }
log "Found $($matched_zone.Id) $($matched_zone.Name)"
$subdomain = $dns.Replace($($matched_zone).Name.TrimEnd("."), "")
log "Subdomain is $subdomain"
$public_ipv4 = Get-EC2InstanceMetadata -Category PublicIpv4
$HOSTED_ZONE_ID = $matched_zone.Id

<####################################################
 Prepare and submit the Route53 Record
#####################################################>
log "Building change request to route $dns to $public_ipv4 w/ TTL $TTL"
$changeRequest01 = New-Object -TypeName Amazon.Route53.Model.Change
$changeRequest01.Action = "UPSERT"
$changeRequest01.ResourceRecordSet = New-Object -TypeName Amazon.Route53.Model.ResourceRecordSet
$changeRequest01.ResourceRecordSet.Name = "$dns"
$changeRequest01.ResourceRecordSet.Type = "A"
$changeRequest01.ResourceRecordSet.TTL = $TTL
$changeRequest01.ResourceRecordSet.ResourceRecords.Add(@{Value = "$public_ipv4"})

log "submitting change"
Edit-R53ResourceRecordSet `
	-HostedZoneId $HOSTED_ZONE_ID `
	-ChangeBatch_Change @($changeRequest01)

log "done"
