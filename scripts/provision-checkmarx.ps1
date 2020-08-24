Start-Transcript -Path "C:\provision-checkmarx.log" -Append
Write-Output "$(get-date) -------------------------------------------------------------------------"
Write-Output "$(get-date) -------------------------------------------------------------------------"
Write-Output "$(get-date) -------------------------------------------------------------------------"
Write-Output "$(get-date) provision-checkmarx.ps1 script execution beginning"
Write-Output "$(get-date) env:CheckmarxEnvironment = $env:CheckmarxEnvironment"
Write-Output "$(get-date) env:CheckmarxBucket = $env:CheckmarxBucket"
Write-Output "$(get-date) env:CheckmarxComponentType = $env:CheckmarxComponentType"

$ssmprefix = "/checkmarx/${env:CheckmarxEnvironment}"
Write-Output "$(get-date) ssmprefix = $ssmprefix"

# Get the installer variables
$installer_source = $(Get-SSMParameter -Name "${ssmprefix}/installer/source" ).Value
$installer_args = $(Get-SSMParameter -Name "${ssmprefix}/installer/args/$env:CheckmarxComponentType" -WithDecryption $True).Value
$installer_zip_password = $(Get-SSMParameter -Name "${ssmprefix}/installer/zip_password" -WithDecryption $True).Value
$installer_zip = $installer_source.Substring($installer_source.LastIndexOf("/") + 1)
$installer_name = $($installer_zip.Replace(".zip", ""))

# Get the hotfix variables
$hotfix_source = $(Get-SSMParameter -Name "${ssmprefix}/hotfix/source" ).Value
$hotfix_zip_password = $(Get-SSMParameter -Name "${ssmprefix}/hotfix/zip_password" -WithDecryption $True).Value
$hotfix_zip = $hotfix_source.Substring($hotfix_source.LastIndexOf("/") + 1)
$hotfix_name = $($hotfix_zip.Replace(".zip", ""))

Write-Output "$(get-date) installer_source = $installer_source"
Write-Output "$(get-date) installer_args = $installer_args"
Write-Output "$(get-date) installer_zip_password = $installer_zip_password"
Write-Output "$(get-date) installer_zip = $installer_zip"
Write-Output "$(get-date) installer_name = $installer_name"

Write-Output "$(get-date) hotfix_source = $hotfix_source"
Write-Output "$(get-date) hotfix_args = $hotfix_args"
Write-Output "$(get-date) hotfix_zip_password = $hotfix_zip_password"
Write-Output "$(get-date) hotfix_zip = $hotfix_zip"
Write-Output "$(get-date) hotfix_name = $hotfix_name"


###############################################################################
#  Domain Join
###############################################################################
if ($env:CheckmarxComponentType -eq "Manager") {
    if ((Get-WmiObject -Class Win32_ComputerSystem | Select -ExpandProperty PartOfDomain) -eq $True) {
        Write-Output "$(get-date) The computer is joined to a domain"
    } else {
        Write-Output "$(get-date) The computer is not joined to a domain"
        try {
            if (!([String]::IsNullOrEmpty($(Get-SSMParameter -Name "${ssmprefix}/domain/name" ).Value))) {  # If the domain info is set in SSM parameters then join the domain
                Write-Output "$(get-date) Joining the computer to the domain. A reboot will occur."
                C:\programdata\checkmarx\aws-automation\scripts\configure\domain-join.ps1 -domainJoinUserName "${ssmprefix}/domain/admin/username" -domainJoinUserPassword "${ssmprefix}/domain/admin/password" -primaryDns "${ssmprefix}/domain/dns/primary" -secondaryDns "${ssmprefix}/domain/dns/secondary" -domainName "${ssmprefix}/domain/name"
                # In case the implicit restart does not occur or is overridden
                Restart-Computer
            }    
        } catch {
            Write-Output "$(get-date) An error occured while joining to domain. Is the ${ssmprefix}/domain/name ssm parameter set?"
            $_
        }    
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

    Restart-Computer -Force # force in case anyone is logged in
    sleep 30
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

if ($env:CheckmarxComponentType -eq "Manager") {
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
    # Install SQL Server Express
    ###############################################################################
    if (!(Test-Path -Path "C:\ProgramData\chocolatey\choco.exe")) {
        Write-Output "$(get-date) Installing Chocolatey (required for SQL Server Express)"
        Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; iex ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))
        Write-Output "$(get-date) ...finished installing Chocolatey"
    } else {
        Write-Output "$(get-date) Chocolatey (required for SQL Server Express) is already installed - skipping installation"
    }
    if ((get-service sql*).length -eq 0) {
        Write-Output "$(get-date) Installing SQL Server Express"
        choco install sql-server-express --no-progress --install-args="/BROWSERSVCSTARTUPTYPE=Automatic /SQLSVCSTARTUPTYPE=Automatic /TCPENABLED=1" -y
        Write-Output "$(get-date) ...finished installing SQL Server Express"
    } else {
        Write-Output "$(get-date) SQL Server Express is already installed - skipping installation"
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
        
        # Java is the last of the dependencies, so at this point we need to reboot again
        #Write-Output "$(get-date) restarting to refresh the environment"
        #restart-computer -force
    }
}

