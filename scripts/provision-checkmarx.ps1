# Force TLS 1.2+ and hide progress bars to prevent slow downloads
Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; 
$ProgressPreference = "SilentlyContinue"
$InformationPreference = "continue"
Start-Transcript -Path "C:\provision-checkmarx.log" -Append
Write-Information "-------------------------------------------------------------------------"
Write-Information "-------------------------------------------------------------------------"
Write-Information "-------------------------------------------------------------------------"
Write-Information "provision-checkmarx.ps1 script execution beginning"

class Utility {
    [bool] static Exists([String] $fpath) {
        return ((![String]::IsNullOrEmpty($fpath)) -and (Test-Path -Path "${fpath}"))
    }
    [String] static Addpath([String] $fpath){
        [Environment]::SetEnvironmentVariable('Path',[Environment]::GetEnvironmentVariable('Path', [EnvironmentVariableTarget]::Machine) + ";$fpath",[EnvironmentVariableTarget]::Machine)
        return [Environment]::GetEnvironmentVariable("Path", [EnvironmentVariableTarget]::Machine)
    }
    [String] static Basename([String] $fullname) {
        return $fullname.Substring($fullname.LastIndexOf("/") + 1)
    }
    [String] static Find([String] $filename) {
        return $(Get-ChildItem C:\programdata\checkmarx\automation -Recurse -Filter $filename | Sort -Descending | Select -First 1 -ExpandProperty FullName)
    }
    [String] static Find([String] $fpath, [String] $filename) {
        return $(Get-ChildItem "$fpath" -Recurse -Filter $filename | Sort -Descending | Select -First 1 -ExpandProperty FullName)
    }
    [String] static Fetch([String] $source) {
        $filename = [Utility]::Basename($source)
        if ($source.StartsWith("https://")) {
            Write-Information "Downloading $source"
            (New-Object System.Net.WebClient).DownloadFile("$source", "c:\programdata\checkmarx\automation\installers\${filename}")
        } elseif ($source.StartsWith("s3://")) {        
            $bucket = $source.Replace("s3://", "").Split("/")[0]
            $key = $source.Replace("s3://${bucket}", "")
            Write-Information "Downloading $source from bucket $bucket with key $key"
            Read-S3Object -BucketName $bucket -Key $key -File "C:\programdata\checkmarx\automation\installers\$filename"
        }
        $fullname = [Utility]::Find($filename)
        Write-Information "... found $fullname"
        return $fullname
    }
}

$config = Import-PowerShellDataFile -Path C:\checkmarx-config.psd1

###############################################################################
#  Create Folders
###############################################################################
Write-Information "Creating Checkmarx folders"
$cx_home = if ($env:CheckmarxHome -eq $null) { "C:\programdata\checkmarx" } Else { $env:CheckmarxHome }
$cx_automation_state = Join-Path -Path $cx_home -ChildPath "automation-state"

New-Item -Path $cx_home -Force
New-Item -Path $cx_automation_state -Force

###############################################################################
#  Resolve configuration values
###############################################################################
Write-Information "Resolving configuration values"
$sql_password = $(Get-SSMParameter -Name "$($config.Aws.SsmPath)/sql/password" -WithDecryption $True).Value
$cx_api_password = $(Get-SSMParameter -Name "$($config.Aws.SsmPath)/api/password" -WithDecryption $True).Value
$tomcat_password = $(Get-SSMParameter -Name "$($config.Aws.SsmPath)/tomcat/password" -WithDecryption $True).Value

Write-Information "env:CheckmarxBucket = $env:CheckmarxBucket"
Write-Information "checkmarx-config.psd1 configuration:"
cat C:\checkmarx-config.psd1


