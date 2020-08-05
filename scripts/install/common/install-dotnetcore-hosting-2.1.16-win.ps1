<#
.SYNOPSIS
Installs / Configures Microsoft .NET Core 2.1.16 Windows Server Hosting

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
 [Parameter(Mandatory = $False)] [String] $pattern = "dotnet-hosting-2.1.16-win*exe", # should have 1 wild card and end with file extension
 [Parameter(Mandatory = $False)] [String] $expectedpath ="C:\programdata\checkmarx\automation\dependencies",
 [Parameter(Mandatory = $False)] [String] $s3prefix = "installation/common", 
 [Parameter(Mandatory = $False)] [String] $sourceUrl = "https://download.visualstudio.microsoft.com/download/pr/5a059308-c27a-4223-b04d-0e815dce2cd0/10f528c237fed56192ea22283d81c409/dotnet-hosting-2.1.16-win.exe"
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

log "Installing..."
Start-Process -FilePath "$installer" -ArgumentList "/quiet /install /norestart" -Wait -NoNewWindow
log "Finished installing. Restarting IIS..."
iisreset
log "Finished installing"
