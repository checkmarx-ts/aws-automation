<#
.SYNOPSIS
Runs the ALG to provision a license

.NOTES
Uses the ALG. Assumes that all ALG artifacts have been fetched to c:\programdata\checkmarx\alg by convention.
 These artifacts must include:
  1. settings.xml - the ALG settings file configured for your environment
  2. ALG-CLI-1.0.0-jar-with-dependencies.jar - the ALG program
  3. CxEncryptUtils.exe - encryption utility used by ALG
  4. HID_CLI_9.0.zip obtained from https://www.checkmarx.com/cxutilities/
#>

# Self Elevate
if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process PowerShell -Verb RunAs "-NoProfile -ExecutionPolicy Bypass -Command `"cd '$pwd'; & '$PSCommandPath';`"";
    exit
}
function log([string] $msg) { Write-Host "$(Get-Date -Format G) [$PSCommandPath] $msg" }

# Force TLS 1.2+ and hide progress bars to prevent slow downloads
Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; 
$ProgressPreference = "SilentlyContinue"

log "Copying alg config from s3"
Read-S3Object -BucketName $env:CheckmarxBucket -KeyPrefix "installation/field/alg" -Folder c:\programdata\checkmarx\alg

log "Expanding HID_CLI_9.0.zip"
Expand-Archive "C:\programdata\checkmarx\alg\HID_CLI_9.0.zip" -DestinationPath "C:\programdata\checkmarx\alg\HID_CLI_9.0" -Force


$hid = $(& "C:\ProgramData\checkmarx\alg\HID_CLI_9.0\HID.exe") | Out-String
log "HID from HID.exe is $hid"
$hid = $hid.Substring(0, $hid.IndexOf("_") )
log "Using $hid as HID input to ALG"

log "Generating license for HID `"${hid}`"..."
Start-Process "java.exe" -ArgumentList "-jar c:\programdata\checkmarx\alg\ALG-CLI-1.0.0-jar-with-dependencies.jar -file `"C:\programdata\checkmarx\alg\settings.xml`" -hid $hid" -WorkingDirectory "C:\ProgramData\checkmarx\alg\" -Wait -NoNewWindow
log "...ALG finished. Log is:"
Get-Content "c:\programdata\checkmarx\alg\licenseGeneratorInfo.log"

log "Seaching for license..."
$license = (Get-ChildItem C:\programdata\checkmarx\alg\license*cxl  | Sort-Object LastWriteTime | Select-Object -last 1).FullName
log "...found: $license"

# Import the new license if Checkmarx is installed
if (Test-Path "C:\Program Files\Checkmarx\Licenses") {
  Move-Item "C:\Program Files\Checkmarx\Licenses\license.cxl" "C:\Program Files\Checkmarx\Licenses\license.$(Get-Date -format "yyyy-MM-dd-HHmm").bak" -Force -ErrorAction SilentlyContinue
  Copy-Item "${license}" 'C:\Program Files\Checkmarx\Licenses\license.cxl' -Verbose -Force
  # Restart services to begin using the new license
  restart-service cx* 
  iisreset
}

# Place a copy in the installer folder for automation purposes. By convention the automation scripts will look for a license file here
log "Creating a copy for the automation scripts to find during install time"
mkdir -Force "c:\programdata\checkmarx\automation\installers"
Copy-Item "$license" "c:\programdata\checkmarx\automation\installers\" -Verbose -Force

log "finished"