###############################################################################
#  Domain Join
###############################################################################
if ($config.Checkmarx.ComponentType -eq "Manager")  {
    if ((Get-WmiObject -Class Win32_ComputerSystem | Select -ExpandProperty PartOfDomain) -eq $True) {
        Write-Information "The computer is joined to a domain"
    } else {
        Write-Information "The computer is not joined to a domain"
        try {
            if (!([String]::IsNullOrEmpty($config.ActiveDirectory.Username))) {  # If the domain info is set in SSM parameters then join the domain
                Write-Information "Joining the computer to the domain. A reboot will occur."
                & C:\programdata\checkmarx\aws-automation\scripts\configure\domain-join.ps1 -domainJoinUserName "$config.ActiveDirectory.Username" -domainJoinUserPassword "$($config.aws.SsmPath)/domain/admin/password" -primaryDns $config.ActiveDirectory.PrimaryDns -secondaryDns $config.ActiveDirectory.SecondaryDns -domainName $config.ActiveDirectory.DomainName
                # In case the implicit restart does not occur or is overridden
                Restart-Computer -Force
                Sleep 30
            }    
        } catch {
            Write-Information "An error occured while joining to domain. Is the ${ssmprefix}/domain/name ssm parameter set? Assuming that no domain join was intended."
            $_
        }    
    }
}


