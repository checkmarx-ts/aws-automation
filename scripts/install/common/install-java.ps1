<#
.SYNOPSIS
Installs / Configures AdoptOpenJDK Java

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
 [Parameter(Mandatory = $False)] [String] $pattern = "OpenJDK8U*msi", # should have 1 wild card and end with file extension
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

function DownloadJDK8() {
  $jdk = (Invoke-RestMethod -Method GET -Uri "https://api.adoptopenjdk.net/v3/assets/latest/8/hotspot" -UseBasicParsing).binary | Where-Object { $_.architecture -eq "x64" -and $_.heap_size -eq "normal" -and $_.image_type -eq "jdk" -and $_.jvm_impl -eq "hotspot" -and $_.os -eq "windows" }
  $jdk_file = $jdk.installer.link.Substring($jdk.installer.link.LastIndexOf("/") + 1)
  log "Downloading from $($jdk.installer.link)"
  Invoke-WebRequest -UseBasicParsing -Uri "$($jdk.installer.link)" -OutFile "${expectedpath}\${jdk_file}"
  log "Downloaded $jdk.installer.link"
  return "${expectedpath}\${jdk_file}"
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
  $installer = DownloadJDK8
}

if (!(Test-Path "$installer")) {
  log "ERROR: No file exists at $installer"
  exit 1
} 

log "Installing from $installer"
Start-Process "C:\Windows\System32\msiexec.exe" -ArgumentList "/i `"$installer`" ADDLOCAL=FeatureMain,FeatureEnvironment,FeatureJarFileRunWith,FeatureJavaHome INSTALLDIR=`"c:\Program Files\AdoptOpenJDK\`" /quiet /L*V `"$installer.log`" " -Wait -NoNewWindow

if (Test-Path "${installer}.log") { log "Last 50 lines of installer:"; Get-content -tail 50 "${installer}.log" }
log "Finished installing. Log file is at ${installer}.log."