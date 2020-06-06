<#
.SYNOPSIS
Configures max scans per machine for Checkmarx CxSAST Engine Servers
#>

param (
 [Parameter(Mandatory = $False)] [String] $scans = "1"
)

# Force TLS 1.2+ and hide progress bars to prevent slow downloads
Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; 
$ProgressPreference = "SilentlyContinue"

function log([string] $msg) { Write-Host "$(Get-Date -Format G) [$PSCommandPath] $msg" }

Try {
 $config_file = Get-Content "$(Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Checkmarx\Installation\Checkmarx Engine Server' -Name 'Path')\CxSourceAnalyzerEngine.WinService.exe.config"
} catch {
  log "ERROR: couldn't get engine config file"
  log $_.Exception
}

if ([String]::IsNullOrEmpty($config_file)) {
  log "Config file was not found, nothing to configure. Is this an engine server?"
  exit 1
}

[Xml]$xml = Get-Content "$config_file"
$obj = $xml.configuration.appSettings.add | where {$_.Key -eq "MAX_SCANS_PER_MACHINE" }
log "MAX_SCANS_PER_MACHINE initial value is $($obj.value)"
$obj.value = "$scans" 
$xml.Save("$config_file")    

log "Finished configuring"
