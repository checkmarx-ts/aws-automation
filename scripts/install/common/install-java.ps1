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
 [Parameter(Mandatory = $False)] [String] $s3prefix = "installation/common", 
 [Parameter(Mandatory = $False)] [String] $sourceUrl = "https://api.adoptopenjdk.net/v3/assets/latest/8/hotspot"
 )
 
 # Force TLS 1.2+ and hide progress bars to prevent slow downloads
 Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; 
 $ProgressPreference = "SilentlyContinue"
 
 function log([string] $msg) { Write-Host "$(Get-Date -Format G) [$PSCommandPath] $msg" }
 
 Class InstallerLocator {
   [String] $pattern
   [String] $s3pattern
   [String] $expectedpath
   [String] $s3prefix
   [String] $sourceUrl
   [String] $filename
   [String] $installer
   [bool] $isInstallerAvailable
   
   InstallerLocator([String] $pattern, [String] $expectedpath, [String] $s3prefix, [String] $sourceUrl) {
       $this.pattern = $pattern
       # remove anything after the first wild card for the s3 search pattern
       $this.s3pattern = $pattern.Substring(0, $pattern.IndexOf("*")) 
       # Defend against trailing paths that will cause errors
       $this.expectedpath = $expectedpath.TrimEnd("/\")
       $this.s3prefix = $s3prefix.TrimEnd("/")
       $this.sourceUrl = $sourceUrl.TrimEnd("/")
       $this.filename = $this.sourceUrl.Substring($sourceUrl.LastIndexOf("/") + 1)     
   }
 
   [bool] IsValidInstaller() {
     if (![String]::IsNullOrEmpty($this.installer) -and (Test-Path -Path "$($this.installer)" -PathType Leaf)) {
         return $True
     }
     return $False
   }
 
   Locate() {
     $this.EnsureLocalPathExists()
 
     # Search for the installer on the filesystem already in case something out of band placed it there
     $this.installer = $this.TryFindLocal()
     if ($this.IsValidInstaller()) {
       $this.isInstallerAvailable = $True
       return
     }
 
     # If no installer found yet then try download from s3 and find the downloaded file
     $this.TryDownloadFromS3()
     $this.installer = $this.TryFindLocal()
     if ($this.IsValidInstaller()) {
       $this.isInstallerAvailable = $True
       return
     }
 
     # If no installer found yet then try download from source and find the downloaded file
     $this.TryDownloadFromSource()
     $this.installer = $this.TryFindLocal()
     if ($this.IsValidInstaller()) {
       $this.isInstallerAvailable = $True
       return
     }
 
     # If we've reached this point then nothing can be installed
     Throw "Could not find an installer"
   }
 
   EnsureLocalPathExists() {
     md -force "$($this.expectedpath)" | Out-Null
   }
 
   [string] TryFindLocal() {
     return $(Get-ChildItem $this.expectedpath -Recurse -Filter $this.pattern | Sort -Descending | Select -First 1 -ExpandProperty FullName)
   }
 
   TryDownloadFromS3() {
      if (!(Test-Path env:CheckmarxBucket)) {
        Write-Host "Skipping s3 search, CheckmarxBucket environment variable has not been set"
        return
      }
 
      Write-Host "Searching s3://$env:CheckmarxBucket/$($this.s3prefix)/$($this.s3pattern)"
      try {
         $s3object = (Get-S3Object -BucketName $env:CheckmarxBucket -Prefix "$($this.s3prefix)/$($this.s3pattern)" | Select -ExpandProperty Key | Sort -Descending | Select -First 1)
      } catch {
         Write-Host "ERROR: An exception occured calling Get-S3Object cmdlet. Check IAM Policies and if AWS Powershell is installed"
         exit 1
      }
      if ([String]::IsNullOrEmpty($s3object)) {
         Write-Host "No suitable file found in s3"
         return
      }
 
      Write-Host "Found s3://$env:CheckmarxBucket/$s3object"
      $this.filename = $s3object.Substring($s3object.LastIndexOf("/") + 1)
      try {
         Write-Host "Downloading from s3://$env:CheckmarxBucket/$s3object"
         Read-S3Object -BucketName $env:CheckmarxBucket -Key $s3object -File "$($this.expectedpath)\$($this.filename)"
         Write-Host "Finished downloading $($this.filename)"
      } catch {
         Write-Host "ERROR: An exception occured calling Read-S3Object cmdlet. Check IAM Policies and if AWS Powershell is installed"
         exit 1
      }
   }  
 
   TryDownloadFromSource() {
     Write-Host "Determining download source from $($this.sourceUrl)"
     $jdk = (Invoke-RestMethod -Method GET -Uri "$($this.sourceUrl)" -UseBasicParsing).binary | Where-Object { $_.architecture -eq "x64" -and $_.heap_size -eq "normal" -and $_.image_type -eq "jdk" -and $_.jvm_impl -eq "hotspot" -and $_.os -eq "windows" }
     $jdk_file = $jdk.installer.link.Substring($jdk.installer.link.LastIndexOf("/") + 1)
     Write-Host "Downloading from $($jdk.installer.link)"
     Invoke-WebRequest -UseBasicParsing -Uri "$($jdk.installer.link)" -OutFile "$($this.expectedpath)\${jdk_file}"
     Write-Host "Finished downloading $($this.filename)"
   }
 }
 
 # Main execution begins here
 
 if ([String]::IsNullOrEmpty($installer)) {
     [InstallerLocator] $locator = [InstallerLocator]::New($pattern, $expectedpath, $s3prefix, $sourceUrl)
     $locator.Locate()
     $installer = $locator.installer
 }
  
log "Installing from $installer"
Start-Process "C:\Windows\System32\msiexec.exe" -ArgumentList "/i `"$installer`" ADDLOCAL=FeatureMain,FeatureEnvironment,FeatureJarFileRunWith,FeatureJavaHome INSTALLDIR=`"c:\Program Files\AdoptOpenJDK\`" /quiet /L*V `"$installer.log`" " -Wait -NoNewWindow

if (Test-Path "${installer}.log") { log "Last 50 lines of installer:"; Get-content -tail 50 "${installer}.log" }
log "Finished installing. Log file is at ${installer}.log."
