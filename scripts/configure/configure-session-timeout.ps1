<#
.SYNOPSIS
  Configures ASP.NET Session Timeout
#>

param (
 [Parameter(Mandatory = $False)] [String] $timeout = "00:15:00"
)

# Force TLS 1.2+ and hide progress bars to prevent slow downloads
Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; 
$ProgressPreference = "SilentlyContinue"

function log([string] $msg) { Write-Host "$(Get-Date -Format G) [$PSCommandPath] $msg" }

Class CxWebSessionTimeoutConfigurer {
    [String] $timeout
    
    CxWebSessionTimeoutConfigurer([String] $timeout) {
      $this.timeout = $timeout  
    }
  
    Configure() { 
      log "Configuring Timeout for CxSAST Web Portal to: $($this.timeout)"
      # Session timeout if you wish to change it. Default is 1440 minutes (1 day) 
      # Set-WebConfigurationProperty cmdlet is smart enough to convert it into minutes, which is what .net uses
      # See https://checkmarx.atlassian.net/wiki/spaces/PTS/pages/85229666/Configuring+session+timeout+in+Checkmarx
      # See https://blogs.iis.net/jeonghwan/iis-powershell-user-guide-comparing-representative-iis-ui-tasks for examples
      # $sessionTimeoutInMinutes = "01:20:00" # 1 hour 20 minutes - must use timespan format here (HH:MM:SS) and do NOT set any seconds as seconds are invalid options.
      # Prefer this over direct XML file access to support variety of session state providers
      Set-WebConfigurationProperty -pspath 'MACHINE/WEBROOT/APPHOST/Default Web Site/CxWebClient' -filter "system.web/sessionState" -name "timeout" -value "$($this.timeout)"
    }
  }

[CxWebSessionTimeoutConfigurer]::new($timeout).Configure()
