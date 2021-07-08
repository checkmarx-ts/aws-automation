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


. $PSScriptRoot\..\..\CheckmarxAWS.ps1


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