<#
.SYNOPSIS
Installs / Configures IIS
#>

# Force TLS 1.2+ and hide progress bars to prevent slow downloads
Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; 
$ProgressPreference = "SilentlyContinue"

. $PSScriptRoot\..\..\CheckmarxAWS.ps1

# Install IIS
log "Installing IIS..."

Install-WindowsFeature -name Web-Server -IncludeManagementTools
Add-WindowsFeature Web-Http-Redirect  
Install-WindowsFeature -Name  Web-Health -IncludeAllSubFeature
Install-WindowsFeature -Name  Web-Performance -IncludeAllSubFeature
Install-WindowsFeature -Name Web-Security -IncludeAllSubFeature
Install-WindowsFeature -Name  Web-Scripting-Tools -IncludeAllSubFeature
   
log "Finished installing IIS"
