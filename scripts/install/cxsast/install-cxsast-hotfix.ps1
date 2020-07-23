<#
.SYNOPSIS
Installs / Checkmarx CxSAST Hotfix

.NOTES
The installer file is determined in this order:
  IF the installer argument is passed then:
    - the absolute path will be used as the installer
    - neither the local expected path or s3 bucket will be searched
    - no download over the internet will take place
  OTHERWISE the installation file will be searched for in this order
    1. The local expected path i.e. c:\programdata\checkmarx\ will be searched for a file that matches the typical installer filename. This allows you to place an installer here via any means
    2. IF the CheckmarxBucket environment variable is set, the bucket will be searched for a file that matches the typical installer filename with an appropriate key prefix (ie installation/common)

  * When searching based on file prefix, if more than 1 file is found the files are sorted by file name and the first file is selected. This typically will mean the most recent version available is selected. 
#>
param (
 # Automation args
 # installers should be the filename of the zip file as distributed by Checkmarx but stripped of any password protection
 [Parameter(Mandatory = $False)] [String] $installer = "9.0.0.HF3.zip",
 [Parameter(Mandatory = $True)] [String] $zip_password = "",

 # The default paths are a convention and not normally changed. Take caution if passing in args. 
 [Parameter(Mandatory = $False)] [String] $expectedpath ="C:\programdata\checkmarx\automation\installers",
 [Parameter(Mandatory = $False)] [String] $s3prefix = "installation/cxsast/9.0"
)

# Force TLS 1.2+ and hide progress bars to prevent slow downloads
Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; 
$ProgressPreference = "SilentlyContinue"

<##################################
    Functions & Classes - main execution will begin below
###################################>
function log([string] $msg) { Write-Host "$(Get-Date -Format G) [$PSCommandPath] $msg" }


# Helper function to fetch SSM Parameters
function  TryGetSSMParameter([String] $parameter) {
    if(!$parameter) { return $null }

    try {
        $ssmParam = Get-SSMParameter -Name $parameter -WithDecryption $True
    
        if($ssmParam) {
        log "Using the value found for $parameter"
        return $ssmParam.value
        } else {
        log "Using argument as provided"
        return $parameter
    }
    } catch {
        $_
        log "An error occured while fetching SSM parameter key"
        log "Using argument as provided"
        return $parameter
    }
}

###############################################################################
# Support for SSM Parameters
#
# IF a variable starts with a "/" THEN we will try to look it up from SSM 
# parameter store and use its resolved value
###############################################################################
Get-Command $PSCommandPath | ForEach-Object {
    $_.Parameters.GetEnumerator() | % {
        $value = (Get-Variable $_.Key -ErrorAction Ignore).Value
        if ($value) {
            if ($value.ToString().IndexOf("/") -eq 0) {
                log "$($_.Key) looks like a SSM parameter: $value"
                $value = TryGetSSMParameter $value
                Set-Variable -Name $_.Key -Value $value
            }
        }
    } 
}
function VerifyFileExists($path) {
    if ([String]::IsNullOrEmpty($path) -or !(Test-Path "$path")) {
        log "ERROR: file does not exist or is empty: path `"$path`""
        exit 1
    } 
}

Class InstallerLocator {
  [String] $pattern
  [String] $s3pattern
  [String] $expectedpath
  [String] $s3prefix
  [String] $sourceUrl
  [String] $filename
  [String] $installer
  [bool] $isInstallerAvailable
  
  InstallerLocator([String] $pattern, [String] $expectedpath, [String] $s3prefix) {
      $this.pattern = $pattern
      $this.s3pattern = $pattern
      # Defend against trailing paths that will cause errors
      $this.expectedpath = $expectedpath.TrimEnd("/\")
      $this.s3prefix = $s3prefix.TrimEnd("/") 
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
}

<##################################
    Search & obtain the installers
###################################>
[InstallerLocator] $locator = [InstallerLocator]::New($installer, $expectedpath, $s3prefix)
$locator.Locate()
$installer = $locator.installer


$files = $(Get-ChildItem "$expectedpath" -Recurse -Filter "*HF*zip" | Select-Object -ExpandProperty FullName)
$files | ForEach-Object {
    Start-Process "7z.exe" -ArgumentList "x $_  -p`"${zip_password}`"" -Wait -NoNewWindow -WorkingDirectory "${expectedPath}"
}

# At this point the installer vars are actually pointing to zip files.. Lets find the actual executables now that they're unzipped.
$hotfix_installer = $(Get-ChildItem "$expectedpath" -Recurse -Filter "*HF*.exe" | Sort-Object -Descending | Select-Object -First 1 -ExpandProperty FullName)
VerifyFileExists $hotfix_installer

<##################################
    Install Checkmarx Hotfix
###################################>
log "Stopping services to install hotfix"
stop-service cx*; stop-service w3svc;
log "Installing $hotfix_installer"
Start-Process "$hotfix_installer" -ArgumentList "-cmd" -Wait -NoNewWindow
log "Finished hotfix installation"

log "Restarting services"
Restart-Service cx*; Restart-Service w3svc;

log "Finished installing"
exit 0