# Download and unzip the installer
Write-Output "$(get-date) Downloading $installer_source..."
(New-Object System.Net.WebClient).DownloadFile("$installer_source", "c:\programdata\checkmarx\automation\installers\${installer_zip}")
Write-Output "$(get-date) ...finished downloading $installer_source to c:\programdata\checkmarx\automation\installers\${installer_zip}"

Write-Output "$(get-date) Unzipping c:\programdata\checkmarx\automation\installers\${installer_zip}"
Start-Process "C:\Program Files\7-Zip\7z.exe" -ArgumentList "x `"c:\programdata\checkmarx\automation\installers\${installer_zip}`" -aoa -o`"C:\programdata\checkmarx\automation\installers\${installer_name}`" -p`"${installer_zip_password}`"" -Wait -NoNewWindow -RedirectStandardError .\installer7z.err -RedirectStandardOutput .\installer7z.out
cat .\installer7z.err
cat .\installer7z.out
Write-Output "$(get-date) ...finished unzipping"

# Download and unzip the hotfix
Write-Output "$(get-date) Downloading $hotfix_source..."
(New-Object System.Net.WebClient).DownloadFile("$hotfix_source", "c:\programdata\checkmarx\automation\installers\${hotfix_zip}")
Write-Output "$(get-date) ...finished downloading $hotfix_source to c:\programdata\checkmarx\automation\installers\${hotfix_zip}"

Write-Output "$(get-date) Unzipping c:\programdata\checkmarx\automation\installers\${hotfix_zip}"
Start-Process "C:\Program Files\7-Zip\7z.exe" -ArgumentList "x `"c:\programdata\checkmarx\automation\installers\${hotfix_zip}`" -aoa -o`"C:\programdata\checkmarx\automation\installers\${hotfix_name}`" -p`"${hotfix_zip_password}`"" -Wait -NoNewWindow -RedirectStandardError .\hotfix7z.err -RedirectStandardOutput .\hotfix7z.out
cat .\hotfix7z.err
cat .\hotfix7z.out
Write-Output "$(get-date) ...finished unzipping"

$cxsetup = $(Get-ChildItem "C:\programdata\checkmarx\automation\installers\${installer_name}" -Recurse -Filter "CxSetup.exe" | Sort -Descending | Select -First 1 -ExpandProperty FullName)
Write-Output "$(get-date) Installing CxSAST with $cxsetup_install"
Start-Process "$cxsetup" -ArgumentList "${installer_args}" -Wait -NoNewWindow -RedirectStandardError ".\cxinstaller.err" -RedirectStandardOutput ".\cxinstaller.out"
Write-Output "$(get-date) ...finished installing"
Write-Output "$(get-date) installer StandardError:"
cat .\cxinstaller.err
Write-Output "$(get-date) installer StandardOutput:"
cat .\cxinstaller.out

Write-Output "$(get-date) Installing hotfix ${hotfix_name}"
$hotfixexe = $(Get-ChildItem "C:\programdata\checkmarx\automation\installers\${hotfix_name}" -Recurse -Filter "*HF*.exe" | Sort -Descending | Select -First 1 -ExpandProperty FullName)
Start-Process "$hotfixexe" -ArgumentList "-cmd" -Wait -NoNewWindow
Write-Output "$(get-date) ...finished installing"    

if ($env:CheckmarxComponentType -eq "Manager") {

    ###############################################################################
    # Generate Checkmarx License
    ###############################################################################
    Write-Output "$(get-date) Running automatic license generator"
    C:\programdata\checkmarx\aws-automation\scripts\configure\license-from-alg.ps1
    Write-Output "$(get-date) ... finished running automatic license generator"

    ###############################################################################
    # Post Install Windows Configuration
    ###############################################################################
    Write-Output "$(get-date) Hardening IIS"
    C:\programdata\checkmarx\aws-automation\scripts\configure\configure-iis-hardening.ps1
    Write-Output "$(get-date) ...finished hardening IIS"

    Write-Output "$(get-date) Configuring windows defender"
    C:\programdata\checkmarx\aws-automation\scripts\configure\configure-windows-defender.ps1
    Write-Output "$(get-date) ...finished configuring windows defender"

    ###############################################################################
    # Reverse proxy CxARM
    ###############################################################################
    Write-Output "$(get-date) Configuring IIS to reverse proxy CxARM"
    C:\programdata\checkmarx\aws-automation\scripts\configure\configure-cxarm-iis-reverseproxy.ps1
    Write-Output "$(get-date) finished configuring IIS to reverse proxy CxARM"
}

###############################################################################
# Install Tools
###############################################################################
Write-Output "$(get-date) Installing tools"
C:\programdata\checkmarx\aws-automation\scripts\lab\install-tools.ps1 
Write-Output "$(get-date) ...finished installing tools."

Disable-ScheduledTask -TaskName "provision-checkmarx"
