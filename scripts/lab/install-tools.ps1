# Self Elevate
if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process PowerShell -Verb RunAs "-NoProfile -ExecutionPolicy Bypass -Command `"cd '$pwd'; & '$PSCommandPath';`"";
    exit
}
function log([string] $msg) { Write-Host "$(Get-Date -Format G) [$PSCommandPath] $msg" }

# Install Chocolatey
Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; iex ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))
$ProgressPreference = "SilentlyContinue"

# Install the tools
choco install notepadplusplus -y
choco install vim -y
choco install firefox -y
choco install googlechrome -y
choco install 7zip.install -y
choco install sql-server-management-studio -y
choco install wireshark -y
choco install vscode -y
choco install fiddler -y
choco install postman -y
choco install sysinternals -y

log "Finished installing tools"
