# Force TLS 1.2+ and hide progress bars to prevent slow downloads
Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; 
$ProgressPreference = "SilentlyContinue"
$InformationPreference = "continue"
Start-Transcript -Path "C:\90-access-control-migration.log" -Append
. $PSScriptRoot\CheckmarxAWS.ps1
$config = Import-PowerShellDataFile -Path C:\checkmarx-config.psd1
$isManager = ($config.Checkmarx.ComponentType.ToUpper() -eq "MANAGER")
$isEngine = ($config.Checkmarx.ComponentType.ToUpper() -eq "ENGINE")
[Logger] $log = [Logger]::new("90-access-control-migration.ps1")
$log.Info("-------------------------------------------------------------------------")
$log.Info("-------------------------------------------------------------------------")
$log.Info("-------------------------------------------------------------------------")
$log.Info("90-access-control-migration.ps1 script execution beginning")


$config.Tomcat.Username = [Utility]::TryGetSSMParameter($config.Tomcat.Username)
$config.Tomcat.Password = [Utility]::TryGetSSMParameter($config.Tomcat.Password)
$config.MsSql.Username = [Utility]::TryGetSSMParameter($config.MsSql.Username)
$config.MsSql.Password = [Utility]::TryGetSSMParameter($config.MsSql.Password)
$config.Checkmarx.Username = [Utility]::TryGetSSMParameter($config.Checkmarx.Username)
$config.Checkmarx.Password = [Utility]::TryGetSSMParameter($config.Checkmarx.Password)
$config.Ssl.PfxPassword = [Utility]::TryGetSSMParameter($config.Ssl.PfxPassword)

###############################################################################
#  Create Folders
###############################################################################
$log.Info("Creating Checkmarx folders")
$env:CheckmarxHome = if ($env:CheckmarxHome -eq $null) { "C:\programdata\checkmarx" } Else { $env:CheckmarxHome }
$lockdir = "$($env:CheckmarxHome)\locks"
md -Force "$($env:CheckmarxHome)" | Out-Null
md -Force "$lockdir"
# Some cert chains require this folder to exist
md -force "C:\ProgramData\checkmarx\automation\installers\" | Out-Null 

###############################################################################
#  Debug Info
###############################################################################
if (!([Utility]::Exists("${lockdir}\systeminfo.lock"))) {
    Write-Host "################################"
    Write-Host "  System Info"
    Write-Host "################################"
    systeminfo.exe > c:\systeminfo.log
    cat c:\systeminfo.log

    Write-Host "################################"
    Write-Host " Checking for all installed updates"
    Write-Host "################################"
    Wmic qfe list  | Format-Table

    Write-Host "################################"
    Write-Host " Host Info "
    Write-Host "################################"
    Get-Host | Format-Table
    
    Write-Host "################################"
    Write-Host " Powershell Info "
    Write-Host "################################"
    (Get-Host).Version  | Format-Table

    Write-Host "################################"
    Write-Host " OS Info "
    Write-Host "################################"
    Get-WmiObject Win32_OperatingSystem | Select PSComputerName, Caption, OSArchitecture, Version, BuildNumber | Format-Table

    $log.info([Environment]::NewLine)
    $log.info([Environment]::NewLine)
    $log.Info("env:TEMP = $env:TEMP")
    $log.Info("env:CheckmarxBucket = $env:CheckmarxBucket")
    $log.Info("checkmarx-config.psd1 configuration:")
    cat C:\checkmarx-config.psd1    

    "completed" | Set-Content "${lockdir}\systeminfo.lock"
}



