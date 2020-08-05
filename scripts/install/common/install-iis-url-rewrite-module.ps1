<#
.SYNOPSIS
Installs / Configures IIS and Microsoft URL Rewrite Module 2.0 for IIS (x64)

.NOTES
The installer file is determined in this order:
  IF the installer argument is passed then:
    - the absolute path will be used as the installer
    - neither the local expected path or s3 bucket will be searched
    - no download over the internet will take place
  OTHERWISE the installation file will be searched for in this order
    1. The local expected path i.e. c:\programdata\checkmarx\ will be searched for a file that matches the typical installer filename. This allows you to place an installer here via any means
    2. IF the CheckmarxBucket environment variable is set, the bucket will be searched for a file that matches the typical installer filename with an appropriate key prefix (ie installation/common)
  AS A LAST RESORT
    The latest version will be download from the offical source over the internet 

  * When searching based on file prefix, if more than 1 file is found the files are sorted by file name and the first file is selected. This typically will mean the most recent version available is selected. 

#>

param (
 [Parameter(Mandatory = $False)] [String] $installer,
 [Parameter(Mandatory = $False)] [String] $pattern = "rewrite_amd64*msi", # should have 1 wild card and end with file extension
 [Parameter(Mandatory = $False)] [String] $expectedpath ="C:\programdata\checkmarx\automation\dependencies",
 [Parameter(Mandatory = $False)] [String] $s3prefix = "installation/common", 
 [Parameter(Mandatory = $False)] [String] $sourceUrl = "https://download.microsoft.com/download/C/9/E/C9E8180D-4E51-40A6-A9BF-776990D8BCA9/rewrite_amd64.msi"
 )
 
 # Force TLS 1.2+ and hide progress bars to prevent slow downloads
 Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; 
 $ProgressPreference = "SilentlyContinue"
 
 . $PSScriptRoot\..\..\CheckmarxAWS.ps1
 
 # Main execution begins here
  if ([String]::IsNullOrEmpty($installer)) {
     [InstallerLocator] $locator = [InstallerLocator]::New($pattern, $expectedpath, $s3prefix, $sourceUrl)
     $locator.Locate()
     $installer = $locator.installer
 }
 

log "Installing the IIS Rewrite module"
# Install the rewrite module
Start-Process "C:\Windows\System32\msiexec.exe" -ArgumentList "/i `"$installer`" /L*V `"$expectedPath\$(Get-Date -Format "yyyy-MM-dd-HHmmss")-rewrite_install.log`" /QN" -Wait -NoNewWindow
if (Test-Path "$expectedPath\rewrite_install.log") { log "Last 50 lines of installer:"; Get-content -tail 50 "$expectedPath\rewrite_install.log" }
log "Finished installing. Log file is at $expectedPath\rewrite_install.log."
