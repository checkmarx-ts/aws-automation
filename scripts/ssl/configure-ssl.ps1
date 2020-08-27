<#
.SYNOPSIS
Configures Checkmarx Manager for SSL
  * IIS is configured with a https binding, http binding is removed
  * Resolver is configured to use SSL


.NOTES
If the cert information is not provided then the script will attempt to use Posh-ACME certs if available on the machine
(but it will not request new certs). 

#>
param (
 [Parameter(Mandatory = $False)] [String] $pfxfile = "",
 [Parameter(Mandatory = $False)] [String] $pfxpassword = "",
 [Parameter(Mandatory = $False)] [String] $domainname = ""
 )

# Force TLS 1.2+ and hide progress bars to prevent slow downloads
Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; 
$ProgressPreference = "SilentlyContinue"
function log([string] $msg) { Write-Host "$(Get-Date) [$PSCommandPath] $msg" }

function ConfigureIIS($thumbprint) {
    # Create an ssl binding in SSL and add cert to it
    log "Creating a new web binding for https"
    New-WebBinding -Name "Default Web Site" -Protocol "https" -Port 443 -SslFlags 1 -HostHeader *
    log "Adding certificate to https web binding"
    (Get-WebBinding -Name "Default Web Site" -Port 443 -Protocol "https").AddSslCertificate($thumbprint, "My")
    log "Removing http / port 80 web binding"
    Remove-WebBinding -Name "Default Web Site" -Port 80 -Protocol "http"
}