###############################################################################
#  7-zip Install
###############################################################################
$7zip_path = $(Get-ChildItem 'HKLM:\SOFTWARE\7*Zip\' | Get-ItemPropertyValue -Name Path)
if ([Utility]::Exists($7zip_path)) {
    Write-Information "7-Zip is already installed at ${7zip_path} - skipping installation"
} else {
    Write-Information "Installing 7zip"
    $sevenzipinstaller = [Utility]::Fetch($config.Dependencies.Sevenzip)
    Start-Process -FilePath "$sevenzipinstaller" -ArgumentList "/S" -Wait -NoNewWindow
    $newpath = [Utility]::Addpath($(Get-ChildItem 'HKLM:\SOFTWARE\7*Zip\' | Get-ItemPropertyValue -Name Path))
    Write-Information "... finished Installing 7zip"
}


###############################################################################
#  Download Checkmarx Installers
###############################################################################
# Download and unzip the installer. It has many dependencies inside the zip file that
# need to be installed so this is one of the first steps.    
$installer_zip = [Utility]::Basename($config.Installer.Url)
$installer_name = $($installer_zip.Replace(".zip", ""))
if ([Utility]::Exists("c:\programdata\checkmarx\automation\installers\${installer_zip}")) {
    Write-Information "Skipping download of $($config.Installer.Url) because it already has been downloaded"
} else {
    $cxinstaller = [Utility]::Fetch($config.Installer.Url)
    Write-Information "Unzipping c:\programdata\checkmarx\automation\installers\${installer_zip}"
    Start-Process "C:\Program Files\7-Zip\7z.exe" -ArgumentList "x `"${cxinstaller}`" -aoa -o`"C:\programdata\checkmarx\automation\installers\${installer_name}`" -p`"$($config.Installer.ZipKey)`"" -Wait -NoNewWindow -RedirectStandardError .\installer7z.err -RedirectStandardOutput .\installer7z.out
    cat .\installer7z.err
    cat .\installer7z.out
    Write-Information "...finished unzipping ${installer_zip}"
} 

# Download and unzip the hotfix
$hotfix_zip = [Utility]::Basename($config.Hotfix.Url)
$hotfix_name = $($hotfix_zip.Replace(".zip", ""))
if ([Utility]::Exists("c:\programdata\checkmarx\automation\installers\${hotfix_zip}")) {
    Write-Information "Skipping download of $($config.Hotfix.Url) because it already has been downloaded"
} else {
    $hfinstaller = [Utility]::Fetch($config.Hotfix.Url)
    Write-Information "Unzipping c:\programdata\checkmarx\automation\installers\${hotfix_zip}"
    Start-Process "C:\Program Files\7-Zip\7z.exe" -ArgumentList "x `"$hfinstaller`" -aoa -o`"C:\programdata\checkmarx\automation\installers\${hotfix_name}`" -p`"$($config.Hotfix.ZipKey)`"" -Wait -NoNewWindow -RedirectStandardError .\hotfix7z.err -RedirectStandardOutput .\hotfix7z.out
    cat .\hotfix7z.err
    cat .\hotfix7z.out
    Write-Information "...finished unzipping ${hotfix_zip}"
} 


###############################################################################
#  Microsoft Visual C++ 2010 Redistributable Package (x64) Install
###############################################################################
$cpp2010_version = $(Get-ChildItem 'HKLM:\SOFTWARE\Wow6432Node\Microsoft\VisualStudio\10*0\VC\VCRedist\x64' -ErrorAction SilentlyContinue | Get-ItemPropertyValue -Name Installed -ErrorAction SilentlyContinue)
if (![String]::IsNullOrEmpty($cpp2010_version)) {
    Write-Information "C++ 2010 Redistributable is already installed - skipping installation"    
} else {
    Write-Information "Installing C++ 2010 Redistributable"
    $cpp2010_installer = [Utility]::Find("vcredist_x64.exe")
    Start-Process -FilePath "$cpp2010_installer" -ArgumentList "/passive /norestart" -Wait -NoNewWindow
    Write-Information "... finished Installing C++ 2010 Redistributable"
}


###############################################################################
#  Microsoft Visual C++ 2015 Redistributable Update 3 RC Install
###############################################################################
$cpp2015_version = $(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14*0\VC\Runtimes\x64' -ErrorAction SilentlyContinue | Get-ItemPropertyValue -Name Installed -ErrorAction SilentlyContinue)
$cpp2015_installer = [Utility]::Find("vc_redist2015.x64.exe")
if (![String]::IsNullOrEmpty($cpp2015_version)) {
    Write-Information "Microsoft Visual C++ 2015 Redistributable Update 3 RC is already installed - skipping installation"
} else {
    # This only applies for CxSAST 9.0+ so make sure it exists.
    if ([Utility]::Exists($cpp2015_installer)) {
        Write-Information "Installing Microsoft Visual C++ 2015 Redistributable Update 3 RC"
        Start-Process -FilePath "$cpp2015_installer" -ArgumentList "/passive /norestart" -Wait -NoNewWindow
        Write-Information "... finished Installing Microsoft Visual C++ 2015 Redistributable Update 3 RC"
    } 
}


###############################################################################
# AdoptOpenJDK Install
###############################################################################
# Java should be installed before the dotnet framework because it can piggy back
# on the required reboot which will put java on the path and refresh env vars
# which may come in useful later.
if ([Utility]::Exists("C:\Program Files\AdoptOpenJDK\bin\java.exe")) {
    Write-Information "Java is already installed - skipping installation"
} else {
    Write-Information "Installing Java"
    $javainstaller = [Utility]::Fetch($config.Dependencies.AdoptOpenJdk)
    Start-Process -FilePath "C:\Windows\System32\msiexec.exe" -ArgumentList "/i `"$javainstaller`" ADDLOCAL=FeatureMain,FeatureEnvironment,FeatureJarFileRunWith,FeatureJavaHome INSTALLDIR=`"c:\Program Files\AdoptOpenJDK\`" /quiet /L*V `"$javainstaller.log`"" -Wait -NoNewWindow
    Write-Information "... finished Installing Java"
    Start-Process "C:\Program Files\AdoptOpenJDK\bin\java.exe" -ArgumentList "-version" -RedirectStandardError ".\java-version.log" -Wait -NoNewWindow
    cat ".\java-version.log"
}

###############################################################################
#  .NET Framework 4.7.1 Install
###############################################################################
# https://docs.microsoft.com/en-us/dotnet/framework/migration-guide/how-to-determine-which-versions-are-installed#to-check-for-a-minimum-required-net-framework-version-by-querying-the-registry-in-powershell-net-framework-45-and-later
$dotnet_release = $(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full\' | Get-ItemPropertyValue -Name Release)
$dotnet_version = $(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full\' | Get-ItemPropertyValue -Name Version)
Write-Information "Found .net version ${dotnet_version}; release string: $dotnet_release"
if ($dotnet_release -gt 461308 ) {
    Write-Information "Dotnet 4.7.1 (release string: 461308 ) or higher already installed - skipping installation"
} else {
    Write-Information "Installing dotnet framework - a reboot will be required"
    $dotnetinstaller = [Utility]::Fetch($config.Dependencies.DotnetFramework)
    Start-Process -FilePath "$dotnetinstaller" -ArgumentList "/passive /norestart" -Wait -NoNewWindow
    Write-Information "... finished dotnet framework install. Rebooting now"   
    Restart-Computer -Force; 
    sleep 30 # force in case anyone is logged in
}


###############################################################################
# Git Install
###############################################################################
if ($config.Checkmarx.ComponentType -eq "Manager") {
    if (Test-Path -Path "C:\Program Files\Git\bin\git.exe") {
        Write-Information "Git is already installed - skipping installation"
    } else {
        Write-Information "Installing Git"
        $gitinstaller = [Utility]::Fetch($config.Dependencies.Git)
        Start-Process -FilePath "$gitinstaller" -ArgumentList "/VERYSILENT /NORESTART /NOCANCEL /SP- /CLOSEAPPLICATIONS" -Wait -NoNewWindow
        Write-Information "... finished Installing Git"
        Start-Process "C:\Program Files\Git\bin\git.exe" -ArgumentList "--version" -RedirectStandardOutput ".\git-version.log" -Wait -NoNewWindow
        cat ".\git-version.log"
    }
}

    
###############################################################################
# IIS Install
###############################################################################
if ($config.Checkmarx.ComponentType -eq "Manager") {
    Write-Information "Installing IIS"
    Install-WindowsFeature -name Web-Server -IncludeManagementTools
    Add-WindowsFeature Web-Http-Redirect  
    Install-WindowsFeature -Name  Web-Health -IncludeAllSubFeature
    Install-WindowsFeature -Name  Web-Performance -IncludeAllSubFeature
    Install-WindowsFeature -Name Web-Security -IncludeAllSubFeature
    Install-WindowsFeature -Name  Web-Scripting-Tools -IncludeAllSubFeature
    Write-Information "... finished Installing IIS"
}


###############################################################################
# IIS Rewrite Module Install
###############################################################################
if ($config.Checkmarx.ComponentType -eq "Manager") {
    if (Test-Path -Path "C:\Windows\System32\inetsrv\rewrite.dll") {
        Write-Information "IIS Rewrite Module is already installed - skipping installation"
    } else {
        Write-Information "Installing IIS rewrite Module"
        $rewriteinstaller = [Utility]::Fetch($config.Dependencies.IisRewriteModule)
        Start-Process "C:\Windows\System32\msiexec.exe" -ArgumentList "/i `"$rewriteinstaller`" /L*V `".\rewrite_install.log`" /QN" -Wait -NoNewWindow
        Write-Information "... finished Installing IIS Rewrite Module"
    }
}


###############################################################################
# IIS Application Request Routing Install
###############################################################################
if ($config.Checkmarx.ComponentType -eq "Manager") {
    if (($(C:\Windows\System32\inetsrv\appcmd.exe list modules) | Where  { $_ -match "ApplicationRequestRouting" } | ForEach-Object { echo $_ }).length -gt 1) {
        Write-Information "IIS Application Request Routing Module is already installed - skipping installation"
    } else {
        Write-Information "Installing IIS Application Request Routing Module"
        $requestroutinginstaller = [Utility]::Fetch($config.Dependencies.IisApplicationRequestRoutingModule)
        Start-Process "C:\Windows\System32\msiexec.exe" -ArgumentList "/i `"$requestroutinginstaller`" /L*V `".\arr_install.log`" /QN" -Wait -NoNewWindow        
        Write-Information "... finished Installing IIS Application Request Routing Module"
    }
}


###############################################################################
# Dotnet Core Hosting 2.1.16
###############################################################################
if ($config.Checkmarx.ComponentType -eq "Manager") {
    if (Test-Path -Path "C:\Program Files\dotnet") {
        Write-Information "Microsoft .NET Core 2.1.16 Windows Server Hosting is already installed - skipping installation"
    } else {
        # Only required for 9.0+ so make sure it exists
        $dotnetcore_installer = [Utility]::Find("dotnet-hosting-2.1.16-win.exe")
        if ([Utility]::Exists($dotnetcore_installer)) {
            Write-Information "Installing Microsoft .NET Core 2.1.16 Windows Server Hosting"
            Start-Process -FilePath "$dotnetcore_installer" -ArgumentList "/quiet /install /norestart" -Wait -NoNewWindow
            Write-Information "... finished Installing Microsoft .NET Core 2.1.16 Windows Server Hosting"
        }
    }    
}


###############################################################################
# Install SQL Server Express
###############################################################################
if (($config.Checkmarx.ComponentType -eq "Manager") -and ($config.Sql.UseLocalSqlExpress -eq "True")) {
    # SQL Server install should come *after* the Checkmarx installation media is unzipped. The SQL Server
    # installer is packaged in the third_party folder from the zip. 
    if ((get-service sql*).length -eq 0) {
        $sqlserverexe = [Utility]::Find("SQLEXPR*.exe")
        Write-Information "Installing SQL Server from ${sqlserverexe}"
        Start-Process "$sqlserverexe" -ArgumentList "/IACCEPTSQLSERVERLICENSETERMS /Q /ACTION=install /INSTANCEID=SQLEXPRESS /INSTANCENAME=SQLEXPRESS /UPDATEENABLED=FALSE /BROWSERSVCSTARTUPTYPE=Automatic /SQLSVCSTARTUPTYPE=Automatic /TCPENABLED=1" -Wait -NoNewWindow
        $sqlserverlog = $(Get-ChildItem "C:\Program Files\Microsoft SQL Server\110\Setup Bootstrap\Log" -Recurse -Filter "Summary.txt" | Sort -Descending | Select -First 1 -ExpandProperty FullName) 
        Write-Information "...finished Installing SQL Server. Log is:"
        cat $sqlserverlog        
    } else {
        Write-Information "SQL Server Express is already installed - skipping installation"
    }
}


###############################################################################
# Install Checkmarx
###############################################################################
$cxsetup = [Utility]::Find("CxSetup.exe")
Write-Information "Installing CxSAST with $installer_args"
Start-Process "$cxsetup" -ArgumentList "$($config.Installer.Args)" -Wait -NoNewWindow -RedirectStandardError ".\cxinstaller.err" -RedirectStandardOutput ".\cxinstaller.out"
Write-Information "...finished installing"
Write-Information "installer StandardError:"
cat .\cxinstaller.err
Write-Information "installer StandardOutput:"
cat .\cxinstaller.out

###############################################################################
# Install Checkmarx Hotfix
###############################################################################
$hotfixexe = [Utility]::Find("*HF*.exe")
Write-Information "Installing hotfix ${hotfix_name}"
Start-Process "$hotfixexe" -ArgumentList "-cmd" -Wait -NoNewWindow
Write-Information "...finished installing"    


###############################################################################
# Generate Checkmarx License
###############################################################################
if ($config.Checkmarx.ComponentType -eq "Manager") {
    Write-Information "Running automatic license generator"
    C:\programdata\checkmarx\aws-automation\scripts\configure\license-from-alg.ps1
    Write-Information "... finished running automatic license generator"
}

###############################################################################
# Post Install Windows Configuration
###############################################################################
if ($config.Checkmarx.ComponentType -eq "Manager") {
    Write-Information "Hardening IIS"
    C:\programdata\checkmarx\aws-automation\scripts\configure\configure-iis-hardening.ps1
    Write-Information "...finished hardening IIS"

    Write-Information "Configuring windows defender"
    C:\programdata\checkmarx\aws-automation\scripts\configure\configure-windows-defender.ps1
    Write-Information "...finished configuring windows defender"
}

###############################################################################
# Reverse proxy CxARM
###############################################################################
if ($config.Checkmarx.ComponentType -eq "Manager") {
    Write-Information "Configuring IIS to reverse proxy CxARM"
    C:\programdata\checkmarx\aws-automation\scripts\configure\configure-cxarm-iis-reverseproxy.ps1
    Write-Information "finished configuring IIS to reverse proxy CxARM"
}

###############################################################################
# Open Firewall for Engine
###############################################################################
if ($env:CheckmarxComponentType -eq "Engine") {
  # When the engine is installed by itself it can't piggy back on the opening of 80,443 by IIS install, so we need to explicitly open the port
  Write-Information "Adding host firewall rule for for the Engine Server"
  New-NetFirewallRule -DisplayName "CxScanEngine HTTP Port 80" -Direction Inbound -LocalPort 80 -Protocol TCP -Action Allow
  New-NetFirewallRule -DisplayName "CxScanEngine HTTP Port 443" -Direction Inbound -LocalPort 443 -Protocol TCP -Action Allow
}

if (Test-Path -Path "C:\Program Files\Checkmarx\Checkmarx Risk Management\Config\db.properties") {
    # The db.properties file can have a bug where extra spaces are not trimmed off of the DB_HOST line
    # which can cause connection string concatenation to fail due to a space between the host and :port
    # For example:
    #     TARGET_CONNECTION_STRING=jdbc:sqlserver://sqlserverdev.ckbq3owrgyjd.us-east-1.rds.amazonaws.com :1433;DatabaseName=CxARM[class java.lang.String]
    #
    # As a work around we trim the end off of each line in db.properties
    Write-Information "Fixing db.properties"
    (Get-Content "C:\Program Files\Checkmarx\Checkmarx Risk Management\Config\db.properties") | ForEach-Object {$_.TrimEnd()} | Set-Content "C:\Program Files\Checkmarx\Checkmarx Risk Management\Config\db.properties"
  
    Write-Information "Running the initial ETL sync for CxArm"
    # Todo: figure this out for Windows Auth
    Start-Process "C:\Program Files\Checkmarx\Checkmarx Risk Management\ETL\etl_executor.exe" -ArgumentList "-q -console -VSILENT_FLOW=true -Dinstall4j.logToStderr=true -Dinstall4j.debug=true -Dinstall4j.detailStdout=true" -WorkingDirectory "C:\Program Files\Checkmarx\Checkmarx Risk Management\ETL" -NoNewWindow -Wait #sql server auth vars -VSOURCE_PASS_SILENT=${db_password} -VTARGET_PASS_SILENT=${db_password}
    Write-Information "Finished initial ETL sync"
  }

$is_engine_installed = (![String]::IsNullOrEmpty((Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Checkmarx\Installation\Checkmarx Engine Server' -Name "Path")))
if ($is_engine_installed ) {
    Write-Information "Configuring max scans for the engine"
    C:\programdata\checkmarx\aws-automation\scripts\configure\configure-max-scans-per-machine.ps1 -scans 1
    Write-Information "... finished configuring engine max scans"
}

if ($config.aws.UseCloudwatchLogs) {
    Write-Information "Configuring cloudwatch logs"
    C:\programdata\checkmarx\aws-automation\scripts\configure\configure-cloudwatch-logs.ps1
    Write-Information "... finished configuring cloudwatch logs"
}

###############################################################################
# Activate Git trace logging
###############################################################################
if ($config.Checkmarx.ComponentType -eq "Manager") {
    Write-Information "Enabling Git Trace Logging"
    md -force "c:\program files\checkmarx\logs\git"
    [System.Environment]::SetEnvironmentVariable('GIT_TRACE', 'c:\program files\checkmarx\logs\git\GIT_TRACE.txt', [System.EnvironmentVariableTarget]::Machine)
    [System.Environment]::SetEnvironmentVariable('GIT_TRACE_PACK_ACCESS', 'c:\program files\checkmarx\logs\git\GIT_TRACE_PACK_ACCESS.txt', [System.EnvironmentVariableTarget]::Machine)
    [System.Environment]::SetEnvironmentVariable('GIT_TRACE_PACKET', 'c:\program files\checkmarx\logs\git\GIT_TRACE_PACKET.txt', [System.EnvironmentVariableTarget]::Machine)
    [System.Environment]::SetEnvironmentVariable('GIT_TRACE_PERFORMANCE', 'c:\program files\checkmarx\logs\git\GIT_TRACE_PERFORMANCE.txt', [System.EnvironmentVariableTarget]::Machine)
    [System.Environment]::SetEnvironmentVariable('GIT_TRACE_SETUP', 'c:\program files\checkmarx\logs\git\GIT_TRACE_SETUP.txt', [System.EnvironmentVariableTarget]::Machine)
    [System.Environment]::SetEnvironmentVariable('GIT_MERGE_VERBOSITY', 'c:\program files\checkmarx\logs\git\GIT_MERGE_VERBOSITY.txt', [System.EnvironmentVariableTarget]::Machine)
    [System.Environment]::SetEnvironmentVariable('GIT_CURL_VERBOSE', 'c:\program files\checkmarx\logs\git\GIT_CURL_VERBOSE.txt', [System.EnvironmentVariableTarget]::Machine)
    [System.Environment]::SetEnvironmentVariable('GIT_TRACE_SHALLOW', 'c:\program files\checkmarx\logs\git\GIT_TRACE_SHALLOW.txt', [System.EnvironmentVariableTarget]::Machine)
}


###############################################################################
# Install Package Managers if Configured (Required for OSA)
###############################################################################
if ($config.PackageManagers.Python3 -ne $null) {
    $python3 = [Utility]::Fetch($config.PackageManagers.Python3)
    Write-Information "Installing Python3 from $python3"
    Start-Process -FilePath $python3 -ArgumentList "/quiet InstallAllUsers=1 PrependPath=1 Include_dev=0 Include_test=0" -Wait -NoNewWindow
    Write-Information "...finished installing Python3"
}

if ($config.PackageManagers.Nodejs -ne $null) {
    $nodejs = [Utility]::Fetch($config.PackageManagers.Nodejs)
    Write-Information "Installing Nodejs from $nodejs"
    Start-Process -FilePath "C:\Windows\System32\msiexec.exe" -ArgumentList "/i `"$nodejs`" /QN /L*V c:\nodejs.log" -Wait -NoNewWindow
    Write-Information "...finished installing nodejs"
}

if ($config.PackageManagers.Nuget -ne $null) {
    $nuget = [Utility]::Fetch($config.PackageManagers.Nuget)
    Write-Information "Installing Nuget from $Nuget"
    md -force "c:\programdata\nuget"
    move $nuget c:\programdata\nuget\nuget.exe
    [Utility]::Addpath("C:\programdata\nuget")
    Write-Information "...finished installing nodejs"
}

if ($config.PackageManagers.Maven -ne $null) {
    $maven = [Utility]::Fetch($config.PackageManagers.Maven)
    Write-Information "Installing Maven from $maven"
    Expand-Archive $maven -DestinationPath 'C:\programdata\checkmarx\automation\installers' -Force
    $mvnfolder = [Utility]::Basename($maven).Replace("-bin.zip", "")
    [Utility]::Addpath("C:\programdata\checkmarx\automation\installers\${mvnfolder}\bin")
    [Environment]::SetEnvironmentVariable('MAVEN_HOME', 'C:\programdata\checkmarx\automation\installers\apache-maven-3.6.3', 'Machine')
    Write-Information "...finished installing nodejs"
}

if ($config.PackageManagers.Gradle -ne $null) {
    $gradle = [Utility]::Fetch($config.PackageManagers.Gradle)
    Write-Information "Installing Gradle from $gradle"
    Expand-Archive $gradle -DestinationPath 'C:\programdata\checkmarx\automation\installers' -Force
    $gradlefolder = [Utility]::Basename($gradle).Replace("-bin.zip", "")
    [Utility]::Addpath("C:\programdata\checkmarx\automation\installers\${gradlefolder}\bin")
    Write-Information "...finished installing nodejs"
}


###############################################################################
# Disable the provisioning task
###############################################################################
Write-Information "disabling provision-checkmarx scheduled task"
Disable-ScheduledTask -TaskName "provision-checkmarx"
Write-Information "provisioning has completed"
