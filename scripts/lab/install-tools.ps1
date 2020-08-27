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
choco install notepadplusplus --no-progress -y
choco install googlechrome --no-progress -y
choco install sql-server-management-studio --no-progress -y

choco install vim --no-progress -y
choco install firefox --no-progress -y
choco install vscode --no-progress -y
choco install postman --no-progress -y
choco install sysinternals --no-progress -y

log "Finished installing tools"
