# Uses the ALG. Assumes that all ALG artifacts have been fetched to c:\programdata\checkmarx\alg by convention.
# These artifacts must include:
#  1. settings.xml - the ALG settings file configured for your environment
#  2. ALG-CLI-1.0.0-jar-with-dependencies.jar - the ALG program
#  3. CxEncryptUtils.exe - encryption utility used by ALG
#  4. HID_CLI_9.0.zip obtained from https://www.checkmarx.com/cxutilities/

# Self Elevate
if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process PowerShell -Verb RunAs "-NoProfile -ExecutionPolicy Bypass -Command `"cd '$pwd'; & '$PSCommandPath';`"";
    exit
}

# Force TLS 1.2+ and hide progress bars to prevent slow downloads
Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; 
$ProgressPreference = "SilentlyContinue"

if (!(Test-Path "C:\programdata\checkmarx\alg")) {
  Expand-Archive "C:\programdata\checkmarx\alg\HID_CLI_9.0.zip" -DestinationPath "C:\programdata\checkmarx\alg\HID_CLI_9.0" -Force
}

# Get the machine's hardware id
$hid = $(& "C:\ProgramData\checkmarx\alg\HID_CLI_9.0\HID.exe") | Out-String
$hid = $hid.Substring(0, $hid.IndexOf("_") )

# Generate the license
Write-Host "Generating license for HID $hid"
#Start-Process "java.exe" -ArgumentList "-jar c:\programdata\checkmarx\alg\ALG-CLI-1.0.0-jar-with-dependencies.jar -file `"C:\programdata\checkmarx\alg\settings.xml`" -hid $hid" -WorkingDirectory "C:\ProgramData\checkmarx\alg\" -Wait -NoNewWindow
cat "c:\programdata\checkmarx\alg\licenseGeneratorInfo.log"

# Backup any existing license file and import the new one
$license = (gci C:\programdata\checkmarx\alg\license*cxl  | sort LastWriteTime | select -last 1).FullName

# Import the new license if Checkmarx is installed
if (Test-Path "C:\Program Files\Checkmarx\Licenses") {
  Move-Item "C:\Program Files\Checkmarx\Licenses\license.cxl" "C:\Program Files\Checkmarx\Licenses\license.$(Get-Date -format "yyyy-MM-dd-HHmm").bak" -Force -ErrorAction SilentlyContinue
  cp "$((${license}).FullName)" 'C:\Program Files\Checkmarx\Licenses\license.cxl' -Verbose -Force
  # Restart services to begin using the new license
  restart-service cx* 
  iisreset
}

# Place a copy in the installer folder for automation purposes. By convention the automation scripts will look for a license file here
md -Force c:\programdata\checkmarx\automation\installers
cp "$license" "c:\programdata\checkmarx\automation\installers\" -Verbose -Force
