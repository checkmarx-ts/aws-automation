<#
.SYNOPSIS
  Configures IIS to reverse proxy CxArm components. 
#>

param (
 [Parameter(Mandatory = $False)] [String] $arm_server = "http://localhost:8080"
)

# Force TLS 1.2+ and hide progress bars to prevent slow downloads
Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; 
$ProgressPreference = "SilentlyContinue"

function log([string] $msg) { Write-Host "$(Get-Date -Format G) [$PSCommandPath] $msg" }

log "Enabling proxy functionality in IIS"
# Enable Proxy
Set-WebConfigurationProperty -pspath 'MACHINE/WEBROOT/APPHOST'  -filter "system.webServer/proxy" -name "enabled" -value "True"


log "Adding rewrite-rule for /cxarm -> ${arm_server}"
$site = "iis:\sites\Default Web Site"
$filterRoot = "system.webServer/rewrite/rules/rule[@name='cxarm']"
Add-WebConfigurationProperty -pspath $site -filter "system.webServer/rewrite/rules" -name "." -value @{name='cxarm';patternSyntax='Regular Expressions';stopProcessing='False'}
Set-WebConfigurationProperty -pspath $site -filter "$filterRoot/match" -name "url" -value "^(cxarm/.*)"
Set-WebConfigurationProperty -pspath $site -filter "$filterRoot/action" -name "type" -value "Rewrite"
Set-WebConfigurationProperty -pspath $site -filter "$filterRoot/action" -name "url" -value "${arm_server}/{R:0}"
