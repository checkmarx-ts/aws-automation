<#
.SYNOPSIS
Configures Windows Defender for Checkmarx Servers. 
#>

param (
 [Parameter(Mandatory = $False)] [String] $scans = "1"
)

# Force TLS 1.2+ and hide progress bars to prevent slow downloads
Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; 
$ProgressPreference = "SilentlyContinue"

function log([string] $msg) { Write-Host "$(Get-Date -Format G) [$PSCommandPath] $msg" }

# Add exclusions
Add-MpPreference -ExclusionPath "C:\Program Files\Checkmarx\*"
Add-MpPreference -ExclusionPath "C:\CxSrc\*"  
Add-MpPreference -ExclusionPath "C:\ExtSrc\*"  

log "Finished configuring"
