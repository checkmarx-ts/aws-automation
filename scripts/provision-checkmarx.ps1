Start-Transcript -Path "C:\provision-checkmarx.log" -Append
Write-Output "$(get-date) -------------------------------------------------------------------------"
Write-Output "$(get-date) -------------------------------------------------------------------------"
Write-Output "$(get-date) -------------------------------------------------------------------------"
Write-Output "$(get-date) provision-checkmarx.ps1 script execution beginning"

$attemptDomainJoin = $false

###############################################################################
#  Domain Join
###############################################################################
if ((Get-WmiObject -Class Win32_ComputerSystem | Select -ExpandProperty PartOfDomain) -eq $True) {
    Write-Output "$(get-date) The computer is joined to a domain"
} else {
    Write-Output "$(get-date) The computer is not joined to a domain"
    if ($attemptDomainJoin) {
        Write-Output "$(get-date) Joining the computer to the domain. A reboot will occur."
        C:\programdata\checkmarx\aws-automation\scripts\configure\domain-join.ps1 -domainJoinUserName "corp\Admin" -domainJoinUserPassword "pass" -primaryDns "dns1" -secondaryDns "dns2" -domainName "corp.company.com"
        # In case the implicit restart does not occur or is overridden
        Restart-Computer
    }
}


###############################################################################
#  .NET Framework 4.7.1 Install
###############################################################################
# https://docs.microsoft.com/en-us/dotnet/framework/migration-guide/how-to-determine-which-versions-are-installed#to-check-for-a-minimum-required-net-framework-version-by-querying-the-registry-in-powershell-net-framework-45-and-later
$dotnet_release = $(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full\' | Get-ItemPropertyValue -Name Release)
$dotnet_version = $(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full\' | Get-ItemPropertyValue -Name Version)
Write-Output "$(get-date) Found .net version ${dotnet_version}; release string: $dotnet_release"
if ($dotnet_release -ge 461308 ) {
    Write-Output "$(get-date) Dotnet 4.7.1 (release string: 461308 ) or higher already installed - skipping installation"
} else {
    Write-Output "$(get-date) Installing dotnet framework - a reboot will be required"
    C:\programdata\checkmarx\aws-automation\scripts\install\common\install-dotnetframework.ps1
    Write-Output "$(get-date) ... finished dotnet framework install"
    Write-Output "$(get-date) Rebooting now"
    sleep 5
    Restart-Computer -Force # force in case anyone is logged in
}

###############################################################################
#  7-zip Install
###############################################################################
$7zip_path = $(Get-ChildItem 'HKLM:\SOFTWARE\7*Zip\' | Get-ItemPropertyValue -Name Path)
if (![String]::IsNullOrEmpty($7zip_path)) {
    Write-Output "$(get-date) 7-Zip is already installed at ${7zip_path} - skipping installation"
} else {
    Write-Output "$(get-date) Installing 7zip"
    C:\programdata\checkmarx\aws-automation\scripts\install\common\install-7zip.ps1
    Write-Output "$(get-date) ... finished Installing 7zip"
}

###############################################################################
#  Microsoft Visual C++ 2010 Redistributable Package (x64) Install
###############################################################################
$cpp2010_version = $(Get-ChildItem 'HKLM:\SOFTWARE\Wow6432Node\Microsoft\VisualStudio\10*0\VC\VCRedist\x64' -ErrorAction SilentlyContinue | Get-ItemPropertyValue -Name Installed -ErrorAction SilentlyContinue)
if (![String]::IsNullOrEmpty($cpp2010_version)) {
    Write-Output "$(get-date) C++ 2010 Redistributable is already installed - skipping installation"
} else {
    Write-Output "$(get-date) Installing C++ 2010 Redistributable"
    C:\programdata\checkmarx\aws-automation\scripts\install\common\install-cpp2010sp1.ps1
    Write-Output "$(get-date) ... finished Installing C++ 2010 Redistributable"
}

###############################################################################
#  Microsoft Visual C++ 2015 Redistributable Update 3 RC Install
###############################################################################
$cpp2015_version = $(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14*0\VC\Runtimes\x64' -ErrorAction SilentlyContinue | Get-ItemPropertyValue -Name Installed -ErrorAction SilentlyContinue)
if (![String]::IsNullOrEmpty($cpp2015_version)) {
    Write-Output "$(get-date) Microsoft Visual C++ 2015 Redistributable Update 3 RC is already installed - skipping installation"
} else {
    Write-Output "$(get-date) Installing Microsoft Visual C++ 2015 Redistributable Update 3 RC"
    C:\programdata\checkmarx\aws-automation\scripts\install\common\install-cpp2015update3rc.ps1
    Write-Output "$(get-date) ... finished Installing Microsoft Visual C++ 2015 Redistributable Update 3 RC"
}


###############################################################################
# AdoptOpenJDK Install
###############################################################################
if (Test-Path -Path "C:\Program Files\AdoptOpenJDK\bin\java.exe") {
    Write-Output "$(get-date) Java is already installed - skipping installation"
} else {
    Write-Output "$(get-date) Installing Java"
    C:\programdata\checkmarx\aws-automation\scripts\install\common\install-java.ps1
    Write-Output "$(get-date) ... finished Installing Java"
    Start-Process "C:\Program Files\AdoptOpenJDK\bin\java.exe" -ArgumentList "-version" -RedirectStandardError ".\java-version.log" -Wait -NoNewWindow
    cat ".\java-version.log"
}

###############################################################################
# Git Install
###############################################################################
if (Test-Path -Path "C:\Program Files\Git\bin\git.exe") {
    Write-Output "$(get-date) Git is already installed - skipping installation"
} else {
    Write-Output "$(get-date) Installing Git"
    C:\programdata\checkmarx\aws-automation\scripts\install\common\install-git.ps1
    Write-Output "$(get-date) ... finished Installing Git"
    Start-Process "C:\Program Files\Git\bin\git.exe" -ArgumentList "--version" -RedirectStandardOutput ".\git-version.log" -Wait -NoNewWindow
    cat ".\git-version.log"
}

###############################################################################
# IIS Install
###############################################################################
Write-Output "$(get-date) Installing IIS"
C:\programdata\checkmarx\aws-automation\scripts\install\common\install-iis.ps1
Write-Output "$(get-date) ... finished Installing IIS"

###############################################################################
# IIS Rewrite Module Install
###############################################################################
if (Test-Path -Path "C:\Windows\System32\inetsrv\rewrite.dll") {
     Write-Output "$(get-date) IIS Rewrite Module is already installed - skipping installation"
} else {
    Write-Output "$(get-date) Installing IIS rewrite Module"
    C:\programdata\checkmarx\aws-automation\scripts\install\common\install-iis-url-rewrite-module.ps1
    Write-Output "$(get-date) ... finished Installing IIS Rewrite Module"
}

###############################################################################
# IIS Application Request Routing Install
###############################################################################
if (($(C:\Windows\System32\inetsrv\appcmd.exe list modules) | Where  { $_ -match "ApplicationRequestRouting" } | ForEach-Object { echo $_ }).length -gt 1) {
     Write-Output "$(get-date) IIS Application Request Routing Module is already installed - skipping installation"
} else {
    Write-Output "$(get-date) Installing IIS Application Request Routing Module"
    C:\programdata\checkmarx\aws-automation\scripts\install\common\install-iis-application-request-routing-module.ps1
    Write-Output "$(get-date) ... finished Installing IIS Application Request Routing Module"
}

###############################################################################
# Dotnet Core Hosting 2.1.16
###############################################################################
if (Test-Path -Path "C:\Program Files\dotnet") {
     Write-Output "$(get-date) Microsoft .NET Core 2.1.16 Windows Server Hosting is already installed - skipping installation"
} else {
    Write-Output "$(get-date) Installing Microsoft .NET Core 2.1.16 Windows Server Hosting"
    C:\programdata\checkmarx\aws-automation\scripts\install\common\install-dotnetcore-hosting-2.1.16-win.ps1
    Write-Output "$(get-date) ... finished Installing Microsoft .NET Core 2.1.16 Windows Server Hosting"
}

###############################################################################
# Generate Checkmarx License
###############################################################################
Write-Output "$(get-date) Running automatic license generator"
C:\programdata\checkmarx\aws-automation\scripts\configure\license-from-alg.ps1
Write-Output "$(get-date) ... finished running automatic license generator"


###############################################################################
# Install SQL Server Express
###############################################################################
if (!(Test-Path -Path "C:\ProgramData\chocolatey\choco.exe")) {
    Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; iex ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))
}
choco install sql-server-express --no-progress --install-args="/BROWSERSVCSTARTUPTYPE=Automatic /SQLSVCSTARTUPTYPE=Automatic /TCPENABLED=1" -y
