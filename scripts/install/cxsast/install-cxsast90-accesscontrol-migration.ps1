<#
.SYNOPSIS
Installs / Checkmarx CxSAST 9.0 Access Control and Migration

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
 [Parameter(Mandatory = $False)] [String] $installer = "CxSAST.900.Release.Setup_9.0.0.40085*zip",

 # The default paths are a convention and not normally changed. Take caution if passing in args. 
 [Parameter(Mandatory = $False)] [String] $expectedpath ="C:\programdata\checkmarx\automation\installers",
 [Parameter(Mandatory = $False)] [String] $s3prefix = "installation/cxsast/9.0",
 
 # Install Options
 [Parameter(Mandatory = $False)] [switch] $ACCEPT_EULA = $False,
 [Parameter(Mandatory = $False)] [String] $PORT = "443",
 [Parameter(Mandatory = $False)] [String] $INSTALLFOLDER = "C:\Program Files\Checkmarx",
 [Parameter(Mandatory = $False)] [String] $CxSAST_ADDRESS = "https://sekots.dev.checkmarx-ts.com",

 # Cx Components
 [Parameter(Mandatory = $False)] [switch] $ACCESSCONTROL = $False,
 
 # CxDB SQL
 [Parameter(Mandatory = $False)] [switch] $SQLAUTH = $False,
 [Parameter(Mandatory = $False)] [String] $SQLSERVER = "localhost\SQLExpress",
 [Parameter(Mandatory = $False)] [String] $SQLUSER = "",
 [Parameter(Mandatory = $False)] [String] $SQLPWD = ""

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
    Initial start up
###################################>
# Users must accept the EULA
if (!$ACCEPT_EULA.IsPresent) {
  log "You must accept the EULA."
  exit 1
}

# Defend against trailing paths and missing directories that will cause errors
$expectedpath = $expectedpath.TrimEnd("\")
$s3prefix = $s3prefix.TrimEnd("/")
mkdir -force "$expectedpath" | Out-Null

<##################################
    Search & obtain the installers
###################################>
[InstallerLocator] $locator = [InstallerLocator]::New($installer, $expectedpath, $s3prefix)
$locator.Locate()
$installer = $locator.installer


$files = $(Get-ChildItem "$expectedpath" -Recurse -Filter "*zip" | Select-Object -ExpandProperty FullName)
$files | ForEach-Object {
    Expand-Archive -Path $_ -DestinationPath $expectedpath -Force
}

# At this point the installer vars are actually pointing to zip files.. Lets find the actual executables now that they're unzipped.
$installer = $(Get-ChildItem "$expectedpath" -Recurse -Filter "CxSetup.AC_and_Migration.exe" | Sort-Object -Descending | Select-Object -First 1 -ExpandProperty FullName)
VerifyFileExists $installer


<##################################
    Install AC
###################################>
# Build up the installer command line options
$ACCESSCONTROL_BIT = "0"
if ($ACCESSCONTROL.IsPresent) { $ACCESSCONTROL_BIT = "1" } 
if ($SQLAUTH.IsPresent) { $SQLAUTH_BIT = "1" }

$cx_component_options = " ACCESSCONTROL=${ACCESSCONTROL_BIT} "
$cx_options = "/install /quiet ACCEPT_EULA=Y PORT=${PORT} INSTALLFOLDER=`"${INSTALLFOLDER}`" CXSAST_ADDRESS=`"${CxSAST_ADDRESS}`"" # Note you must quote INSTALLFOLDER and other paths to handle spaces
$cx_db_options = " SQLAUTH=${SQLAUTH_BIT} SQLSERVER=${SQLSERVER} SQLUSER=`"${SQLUSER}`" SQLPWD=`"${SQLPWD}`" "
$cx_static_options = "${cx_options} ${cx_db_options} "
# Now do run the installer, keep tracking of component bit state along the way. Multiple runs of the installer are required or else the database hangs (which is why we keep track of the state). 

log "Installing with command:"
log "${installer} ${cx_options} ${cx_db_options}" # $("${cx_component_options} ${cx_static_options}".Replace("SQLPWD=$SQLPWD", "SQLPWD=***""))"

$logtimestamp = $(get-date -format "yyyy.mm.dd-HH.mm.ss")
$logprefix = "c:\programdata\checkmarx\automation\${logtimestamp}-CxSetup.AC_and_Migration.exe"
Start-Process "$installer" -ArgumentList "${cx_component_options} ${cx_static_options} " -Wait -NoNewWindow -RedirectStandardError "${logprefix}.err" -RedirectStandardOutput "${logprefix}.out"

log "Finished installing"