###############################################################################
#  Fetch Checkmarx Installation Media and Unzip
###############################################################################
if (!([Utility]::Exists("${lockdir}\ninex_installer.lock"))) {
    $ninex_installer_url = "s3://$($env:CheckmarxBucket)/installation/cxsast/9.0/CxSAST.900.Release.Setup_9.0.0.40085.zip"
    $ninex_zip = $installer_zip = [DependencyFetcher]::new($ninex_installer_url).Fetch() 
    $ninex_installer_name = $($installer_zip.Replace(".zip", "")).Split("\")[-1]

    $log.Info("Unzipping c:\programdata\checkmarx\artifacts\${ninex_zip}")
    Start-Process "C:\Program Files\7-Zip\7z.exe" -ArgumentList "x `"${ninex_zip}`" -aos -o`"C:\programdata\checkmarx\artifacts\${ninex_installer_name}`" -p`"$($env:NinexInstallerZipKey)`"" -Wait -NoNewWindow -RedirectStandardError .\ninexinstaller7z.err -RedirectStandardOutput .\ninexinstaller7z.out
    cat .\ninexinstaller7z.err
    cat .\ninexinstaller7z.out
    "completed" | Set-Content "${lockdir}\ninex_installer.lock" # lock so this unzip doesn't run on reboot
}

###############################################################################
#  Dependencies
###############################################################################

if (!([Utility]::Exists("${lockdir}\cpp2015.lock"))) {
    # Only install if it was unzipped from the installation package
    $cpp2015 = $(Get-ChildItem "$($env:CheckmarxHome)" -Recurse -Filter "vc_redist2015.x64.exe" | Sort -Descending | Select -First 1 -ExpandProperty FullName)  
    if (!([String]::IsNullOrEmpty($cpp2015))) {
        [Cpp2015RedistInstaller]::new([DependencyFetcher]::new($cpp2015).Fetch()).Install()
    }
    "completed" | Set-Content "${lockdir}\cpp2015.lock" # lock so this doesn't run on reboot
}

# Only install if it was unzipped from the installation package
if (!([Utility]::Exists("${lockdir}\dotnetcore.lock"))) {       
    $dotnetcore = $(Get-ChildItem "$($env:CheckmarxHome)" -Recurse -Filter "dotnet-hosting-2.1.16-win.exe" | Sort -Descending | Select -First 1 -ExpandProperty FullName)  
    if (!([String]::IsNullOrEmpty($dotnetcore))) {
        [DotnetCoreHostingInstaller]::new([DependencyFetcher]::new($dotnetcore).Fetch()).Install()
    }
    "completed" | Set-Content "${lockdir}\dotnetcore.lock" # lock so this doesn't run on reboot
}    

###############################################################################
# Install Checkmarx
###############################################################################
# Augment the installer augments with known configuration
$cxsast_uri = "http://localhost"
$acm_installerargs = "/install /quiet ACCEPT_EULA=Y ACCESSCONTROL=1 CXSAST_ADDRESS=""${cxsast_uri}"""


# Add the database connections to the install arguments
$acm_installerargs = "$($acm_installerargs) SQLSERVER=""$($config.MsSql.Host)"" CXARM_DB_HOST=""$($config.MsSql.Host)"""

# Add sql server authentication to the install arguments
if ($config.MsSql.UseSqlAuth -eq "True") {
    #Add the sql server authentication
    $config.Checkmarx.Installer.Args = "$($config.Checkmarx.Installer.Args) SQLAUTH=1 SQLUSER=$($config.MsSql.Username) SQLPWD=""$($config.MsSql.Password)"""
}

if (!([Utility]::Exists("${lockdir}\acmigration.lock"))) {
    $acmigration = $(Get-ChildItem "$($env:CheckmarxHome)\CxSAST.900.Release.Setup_9.0.0.40085" -Recurse -Filter "CxSetup.AC_and_Migration.exe" | Sort -Descending | Select -First 1 -ExpandProperty FullName)
    $p = Start-Process -FilePath "$acmigration" -ArgumentList "$acm_installerargs" -RedirectStandardError "${acmigration}.err.log" -RedirectStandardOutput "${acmigration}.out.log" -PassThru -NoNewWindow -Wait
    
    "complete" | Set-Content "${lockdir}\acmigration.lock"
    #restart-computer -Force
    #sleep 900
}