<#
.SYNOPSIS
  Obtains ssl certificates from letsencrypt.org using the Posh-ACME Route 53 Plugin

  The LetsEncrypt.org production environment (LE_PROD) is used by default. 
  Pass the -LE_STAGE switch to use the LetsEncrypt.org staging environment (useful when developing).
#>

# Initializes ssl using letsencrypt.org with the route 53 dns plugin
param (
 [Parameter(Mandatory = $True)] [String] $domain = "ben.dev.checkmarx-ts.com",
 [Parameter(Mandatory = $false)] [String] $password = "",
 [Parameter(Mandatory = $false)] [String] $email ="ben.stokes@checkmarx.com",
 [Parameter(Mandatory = $False)] [switch] $Renewal,
 [Parameter(Mandatory = $False)] [switch] $LE_STAGE
)

# Force TLS 1.2+ and hide progress bars to prevent slow downloads
Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; 
$ProgressPreference = "SilentlyContinue"

function log([string] $msg) { Write-Host "$(Get-Date -Format G) [$PSCommandPath] $msg" }

log "Installing Posh-ACME Plugin"
# Get the Posh-ACME Plugin
Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
# Trust the PSGallery so we can install modules from it.
Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
Install-Module -Name Posh-ACME

if ($LE_STAGE.IsPresent) {
  log "Configuring LetsEncrypt.org Environment: LE_STAGE"
  Set-PAServer LE_STAGE
} else {
  log "Configuring LetsEncrypt.org Environment: LE_PROD"
  Set-PAServer LE_PROD
}

if ($Renewal.IsPresent) {
  log "Renewing certificate for $domain"
  Set-PAOrder $domain
  if ($certs = Submit-Renewal -Force) {   
    log "Certs are here: $(($certs).PfxFile)"
  } else {
    log "There was an issue with renewal"
  }
} else {
  log "Requesting certificate for $domain by $email"
  New-PACertificate $domain -AcceptTOS -Contact $email -DnsPlugin Route53 -PluginArgs @{R53UseIAMRole=$true} -Verbose -PfxPass "$password" -DNSSleep 120
  $certs = Get-PACertificate
  log "Certs are here: $(($certs).PfxFile)"
}