function ConfigureWSResolver([string] $domainname) {
    # Search for the web portal web.config file
    $cx_web_webconfig = ("{0}\web\{1}" -f (Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Checkmarx\Installation\CheckmarxWebPortal' -Name "Path" -ErrorAction SilentlyContinue), 'web.config')
    if ((Test-Path "$cx_web_webconfig")) {
      log "Updating the Checkmarx Web Portal web.config CxWSResolver.CxWSResolver key for ssl"
      [Xml]$xml = Get-Content $cx_web_webconfig
      $obj = $xml.configuration.appSettings.add | where {$_.Key -eq "CxWSResolver.CxWSResolver" }
      $obj.value = "https://${domainname}:443/Cxwebinterface/CxWSResolver.asmx"
      $xml.Save($cx_web_webconfig)
      log "... Finished"
    }
}

function UpdateHostsFile([string] $domainname) {
    # Update the hosts file so the manager talks to itself without going through any network infrastructure overhead that might exist at the fqdn
    $cx_manager_config = ("{0}\bin\{1}" -f (Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Checkmarx\Installation\Checkmarx Jobs Manager' -Name "Path" -ErrorAction SilentlyContinue), 'CxJobsManagerWinService.exe.config')
    if ((Test-Path "$cx_manager_config")) {
      log "Updating the hosts file to resolve $domainname to 127.0.0.1 to avoid load balancer round trips for web-to-services web-services"
      "# Checkmarx will resolve the servername to localhost to bypass load balancer hops for inner-app communication" | Add-Content -PassThru "$env:windir\system32\drivers\etc\hosts"
      "127.0.0.1 $domainname" | Add-Content -PassThru "$env:windir\system32\drivers\etc\hosts"
      log "... Finished"
    }
}


function ConfigureManagerServicesTransportSecurity() {
    # Find all the manager/web service's config files that have been installed and loop over them to configure transport security.
    @(
      ("{0}\bin\{1}" -f (Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Checkmarx\Installation\Checkmarx System Manager' -Name "Path" -ErrorAction SilentlyContinue), 'CxSystemManagerService.exe.config'),
      ("{0}\bin\{1}" -f (Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Checkmarx\Installation\Checkmarx Jobs Manager' -Name "Path" -ErrorAction SilentlyContinue), 'CxJobsManagerWinService.exe.config'),
      ("{0}\bin\{1}" -f (Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Checkmarx\Installation\Checkmarx Scans Manager' -Name "Path" -ErrorAction SilentlyContinue), 'CxScansManagerWinService.exe.config'),
      ("{0}\web\{1}" -f (Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Checkmarx\Installation\CheckmarxWebPortal' -Name "Path" -ErrorAction SilentlyContinue), 'web.config'),
      ("{0}\CxWebInterface\{1}" -f (Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Checkmarx\Installation\Checkmarx Web Services' -Name "Path" -ErrorAction SilentlyContinue), 'web.config'),
      ("{0}\CxRestAPI\{1}" -f (Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Checkmarx\Installation\Checkmarx Web Services' -Name "PathRestAPI" -ErrorAction SilentlyContinue), 'web.config')
    ) | ForEach-Object {
        # Guard clause on existance
        log "Checking if $_ exists"
        if ((Test-Path "$_")) {
            log "Found $_"
        } else {
            log "Skipping file that doesn't exist: $_"
            continue
        }

        # Set transport security mode
        [Xml]$xml = Get-Content "$_"
        log "Adding security mode = Transport"
        $bindingNode = Select-Xml -xml $xml -XPath "/configuration/*/bindings/basicHttpBinding/binding" 
        $securityNode = $bindingNode.Node.SelectSingleNode('security')
        if (!$securityNode){
          $securityNode = $xml.CreateElement('security')
          $bindingNode.Node.AppendChild($securityNode)  | Out-Null
        }
        $securityNode.SetAttribute("mode", "Transport")
        $xml.Save("$_")
    
        log "Finished configuring transport security on $_"
    }
}

function ConfigureEngineTls([string] $domainname, [string] $thumbprint) {
    # If there is an engine on the machine - it needs some unique configuration
    $engine_config = ("{0}\{1}" -f ( Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Checkmarx\Installation\Checkmarx Engine Server' -Name 'Path' -ErrorAction SilentlyContinue), 'CxSourceAnalyzerEngine.WinService.exe.config')
    if (!(Test-Path "$engine_config")) {
      log "No engine was detected on this machine. "
    } else {
      log "An engine was detected on this machine. It will be configured for TLS."
      # Configure netsh cert and url pattern reservation
      $appid = "{00112233-4455-6677-8899-AABBCCDDEEFF}"
      $ipport = "0.0.0.0:443"
      $scratch = Join-Path $env:TEMP $(New-Guid) 
      md -force $scratch
      Start-Process "netsh.exe" -ArgumentList "http add sslcert ipport=${ipport} certhash=${thumbprint} appid={$appid}" -Wait -NoNewWindow -RedirectStandardError "${scratch}\netsh.out" -RedirectStandardOutput "${scratch}\netsh.err"
      log "Log of netsh http add sslcert:"
      log "netsh.out file:"
      cat "${scratch}\netsh.out"
      log "netsh.err file:"
      cat "${scratch}\netsh.err"    

      Start-Process "netsh.exe" -ArgumentList "http add urlacl url=https://+:443/CxSourceAnalyzerEngineWCF/CxEngineWebServices.svc user=`"NT AUTHORITY\NETWORK SERVICE`"" -Wait -NoNewWindow -RedirectStandardError "${scratch}\netsh.out" -RedirectStandardOutput "${scratch}\netsh.err"
      log "Log of netsh http add urlacl:"
      log "netsh.out file:"
      cat "${scratch}\netsh.out"
      log "netsh.err file:"
      cat "${scratch}\netsh.err"          

      # Configure transport,binding,baseaddress
      [Xml]$xml = Get-Content "$engine_config"
      log "Adding security mode = Transport"
      $bindingNode = Select-Xml -xml $xml -XPath "/configuration/*/bindings/basicHttpBinding/binding" 
      $securityNode = $bindingNode.Node.SelectSingleNode('security')
      if (!$securityNode){
        $securityNode = $xml.CreateElement('security')
        $bindingNode.Node.AppendChild($securityNode)  | Out-Null
      }
      $securityNode.SetAttribute("mode", "Transport")

      log "Setting mexHttpsBinding"
      $mexNode = $xml.SelectSingleNode("/configuration/*/services/service/endpoint[@address='mex']")
      if (!$mexNode) { log "WARN: \<endpoint address=`"mex`" not found in $($engine_config)" }
      $mexNode.SetAttribute("binding", "mexHttpsBinding")
  
      log "Configuring baseAddress"
      $hostNode = $xml.SelectSingleNode("/configuration/*/services/service/host/baseAddresses/add")     
      if (!$hostNode) {log "WARN: \<baseAddresses\>\<add\>... not found!" }
      [string]$hostAddress = $hostNode.SelectSingleNode("@baseAddress").Value
      $hostAddress = $hostAddress.Replace("http:", "https:").Replace(":80", ":443").Replace("localhost", $($domainname))
      $hostNode.SetAttribute("baseAddress", $hostAddress)
  
      log "Configuring httpsGetEnabled"
      $serviceNode = $xml.SelectSingleNode("/configuration/*/behaviors/serviceBehaviors/behavior/serviceMetadata")
      if (!$serviceNode) { log "WARN: \<serviceMetadata\> not found!" }
      $serviceNode.SetAttribute("httpsGetEnabled", "true")
      $serviceNode.RemoveAttribute("httpGetEnabled")
  
      log "saving $($engine_config)"
      $xml.Save($engine_config)
    }
}

function ConfigureAccessControl() {
  log "Configuring Checkmarx Access Control appsettings.json for SSL"
  $appsettings = "C:\Program Files\Checkmarx\Checkmarx Access Control\appsettings.json"
  if ((Test-Path $appsettings)) {
    $s = Get-Content "$appsettings" | ConvertFrom-Json
    $s.Host.ListenUrls = "https://*:443"
    $s.Host.ExternalListenUrls = "https://*:443"
    $s.Host.SslCertificate.Filename = $cert.PfxFile
    $s.Host.SslCertificate.Password = $cert.PfxPass
    $s | ConvertTo-Json | Set-Content $appsettings
  }
}

$Secure_String_Pwd = ConvertTo-SecureString $pfxpassword -AsPlainText -Force

if ([String]::IsNullOrEmpty($pfxfile) -and [String]::IsNullOrEmpty($domainname)) {
  log "No certificates provided, attempting to use Posh-ACME certs if available." 
  $cert = Get-PACertificate
  if ($cert -ne $null) {
    log "Posh-ACME cert found."
    $pfxfile = $cert.PfxFile
    $Secure_String_Pwd = $cert.PfxPass
    $domainname = $cert.AllSANs[0]
    $thumbprint = $cert.Thumbprint
  } else {
    log "Posh-ACME cert was not found. Searching for server.pfx file"
    $pfxfile = $(Get-ChildItem C:\programdata\checkmarx -Recurse -Filter "server.pfx" | Sort -Descending | Select -First 1 -ExpandProperty FullName)
  } 
} 

log "Validating arguments..."
if ([String]::IsNullOrEmpty($pfxfile) -or [String]::IsNullOrEmpty($domainname)) {
  log "ERROR: All or one of pfxfile, domainname, or thumbprint is empty."
  exit 1
}

# Import the cert to the machine on IIS
log "Importing the certificate into LocalMachine\My"
$cert = Import-PfxCertificate -FilePath $pfxfile -CertStoreLocation Cert:\LocalMachine\My -Password $Secure_String_Pwd

ConfigureIIS $domainname $cert.Thumbprint
ConfigureWSResolver $domainname
UpdateHostsFile $domainname
ConfigureManagerServicesTransportSecurity
ConfigureEngineTls $domainname $cert.Thumbprint
ConfigureAccessControl 

try {
    restart-service cx*
    iisreset
    ipconfig /flushdns
} catch {
    log "An error occured restarting services"
}

log "finished"