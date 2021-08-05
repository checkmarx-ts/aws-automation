<#
    This script will create a self signed certificate for the current machine
    and place the server.pfx file in the checkmarx automation folder. The 
    provisioning script will look for the server.pfx file there and will use it.
#>

param (
 [Parameter(Mandatory = $False)] [String] $pfxpassword = "",
 [Parameter(Mandatory = $False)] [String] $domainname = ""
 )

 # Force TLS 1.2+ and hide progress bars to prevent slow downloads
Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; 
$ProgressPreference = "SilentlyContinue"
function log([string] $msg) { Write-Host "$(Get-Date) [$PSCommandPath] $msg" }

Write-Host "$(Get-Date) Script is running with arguments:"
Write-Host "$(Get-Date) pfxpassword = $pfxpassword"
Write-Host "$(Get-Date) domainname = $domainname"


$serverNames = @(
    $domainname,
    (get-ec2instancemetadata -Category LocalHostname),
    (get-ec2instancemetadata -Category PublicHostname),
    $env:COMPUTERNAME   
)
Write-Host "$(Get-Date) Generating self signed certificate with $($serverNames -join ",")."
$ssc = New-SelfSignedCertificate -DnsName $serverNames -CertStoreLocation "cert:\LocalMachine\My"

log "Certificate created:"
$ssc 
log "ensuring c:\programdata\checkmarx\ssl folder exists"
md -force "C:\programdata\checkmarx\ssl" 
log "exporting certificate to C:\programdata\checkmarx\ssl\server.pfx"
$ssc | Export-PfxCertificate -FilePath "C:\programdata\checkmarx\ssl\server.pfx" -Password (ConvertTo-SecureString $pfxpassword -AsPlainText -Force)
log "removing the certificate from the windows cert store"
$ssc | Remove-Item 
log "Done. The self signed cert is on the file system ready to be used in SSL configuration"
