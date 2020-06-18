<#
.SYNOPSIS
Applies some hardening/configuration to IIS
#>

# Force TLS 1.2+ and hide progress bars to prevent slow downloads
Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; 
$ProgressPreference = "SilentlyContinue"

function log([string] $msg) { Write-Host "$(Get-Date -Format G) [$PSCommandPath] $msg" }

log "Add rewrite rules to CxWebClient for ease of use"
# Depends on Rewrite Module installed
try {
  Add-WebConfigurationProperty -pspath 'MACHINE/WEBROOT/APPHOST/Default Web Site' -filter "system.webServer/rewrite/rules" -name "." -value @{name='RedirectRootToCxWebClient';stopProcessing='True'}
  Set-WebConfigurationProperty -pspath 'MACHINE/WEBROOT/APPHOST/Default Web Site' -filter "system.webServer/rewrite/rules/rule[@name='RedirectRootToCxWebClient']/match" -name "url" -value "^$"
  Set-WebConfigurationProperty -pspath 'MACHINE/WEBROOT/APPHOST/Default Web Site' -filter "system.webServer/rewrite/rules/rule[@name='RedirectRootToCxWebClient']/action" -name "url" -value "/CxWebClient/"
  Set-WebConfigurationProperty -pspath 'MACHINE/WEBROOT/APPHOST/Default Web Site' -filter "system.webServer/rewrite/rules/rule[@name='RedirectRootToCxWebClient']/action" -name "type" -value "Redirect"
} catch {
  log "Error configuring rewrites"
  log $_.Exception.ToString()
}

try {
log "Remove default documents"
  Clear-WebConfiguration -PSPath "MACHINE/WEBROOT/APPHOST" -Filter "system.webServer/defaultDocument/files"
} catch {
  log "Error removing default documents"
  log $_.Exception.ToString()
}

try {
log "Disable Powered By header"
  Remove-WebConfigurationProperty  -pspath 'MACHINE/WEBROOT/APPHOST' -filter "system.webServer/httpProtocol/customHeaders" -name "." -AtElement @{name='X-Powered-By'}
} catch {
  log "Error disabling powered by header"
  log $_.Exception.ToString()
}

try {
log "Disable server header"
  Set-WebConfigurationProperty -pspath 'MACHINE/WEBROOT/APPHOST' -filter "system.webServer/security/requestFiltering" -name "removeServerHeader" -value "True"
} catch {
  log "Error disabling server header"
  log $_.Exception.ToString()
}

try {
  log "Disable dotnet header"
   "CxWebClient", "CxRestAPI", "CxWebInterface" | ForEach-Object {
    Set-WebConfigurationProperty -pspath "MACHINE/WEBROOT/APPHOST/Default Web Site/$_" -filter "system.web/httpRuntime" -name "enableVersionHeader" -value "false"
  } 
} catch {
  log "Error disabling dotnet header"
  log $_.Exception.ToString()
}

try {
  log "Configure application inititialization"
  Enable-WindowsOptionalFeature -Online -FeatureName IIS-ApplicationInit  
  Write-Host "Configuring startMode on application pools"       
  Set-WebConfigurationProperty -pspath 'MACHINE/WEBROOT/APPHOST'  -filter "system.applicationHost/applicationPools/add[@name='CxPool']" -name "startMode" -value "AlwaysRunning"
  Set-WebConfigurationProperty -pspath 'MACHINE/WEBROOT/APPHOST'  -filter "system.applicationHost/applicationPools/add[@name='CxPoolRestAPI']" -name "startMode" -value "AlwaysRunning"
  Set-WebConfigurationProperty -pspath 'MACHINE/WEBROOT/APPHOST'  -filter "system.applicationHost/applicationPools/add[@name='CxClientPool']" -name "startMode" -value "AlwaysRunning"

  Write-Host "Configuring preloadEnabled on applications"
  Set-WebConfigurationProperty -pspath 'MACHINE/WEBROOT/APPHOST'  -filter "system.applicationHost/sites/site[@name='Default Web Site']/application[@path='/CxWebClient']" -name "preloadEnabled" -value "True"
  Set-WebConfigurationProperty -pspath 'MACHINE/WEBROOT/APPHOST'  -filter "system.applicationHost/sites/site[@name='Default Web Site']/application[@path='/CxWebInterface']" -name "preloadEnabled" -value "True"
  Set-WebConfigurationProperty -pspath 'MACHINE/WEBROOT/APPHOST'  -filter "system.applicationHost/sites/site[@name='Default Web Site']/application[@path='/CxRestAPI']" -name "preloadEnabled" -value "True"

  Write-Host "Configuring applicationInitialization on website"
  Set-WebConfigurationProperty -pspath 'MACHINE/WEBROOT/APPHOST/Default Web Site' -filter "system.webServer/applicationInitialization" -name "skipManagedModules" -value "False"
  Set-WebConfigurationProperty -pspath 'MACHINE/WEBROOT/APPHOST/Default Web Site' -filter "system.webServer/applicationInitialization" -name "doAppInitAfterRestart" -value "True"
  Add-WebConfigurationProperty -pspath 'MACHINE/WEBROOT/APPHOST/Default Web Site' -filter "system.webServer/applicationInitialization" -name "." -value @{initializationPage='/CxWebClient/ProjectState.aspx'}
} catch {
  log "Error configuring application initialization"
  log $_.Exception.ToString()
}
log "Finished IIS Hardening"
