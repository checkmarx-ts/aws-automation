<#
.SYNOPSIS
Installs / Configures Microsoft Visual C++ 2015 Redistributable Update 3 RC

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
 [Parameter(Mandatory = $False)] [String] $pattern = "vc_redist2015.x64*exe", # should have 1 wild card and end with file extension
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

function Download() {
  Invoke-WebRequest -UseBasicParsing -Uri "https://download.microsoft.com/download/0/6/4/064F84EA-D1DB-4EAA-9A5C-CC2F0FF6A638/vc_redist.x64.exe" -OutFile (Join-Path $expectedPath "vc_redist2015.x64.exe")
  return (Join-Path $expectedPath "vc_redist2015.x64.exe")
}


# Defend against trailing paths that will cause errors
$expectedpath = $expectedpath.TrimEnd("\")
$s3prefix = $s3prefix.TrimEnd("/")
md -force "$expectedpath" | Out-Null

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
  $installer = Download
}

if (!(Test-Path "$installer")) {
  log "ERROR: No file exists at $installer"
  exit 1
} 

log "Installing from $installer"
Start-Process -FilePath "$installer" -ArgumentList "/passive /norestart" -Wait   

if (Test-Path "${installer}.log") { log "Last 50 lines of installer:"; Get-content -tail 50 "${installer}.log" }
log "Finished installing. Log file is at ${installer}.log."
