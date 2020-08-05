<#
.SYNOPSIS
Installs Application Request Routing Module for IIS (x64)

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
 [Parameter(Mandatory = $False)] [String] $pattern = "requestRouter_amd64*msi", # should have 1 wild card and end with file extension
 [Parameter(Mandatory = $False)] [String] $expectedpath ="C:\programdata\checkmarx\automation\dependencies",
 [Parameter(Mandatory = $False)] [String] $s3prefix = "installation/common", 
 [Parameter(Mandatory = $False)] [String] $sourceUrl = "http://download.microsoft.com/download/E/9/8/E9849D6A-020E-47E4-9FD0-A023E99B54EB/requestRouter_amd64.msi"
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
 
log "Installing the IIS Request Router module"
Start-Process "C:\Windows\System32\msiexec.exe" -ArgumentList "/i `"$installer`" /L*V `"$expectedPath\$(Get-Date -Format "yyyy-MM-dd-HHmmss")-router_install.log`" /QN" -Wait -NoNewWindow
log "Finished installing."
