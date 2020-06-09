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
 [Parameter(Mandatory = $False)] [String] $pattern = "rewrite_amd64*msi", # should have 1 wild card and end with file extension
 [Parameter(Mandatory = $False)] [String] $arrpattern = "requestRouter_amd64*msi",
 [Parameter(Mandatory = $False)] [String] $expectedpath ="C:\programdata\checkmarx\automation\dependencies",
 [Parameter(Mandatory = $False)] [String] $s3prefix = "installation/common"   
)

# Force TLS 1.2+ and hide progress bars to prevent slow downloads
Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; 
$ProgressPreference = "SilentlyContinue"

function log([string] $msg) { Write-Host "$(Get-Date -Format G) [$PSCommandPath] $msg" }

function GetInstaller ([string] $pattern, [string] $expectedPath, [string] $s3prefix) {
    if (![String]::IsNullOrEmpty($installer)) {
      log "The specified file $installer will be used for install"
      return $installer
    } 

    $candidate = $(Get-ChildItem "$expectedpath" -Recurse -Filter "${pattern}" | Sort -Descending | Select -First 1 -ExpandProperty FullName)
    if (![String]::IsNullOrEmpty($candidate) -and (Test-Path $candidate)) {
      log "Found $candidate in expected path"
      return $candidate
    } else {
      log "Found no candidate in $expectedPath"
    }

    if ($env:CheckmarxBucket) {
      log "Searching s3://$env:CheckmarxBucket/$s3prefix/$pattern"
	    $s3pattern = $pattern.Substring(0, $pattern.IndexOf("*")) # remove anything after the first wild card
      $s3object = (Get-S3Object -BucketName $env:CheckmarxBucket -Prefix "$s3prefix/$s3pattern" | Select -ExpandProperty Key | Sort -Descending | Select -First 1)
      if (![String]::IsNullOrEmpty($s3object)) {
        log "Found s3://$env:CheckmarxBucket/$s3object"
        $filename = $s3object.Substring($s3object.LastIndexOf("/") + 1)
        Read-S3Object -BucketName $env:CheckmarxBucket -Key $s3object -File "$expectedpath\$filename"
        sleep 5
        $candidate = (Get-ChildItem "$expectedpath" -Recurse -Filter "${pattern}*" | Sort -Descending | Select -First 1 -ExpandProperty FullName).ToString()
        return [String]$candidate[0].FullName
      } else {
        log "Found no candidate in s3://$env:CheckmarxBucket/$s3prefix"
      }
    } else {
      log "No CheckmarxBucket environment variable defined - not searching s3"
    }
}

function DownloadRewrite() {
  log "Downloading from https://download.microsoft.com/download/C/9/E/C9E8180D-4E51-40A6-A9BF-776990D8BCA9/rewrite_amd64.msi"
  Invoke-WebRequest -UseBasicParsing -Uri "https://download.microsoft.com/download/C/9/E/C9E8180D-4E51-40A6-A9BF-776990D8BCA9/rewrite_amd64.msi" -OutFile "${expectedpath}\rewrite_amd64.msi"
  return "${expectedpath}\rewrite_amd64.msi"
}

function DownloadRequestRouter() {
  log "Downloading from http://download.microsoft.com/download/E/9/8/E9849D6A-020E-47E4-9FD0-A023E99B54EB/requestRouter_amd64.msi"
  Invoke-WebRequest -UseBasicParsing -Uri "http://download.microsoft.com/download/E/9/8/E9849D6A-020E-47E4-9FD0-A023E99B54EB/requestRouter_amd64.msi" -OutFile "${expectedpath}\requestRouter_amd64.msi"
  return "${expectedpath}\requestRouter_amd64.msi"
}

# Defend against trailing paths that will cause errors
$expectedpath = $expectedpath.TrimEnd("\")
$s3prefix = $s3prefix.TrimEnd("/")
md -force "$expectedpath" | Out-Null
$installer = ""
try {
  # Find the installer
  $installer = GetInstaller $pattern $expectedpath $s3prefix
} catch {
  Write-Error $_.Exception.ToString()
  log $_.Exception.ToString()
  $_
  log "ERROR: An error occured. Check IAM policies? Is AWS Powershell installed?"
  exit 1
}

# Last resort, try to get the installer over the internet
if ([String]::IsNullOrEmpty($installer)) {
  log "No installer found, attempting download from source"
  $installer = DownloadRewrite
}

if (!(Test-Path "$installer")) {
  log "ERROR: No file exists at $installer"
  exit 1
} 

$arr_installer = ""
try {
  # Find the installer
  $arr_installer = GetInstaller $arrpattern $expectedpath $s3prefix
} catch {
  Write-Error $_.Exception.ToString()
  log $_.Exception.ToString()
  $_
  log "ERROR: An error occured. Check IAM policies? Is AWS Powershell installed?"
  exit 1
}

# Last resort, try to get the installer over the internet
if ([String]::IsNullOrEmpty($arr_installer)) {
  log "No installer found, attempting download from source"
  $installer = DownloadRequestRouter
}

if (!(Test-Path "$arr_installer")) {
  log "ERROR: No file exists at $arr_installer"
  exit 1
} 

# Install IIS
log "Installing IIS..."
Install-WindowsFeature -name Web-Server -IncludeManagementTools
Add-WindowsFeature Web-Http-Redirect  
Install-WindowsFeature -Name  Web-Health -IncludeAllSubFeature
Install-WindowsFeature -Name  Web-Performance -IncludeAllSubFeature
Install-WindowsFeature -Name Web-Security -IncludeAllSubFeature
Install-WindowsFeature -Name  Web-Scripting-Tools -IncludeAllSubFeature
   
log "Finished installing IIS"
log "Installing the IIS Rewrite module"
# Install the rewrite module
Start-Process "C:\Windows\System32\msiexec.exe" -ArgumentList "/i `"$installer`" /L*V `"$expectedPath\$(Get-Date -Format "yyyy-MM-dd-HHmmss")-rewrite_install.log`" /QN" -Wait -NoNewWindow
log "Installing the IIS Request Router module"
Start-Process "C:\Windows\System32\msiexec.exe" -ArgumentList "/i `"$arr_installer`" /L*V `"$expectedPath\$(Get-Date -Format "yyyy-MM-dd-HHmmss")-router_install.log`" /QN" -Wait -NoNewWindow

if (Test-Path "$expectedPath\rewrite_install.log") { log "Last 50 lines of installer:"; Get-content -tail 50 "$expectedPath\rewrite_install.log" }
log "Finished installing. Log file is at $expectedPath\rewrite_install.log."

