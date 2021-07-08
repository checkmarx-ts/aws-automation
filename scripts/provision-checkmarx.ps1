# Force TLS 1.2+ and hide progress bars to prevent slow downloads
Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; 
$ProgressPreference = "SilentlyContinue"
$InformationPreference = "continue"
Start-Transcript -Path "C:\provision-checkmarx.log" -Append
. $PSScriptRoot\CheckmarxAWS.ps1
$config = Import-PowerShellDataFile -Path C:\checkmarx-config.psd1
$isManager = ($config.Checkmarx.ComponentType.ToUpper() -eq "MANAGER")
$isEngine = ($config.Checkmarx.ComponentType.ToUpper() -eq "ENGINE")
[Logger] $log = [Logger]::new("provision-checkmarx.ps1")
$log.Info("-------------------------------------------------------------------------")
$log.Info("-------------------------------------------------------------------------")
$log.Info("-------------------------------------------------------------------------")
$log.Info("provision-checkmarx.ps1 script execution beginning")

function Get-JsonSsmParam ([string] $ssmpath) {
    $json = $null
    $ps_params = $null
    $json = $(Get-SSMParameter -Name "$ssmpath" -WithDecryption $True).Value
    $ps_params = $json | ConvertFrom-Json
    return $ps_params
}

# Fetch the SSM Parameter JSON Objects and load them into powershell
try {
    $log.Info("Fetching api ssm json config object")
    $CxApiParams = Get-JsonSsmParam "$($config.Aws.SsmPath)/api"

    if ([String]::IsNullOrEmpty($CxApiParams.username)) {
        $log.Info("API username field is null or empty - cannot continue")
        exit 1
    }
    if ([String]::IsNullOrEmpty($CxApiParams.password)) {
        $log.Info("API password field is null or empty - cannot continue")
        exit 1
    }
    $config.Checkmarx.Username = $CxApiParams.username
    $config.Checkmarx.Password = $CxApiParams.password
} catch {
    $log.Info("An error occured while fetching API parameters from $($config.Aws.SsmPath)/api")
    $_ 
    exit 1
}

try {
    $log.Info("Fetching sql ssm json config object")
    $CxSqlParams = Get-JsonSsmParam "$($config.Aws.SsmPath)/sql"

    if ([String]::IsNullOrEmpty($CxSqlParams.username)) {
        $log.Info("SQL username field is null or empty - cannot continue")
        exit 1
    }
    if ([String]::IsNullOrEmpty($CxSqlParams.password)) {
        $log.Info("SQL password field is null or empty - cannot continue")
        exit 1
    }
    $config.MsSql.Username = $CxSqlParams.username
    $config.MsSql.Password = $CxSqlParams.password
} catch {
    $log.Info("An error occured while fetching SQL parameters from $($config.Aws.SsmPath)/sql")
    $_ 
    exit 1
}


try {
    $log.Info("Fetching tomcat ssm json config object")
    $CxTomcatParams = Get-JsonSsmParam "$($config.Aws.SsmPath)/tomcat"

    if ([String]::IsNullOrEmpty($CxTomcatParams.username)) {
        $log.Info("SQL username field is null or empty - cannot continue")
        exit 1
    }
    if ([String]::IsNullOrEmpty($CxTomcatParams.password)) {
        $log.Info("SQL password field is null or empty - cannot continue")
        exit 1
    }
    $config.Tomcat.Username = $CxTomcatParams.username
    $config.Tomcat.Password = $CxTomcatParams.password
} catch {
    $log.Info("An error occured while fetching tomcat parameters from $($config.Aws.SsmPath)/tomcat")
    $_ 
    exit 1
}

$log.Info("Attempting to fetch PfxPassword from SSM")
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
#  Disk Configuration
###############################################################################
if ($isManager) {
    if (!([Utility]::Exists("${lockdir}\disk-label.lock"))) {

        $log.Info("Bringing all disks online...")
        Get-Disk | Where-Object { $_.OperationalStatus -eq "Offline" } | ForEach-Object {
            $log.Info("Bringing Disk # $($_.Number) online")
            Set-Disk -Number $_.Number -IsOffline $false 
            $log.Info("Bringing Disk # $($_.Number) writable")
            Set-Disk -Number $_.Number -IsReadOnly $false 
        }

        $log.Info("Initializing disks with C:\ProgramData\Amazon\EC2-Windows\Launch\Scripts\InitializeDisks.ps1")
        iex "C:\ProgramData\Amazon\EC2-Windows\Launch\Scripts\InitializeDisks.ps1"
        $log.Info("Finished running C:\ProgramData\Amazon\EC2-Windows\Launch\Scripts\InitializeDisks.ps1")
        
        $log.Info("Examining disks to set largest to D drive")
        Get-Partition
        $initial_data_drive = Get-Partition | Where-Object { $_.DriveLetter -eq "D" }
        $largest_data_drive = Get-Partition | Where-Object { $_.Size -gt (500 * 1024 * 1024 * 1024) }

        if ($largest_data_drive.DriveLetter -ne "D") {
            $log.Info("Reconfiguring D drive")
            Remove-PartitionAccessPath -DiskNumber $initial_data_drive.DiskNumber -PartitionNumber $initial_data_drive.PartitionNumber -AccessPath $($initial_data_drive.DriveLetter + ":")
            Get-Partition -DiskNumber $largest_data_drive.DiskNumber | Set-Partition -NewDriveLetter D            
        } else {
            $log.Info("Largest disk is already D drive - no need to remap partitions")
        }
        Get-Partition
        sleep 60

        "Complete" | Set-Content "${lockdir}\disk-label.lock"
    }
}


###############################################################################
#  Domain Join
###############################################################################
if ($isManager)  {
    if ((Get-WmiObject -Class Win32_ComputerSystem | Select -ExpandProperty PartOfDomain) -eq $True) {
        $log.Info("The computer is joined to a domain")
    } else {
        $log.Info("The computer is not joined to a domain")
        try {
            if (!([String]::IsNullOrEmpty($config.ActiveDirectory.Username))) {  # If the domain info is set in SSM parameters then join the domain
                $log.Info("Joining the computer to the domain. A reboot will occur.")
                & C:\programdata\checkmarx\aws-automation\scripts\configure\domain-join.ps1 -domainJoinUserName "$($config.ActiveDirectory.Username)" -domainJoinUserPassword "$($config.ActiveDirectory.Password)" -primaryDns $($config.ActiveDirectory.PrimaryDns) -secondaryDns $($config.ActiveDirectory.SecondaryDns) -domainName $($config.ActiveDirectory.DomainName)
                # In case the implicit restart does not occur or is overridden
                Restart-Computer -Force
                Sleep 900
            }    
        } catch {
            $log.Info("An error occured while joining to domain. Is the ${ssmprefix}/domain/name ssm parameter set? Assuming that no domain join was intended.")
            $_
        }
    }
}


###############################################################################
#  Fetch Checkmarx Installation Media and Unzip
###############################################################################


if (!([Utility]::Exists("${lockdir}\7zip.lock"))) {
    # First install 7zip so it can unzip password protected zip files.
    [SevenZipInstaller]::new([DependencyFetcher]::new($config.Dependencies.Sevenzip).Fetch()).Install()
    "Complete" | Set-Content "${lockdir}\7zip.lock"
}

if (!([Utility]::Exists("${lockdir}\installer.lock"))) {
    # Download/Unzip the Checkmarx installer. 
    # Many dependencies (cpp redists, dotnet core, sql server express) comes from this zip so it must be unzipped early in the process. 
    # The 7zip unzip process is not guarded and instead we use -aos option to skip existing files so there is not a material time penalty for the unguarded command
    $installer_zip = [DependencyFetcher]::new($config.Checkmarx.Installer.Url).Fetch()  
    $installer_name = $($installer_zip.Replace(".zip", "")).Split("\")[-1]

    $log.Info("Unzipping ${installer_zip}")
    Start-Process "C:\Program Files\7-Zip\7z.exe" -ArgumentList "x `"${installer_zip}`" -aos -o`"C:\programdata\checkmarx\artifacts\${installer_name}`" -p`"$($config.Checkmarx.Installer.ZipKey)`"" -Wait -NoNewWindow -RedirectStandardError .\installer7z.err -RedirectStandardOutput .\installer7z.out
    cat .\installer7z.err
    cat .\installer7z.out
    "completed" | Set-Content "${lockdir}\installer.lock" # lock so this unzip doesn't run on reboot
}

if (!([Utility]::Exists("${lockdir}\hotfix.lock"))) {
    # Download/Unzip the Checkmarx Hotfix
    $hfinstaller = [DependencyFetcher]::new($config.Checkmarx.Hotfix.Url).Fetch()  
    $hotfix_name = $($hfinstaller.Replace(".zip", "")).Split("\")[-1]

    $log.Info("Unzipping ${hotfix_zip}")
    Start-Process "C:\Program Files\7-Zip\7z.exe" -ArgumentList "x `"$hfinstaller`" -aos -o`"C:\programdata\checkmarx\artifacts\${hotfix_name}`" -p`"$($config.Checkmarx.Hotfix.ZipKey)`"" -Wait -NoNewWindow -RedirectStandardError .\hotfix7z.err -RedirectStandardOutput .\hotfix7z.out
    cat .\hotfix7z.err
    cat .\hotfix7z.out
    "completed" | Set-Content "${lockdir}\hotfix.lock" # lock so this unzip doesn't run on reboot
}




###############################################################################
#  Dependencies
###############################################################################
if (!([Utility]::Exists("${lockdir}\cpp2010.lock"))) {
    # Only install if it was unzipped from the installation package
    $cpp2010 = $(Get-ChildItem "$($env:CheckmarxHome)" -Recurse -Filter "vcredist_x64.exe" | Sort -Descending | Select -First 1 -ExpandProperty FullName)  
    if (!([String]::IsNullOrEmpty($cpp2010))) {
        [Cpp2010RedistInstaller]::new([DependencyFetcher]::new($cpp2010).Fetch()).Install()
    }  
    "completed" | Set-Content "${lockdir}\cpp2010.lock" # lock so this doesn't run on reboot
}

if (!([Utility]::Exists("${lockdir}\cpp2015.lock"))) {
    # Only install if it was unzipped from the installation package
    #$cpp2015 = $(Get-ChildItem "$($env:CheckmarxHome)" -Recurse -Filter "vc_redist2015.x64.exe" | Sort -Descending | Select -First 1 -ExpandProperty FullName)  
    #use 9.3 version c++
    $cpp2015 = $(Get-ChildItem "$($env:CheckmarxHome)" -Recurse -Filter "VC_redist.x64.exe" | Sort -Descending | Select -First 1 -ExpandProperty FullName)  
    if (!([String]::IsNullOrEmpty($cpp2015))) {
        [Cpp2015RedistInstaller]::new([DependencyFetcher]::new($cpp2015).Fetch()).Install()
    }
    "completed" | Set-Content "${lockdir}\cpp2015.lock" # lock so this doesn't run on reboot
}

if (!([Utility]::Exists("${lockdir}\adoptopenjdk.lock"))) {
    [AdoptOpenJdkInstaller]::new([DependencyFetcher]::new($config.Dependencies.AdoptOpenJdk).Fetch()).Install()
    "completed" | Set-Content "${lockdir}\adoptopenjdk.lock" # lock so this doesn't run on reboot
}  

if (!([Utility]::Exists("${lockdir}\dotnetframework.lock"))) {
    [DotnetFrameworkInstaller]::new([DependencyFetcher]::new($config.Dependencies.DotnetFramework).Fetch()).Install()
    "completed" | Set-Content "${lockdir}\dotnetframework.lock" # lock so this doesn't run on reboot
    Restart-Computer -Force; 
    sleep 900 # force in case anyone is logged in
} 

if ($isManager) {
    if (!([Utility]::Exists("${lockdir}\git.lock"))) {
        [GitInstaller]::new([DependencyFetcher]::new($config.Dependencies.Git).Fetch()).Install()
        "completed" | Set-Content "${lockdir}\git.lock" # lock so this doesn't run on reboot
    }           
        
    if (!([Utility]::Exists("${lockdir}\iis.lock"))) {    
        [IisInstaller]::new().Install()
        "completed" | Set-Content "${lockdir}\iis.lock" # lock so this doesn't run on reboot
        Restart-Computer -Force
        Sleep 900
    }           

    if (!([Utility]::Exists("${lockdir}\iisurlrewrite.lock"))) {        
        [IisUrlRewriteInstaller]::new([DependencyFetcher]::new($config.Dependencies.IisRewriteModule).Fetch()).Install()
        "completed" | Set-Content "${lockdir}\iisurlrewrite.lock" # lock so this doesn't run on reboot
    }           

    if (!([Utility]::Exists("${lockdir}\iisarr.lock"))) {            
        [IisApplicationRequestRoutingInstaller]::new([DependencyFetcher]::new($config.Dependencies.IisApplicationRequestRoutingModule).Fetch()).Install()
        "completed" | Set-Content "${lockdir}\iisarr.lock" # lock so this doesn't run on reboot
    }           

    # Only install if it was unzipped from the installation package
    if (!([Utility]::Exists("${lockdir}\dotnetcore.lock"))) {       
        $dotnetcore = $(Get-ChildItem "$($env:CheckmarxHome)" -Recurse -Filter "dotnet-hosting-2.1.16-win.exe" | Sort -Descending | Select -First 1 -ExpandProperty FullName)  
        if (!([String]::IsNullOrEmpty($dotnetcore))) {
            [DotnetCoreHostingInstaller]::new([DependencyFetcher]::new($dotnetcore).Fetch()).Install()
        }
        "completed" | Set-Content "${lockdir}\dotnetcore.lock" # lock so this doesn't run on reboot
    }          

    if (!([Utility]::Exists("${lockdir}\sqlexpress.lock"))) {        
        if ($config.MsSql.UseLocalSqlExpress -eq "True") {
            [MsSqlServerExpressInstaller]::new([DependencyFetcher]::new("SQLEXPR*.exe").Fetch()).Install()
        }
        "completed" | Set-Content "${lockdir}\sqlexpress.lock" # lock so this doesn't run on reboot
    }
}


###############################################################################
# Generate Checkmarx License
###############################################################################
if ($isManager) {
    if ($config.Checkmarx.License.Url -eq $null) {
        $log.Warn("No license url specified")
    } elseif ($config.Checkmarx.License.Url.EndsWith(".cxl")) {
        $log.Info("License file provided and will be downloaded.")
        [Utility]::Fetch($config.Checkmarx.License.Url)
    } elseif ($config.Checkmarx.License.Url -eq "ALG") {
        if (!(Test-Path -Path "${lockdir}\alg.lock")) {
            $log.Info("Running automatic license generator")
            try {
                C:\programdata\checkmarx\aws-automation\scripts\configure\license-from-alg.ps1
                $log.Info("... finished running automatic license generator")
            } catch {
                $log.Error("an error occured while running the ALG. Error details follows. The provisoning process will continue w/o a license")
                $_
            }
            "ALG Completed" | Set-Content "${lockdir}\alg.lock"
        } else {
            $log.Info("ALG already ran previously. Skipping")
        }
    } elseif (!([String]::IsNullOrEmpty($config.Checkmarx.License.Url))) {
        $log.Warn("config.Checkmarx.License.Url value provided ($($config.Checkmarx.License.Url)) but not sure how to handle. Valid values are 'ALG' and 's3://bucket/keyprefix/somelicensefile.cxl' (must end in .cxl)")
    } else {
        if ($isManager) {
            # A manager w/o a license should generate a warning, otherwise it is informational
            $log.Warn("No license url provided for config.Checkmarx.License.Url")
        } else {
            $log.Info("No license url provided for config.Checkmarx.License.Url")        
        }
    }

    # Update the installation command line arguments to specify the license file
    $license_file = [Utility]::Find("*.cxl")
    if ([Utility]::Exists($license_file)) {
        $log.Info("Using $license_file")
        $config.Checkmarx.Installer.Args = "$($config.Checkmarx.Installer.Args) LIC=""$($license_file)"""
    } 
}

# ie4uinit.exe is a process that is used to refresh icons on a users desktop.
# In certain situations it can cause the installer to block when running a headless
# install. 
if (!(Test-Path -Path "${lockdir}\ie4uinit.lock")) {
    $log.Info("Creating reaper task for ie4uinit")
    $action = New-ScheduledTaskAction -Execute 'C:\Windows\System32\cmd.exe' -Argument "/C powershell.exe -NoProfile -NonInteractive -NoLogo -ExecutionPolicy Unrestricted -Command `"Get-Process -Name ie4uinit -ErrorAction SilentlyContinue | Stop-Process -Force;`"" 
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -DontStopOnIdleEnd -ExecutionTimeLimit 0
    $restartInterval = new-timespan -Minute 1
    $triggers = @($(New-ScheduledTaskTrigger -AtStartup),$(New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval $restartInterval))
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest
    Register-ScheduledTask -Action $action -Principal $principal -Trigger $triggers -Settings $settings -TaskName "checkmarx-ie4uinit-reaper" -Description "Looks for ie4uinit process that hang during the headless cx install and kills them"
    $log.Info("ie4uinit reaper task has been created")
    "ie4uinit installed" | Set-Content "${lockdir}\ie4uinit.lock"
}

# Create the database shells when needed for RDS or other install w/o SA permission
if ($isManager -and !(Test-Path -Path "${lockdir}\initdatabases.lock")) {
    try {
        [DbUtility] $dbUtil = $null
        if ($config.MsSql.UseSqlAuth.ToUpper() -eq "TRUE") {
            # Swap for sql authn version if needed
            $dbUtil = [DbUtility]::New($config.MsSql.Host, $config.MsSql.Username, $config.MsSql.Password)
        } else {
            $dbUtil = [DbUtility]::New($config.MsSql.Host)
        }
        $dbUtil.ensureCxActivityExists()
        $dbUtil.ensureCxDbExists()
        if ($config.Checkmarx.Installer.Args.contains("BI=1")) {
            $dbUtil.ensureCxArmExists()
        }        
    } catch {
        $log.Error("An exception occured while ensuring that databases exist")
        $_
    }
    "databases initialized" | Set-Content "${lockdir}\initdatabases.lock"
}

###############################################################################
# Install Checkmarx
###############################################################################
# Augment the installer augments with known configuration

# Add the database connections to the install arguments
$config.Checkmarx.Installer.Args = "$($config.Checkmarx.Installer.Args) SQLSERVER=""$($config.MsSql.Host)"" CXARM_DB_HOST=""$($config.MsSql.Host)"""

# Add sql server authentication to the install arguments
if ($config.MsSql.UseSqlAuth -eq "True") {
    #Add the sql server authentication
    $config.Checkmarx.Installer.Args = "$($config.Checkmarx.Installer.Args) SQLAUTH=1 SQLUSER=$($config.MsSql.Username) SQLPWD=""$($config.MsSql.Password)"""
    $config.Checkmarx.Installer.Args = "$($config.Checkmarx.Installer.Args) CXARM_SQLAUTH=1 CXARM_DB_USER=$($config.MsSql.Username) CXARM_DB_PASSWORD=""$($config.MsSql.Password)"""
}






#-----------------------------------------------------------------------------------------------------------------------
# If this is an engine server and NOT a manager, then we need to wait here until the engineConfiguration.json file
# is uploaded to s3 so we can fetch it from that location and use it in the install. The manager installation creates
# some data that is required to successfully install the engine server. 
#
# The scenario where both an engine and a manager are installed will be handled later in this script. 
#-----------------------------------------------------------------------------------------------------------------------

if ($isEngine -and (!($isManager))) {
    Write-Host "$(Get-Date) Waiting for the engineConfiguration.json file to be ready in s3." 
    $s3object = ""
    while ([String]::IsNullOrEmpty($s3object)) {        
        Write-Host "$(Get-Date) Searching s3://$($env:CheckmarxBucket)/$($env:CheckmarxEnvironment)/engineConfiguration.json"
        try {
            $s3object = (Get-S3Object -BucketName $env:CheckmarxBucket -Key "$($env:CheckmarxEnvironment)/engineConfiguration.json" | Select -ExpandProperty Key | Sort -Descending | Select -First 1)
        } catch {
            Write-Host "ERROR: An exception occured calling Get-S3Object cmdlet. Check IAM Policies and if AWS Powershell is installed"
            exit 1
        }
        sleep 30
    }    

    Write-Host "Found s3://$env:CheckmarxBucket/$s3object"
    $filename = $s3object.Substring($s3object.LastIndexOf("/") + 1)
    try {
       Write-Host "Downloading from s3://$env:CheckmarxBucket/$s3object"
       Read-S3Object -BucketName $env:CheckmarxBucket -Key $s3object -File "C:\ProgramData\CheckmarxAutomation\Artifacts\engineConfiguration.json"
       Write-Host "Finished downloading $filename"
       $config.Checkmarx.InstallerArgs = "$($config.Checkmarx.InstallerArgs) ENGINE_SETTINGS_FILE=""C:\ProgramData\CheckmarxAutomation\Artifacts\engineConfiguration.json"""
    } catch {
       Throw "ERROR: An exception occured calling Read-S3Object cmdlet. Check IAM Policies and if AWS Powershell is installed"
       exit 1
    }
}







if (!([Utility]::Exists("${lockdir}\cxsastinstall.lock"))) {
    # Install Checkmarx and the Hotfix


    if ($config.Checkmarx.Installer.Args.ToUpper().Contains(("BI=1"))) {

        # When the BI component is installed on an existing database the GUI installer
        # will not allow you to continue. The authoritative way to do this is to install
        # everything except BI, then run the installer again to add the BI component.
        # We can detect this scenario of BI=1 in the install args and run the install args
        # twice - the first time we set BI=0, then rerun with the full install args to 
        # complete the installation. 

        Write-Host "$(Get-Date) Performing CxSAST install in 2 phases"
        $temporary_install_args = $config.Checkmarx.Installer.Args.Replace("BI=1", "BI=0")

        Write-Host "$(Get-Date) Installing CxSAST without BI=1 first"
        [BasicInstaller]::new([Utility]::Find("CxSetup.exe"), $temporary_install_args).BaseInstall()
        [CxSastServiceController]::new().DisableAll()
    }

    Write-Host "$(Get-Date) Installing CxSAST with specified install args"


    [BasicInstaller]::new([Utility]::Find("CxSetup.exe"), $config.Checkmarx.Installer.Args).BaseInstall()
    [CxSastServiceController]::new().DisableAll()
    
    
    
    "complete" | Set-Content "${lockdir}\cxsastinstall.lock"
    restart-computer -Force
    sleep 900
}

if (!([Utility]::Exists("${lockdir}\cxhfinstall.lock"))) {
    #[CxSastInstaller]::new([Utility]::Find("CxSetup.exe"), $config.Checkmarx.Installer.Args).Install()
    [CxSastHotfixInstaller]::new([Utility]::Find("*HF*.exe")).Install()
    [CxSastServiceController]::new().EnableAll()
    "complete" | Set-Content "${lockdir}\cxhfinstall.lock"
    #restart-computer -Force
    #sleep 900
}



###############################################################################
# DB Configuration
###############################################################################
try {
    if ($isManager) {
        $log.Info("Applying DB configuration")
        [DbClient] $cxdb = [DbClient]::new($config.MsSql.Host, "CxDB", ($config.MsSql.UseSqlAuth.ToUpper() -eq "FALSE"), $config.MsSql.Username, $config.MsSql.Password)
        #$cxdb.ExecuteSql
        #$cxdb.ExecuteNonQuery
        if (!([String]::IsNullOrEmpty($config.CxComponentConfiguration.GIT_EXE_PATH))) {
            $log.Info("Updating GIT_EXE_PATH")
            $cxdb.ExecuteNonQuery("update [dbo].[CxComponentConfiguration] set [value] = '$($config.CxComponentConfiguration.GIT_EXE_PATH)' where [key] = 'GIT_EXE_PATH'")
        }

        if (!([String]::IsNullOrEmpty($config.CxComponentConfiguration.IdentityAuthority))) {
            $log.Info("Updating IdentityAuthority")
            $cxdb.ExecuteNonQuery("update [dbo].[CxComponentConfiguration] set [value] = '$($config.CxComponentConfiguration.IdentityAuthority)' where [key] = 'IdentityAuthority'")
        }

        if (!([String]::IsNullOrEmpty($config.CxComponentConfiguration.CxSASTManagerUri))) {
            $log.Info("Updating CxSASTManagerUri")
            $cxdb.ExecuteNonQuery("update [dbo].[CxComponentConfiguration] set [value] = '$($config.CxComponentConfiguration.CxSASTManagerUri)' where [key] = 'CxSASTManagerUri'")
        }

        if (!([String]::IsNullOrEmpty($config.CxComponentConfiguration.CxARMPolicyUrl))) {
            $log.Info("Updating CxARMPolicyUrl")
            $cxdb.ExecuteNonQuery("update [dbo].[CxComponentConfiguration] set [value] = '$($config.CxComponentConfiguration.CxARMPolicyUrl)' where [key] = 'CxARMPolicyUrl'")
        }

        if (!([String]::IsNullOrEmpty($config.CxComponentConfiguration.CxARMURL))) {
            $log.Info("Updating CxARMURL")
            $cxdb.ExecuteNonQuery("update [dbo].[CxComponentConfiguration] set [value] = '$($config.CxComponentConfiguration.CxARMURL)' where [key] = 'CxARMURL'")
        }
        
        if (!([String]::IsNullOrEmpty($config.CxComponentConfiguration.WebServer))) {
            $log.Info("Updating WebServer")
            $cxdb.ExecuteNonQuery("update [dbo].[CxComponentConfiguration] set [value] = '$($config.CxComponentConfiguration.WebServer)' where [key] = 'WebServer'")
        }

        if (!([String]::IsNullOrEmpty($config.CxComponentConfiguration.SamlServiceProviderIssuer))) {
            $log.Info("Updating SamlServiceProviderIssuer")
            $cxdb.ExecuteNonQuery("update [dbo].[CxComponentConfiguration] set [value] = '$($config.CxComponentConfiguration.SamlServiceProviderIssuer)' where [key] = 'SamlServiceProviderIssuer'")
        }
            
        if (!([String]::IsNullOrEmpty($config.CxComponentConfiguration.ActiveMessageQueueURL))) {
            $log.Info("Updating ActiveMessageQueueURL")
            $cxdb.ExecuteNonQuery("update [dbo].[CxComponentConfiguration] set [value] = '$($config.CxComponentConfiguration.ActiveMessageQueueURL)' where [key] = 'ActiveMessageQueueURL'")
        }

        if (!([String]::IsNullOrEmpty($config.CxComponentConfiguration.SOURCE_PATH))) {
            $log.Info("Updating SOURCE_PATH")
            $cxdb.ExecuteNonQuery("update [dbo].[CxComponentConfiguration] set [value] = '$($config.CxComponentConfiguration.SOURCE_PATH)' where [key] = 'SOURCE_PATH'")
        }

        if (!([String]::IsNullOrEmpty($config.CxComponentConfiguration.REPORTS_PATH))) {
            $log.Info("Updating REPORTS_PATH")
            $cxdb.ExecuteNonQuery("update [dbo].[CxComponentConfiguration] set [value] = '$($config.CxComponentConfiguration.REPORTS_PATH)' where [key] = 'REPORTS_PATH'")
        }

        if (!([String]::IsNullOrEmpty($config.CxComponentConfiguration.EngineScanLogsPath))) {
            $log.Info("Updating EngineScanLogsPath")
            $cxdb.ExecuteNonQuery("update [dbo].[CxComponentConfiguration] set [value] = '$($config.CxComponentConfiguration.EngineScanLogsPath)' where [key] = 'EngineScanLogsPath'")
        }

        if (!([String]::IsNullOrEmpty($config.CxComponentConfiguration.EX_SOURCE_PATH))) {
            $log.Info("Updating EX_SOURCE_PATH")
            $cxdb.ExecuteNonQuery("update [dbo].[CxComponentConfiguration] set [value] = '$($config.CxComponentConfiguration.EX_SOURCE_PATH)' where [key] = 'EX_SOURCE_PATH'")
        }

        if (!([String]::IsNullOrEmpty($config.CxComponentConfiguration.IsLongPathEnabled))) {
            $log.Info("Updating IsLongPathEnabled")
            $cxdb.ExecuteNonQuery("update [dbo].[CxComponentConfiguration] set [value] = '$($config.CxComponentConfiguration.IsLongPathEnabled)' where [key] = 'IsLongPathEnabled'")
        }

        if (!([String]::IsNullOrEmpty($config.CxComponentConfiguration.NumberOfPromotableScans))) {
            $log.Info("Updating NumberOfPromotableScans")
            $cxdb.ExecuteNonQuery("update [dbo].[CxComponentConfiguration] set [value] = '$($config.CxComponentConfiguration.NumberOfPromotableScans)' where [key] = 'NumberOfPromotableScans'")
        }

        if (!([String]::IsNullOrEmpty($config.CxComponentConfiguration.ActiveMessageQueueURL))) {
            $log.Info("Updating ACTIVE_MESSAGE_QUEUE_URL")
            $cxdb.ExecuteNonQuery("update [Config].[CxEngineConfigurationKeysMeta] set [value] = '$($config.CxComponentConfiguration.ActiveMessageQueueURL)' where [key] = 'ACTIVE_MESSAGE_QUEUE_URL'")
        }

        if (!([String]::IsNullOrEmpty($config.CxComponentConfiguration.WebServer))) {
            # SERVER_PUBLIC_ORIGIN should key off WebServer
            $log.Info("Updating SERVER_PUBLIC_ORIGIN")
            $cxdb.ExecuteNonQuery("update [accesscontrol].[ConfigurationItems] set [value] = '$($config.CxComponentConfiguration.WebServer)' where [key] = 'SERVER_PUBLIC_ORIGIN'")
        }

        if (!([String]::IsNullOrEmpty($config.Amq.Password))) {
            $log.Info("Updating AMQ Password")
            $cxdb.ExecuteNonQuery("update [dbo].[CxComponentConfiguration] set [value] = '$($config.Amq.Password)' where [key] = 'MessageQueuePassword'")
            $cxdb.ExecuteNonQuery("Update [Config].[CxEngineConfigurationKeysMeta] set [DefaultValue] = (SELECT TOP 1 [Value]  FROM [CxDB].[dbo].[CxComponentConfiguration]  where [Key] = 'MessageQueuePassword') where [KeyName]='MESSAGE_QUEUE_PASSWORD'")
        }
    }
} catch {
    $log.Warn("An error occured updating the database")
    $_
}







###############################################################################
# Post Install Windows Configuration
#
# After Checkmarx is installed there are a number of things to configure. 
#
###############################################################################
if ($isManager) {
    $log.Info("Hardening IIS")
    C:\programdata\checkmarx\aws-automation\scripts\configure\configure-iis-hardening.ps1
    $log.Info("...finished hardening IIS")
}

###############################################################################
# Reverse proxy CxARM
###############################################################################
if ($isManager -and ($config.Checkmarx.Installer.Args.contains("BI=1"))) {
    $log.Info("Configuring IIS to reverse proxy CxARM")
    $arm_server = "http://localhost:8080"
    Set-WebConfigurationProperty -pspath 'MACHINE/WEBROOT/APPHOST'  -filter "system.webServer/proxy" -name "enabled" -value "True"
    $log.Info("Adding rewrite-rule for /cxarm -> ${arm_server}")
    $site = "iis:\sites\Default Web Site"
    $filterRoot = "system.webServer/rewrite/rules/rule[@name='cxarm']"
    Add-WebConfigurationProperty -pspath $site -filter "system.webServer/rewrite/rules" -name "." -value @{name='cxarm';patternSyntax='Regular Expressions';stopProcessing='False'}
    Set-WebConfigurationProperty -pspath $site -filter "$filterRoot/match" -name "url" -value "^(cxarm/.*)"
    Set-WebConfigurationProperty -pspath $site -filter "$filterRoot/action" -name "type" -value "Rewrite"
    Set-WebConfigurationProperty -pspath $site -filter "$filterRoot/action" -name "url" -value "${arm_server}/{R:0}"
    $log.Info("finished configuring IIS to reverse proxy CxARM")
}

###############################################################################
# Set ASP.Net Session Timeout for the Portal
###############################################################################
if ($config.Checkmarx.Installer.Args.Contains("WEB=1")) {
    $log.Info("Configuring Timeout for CxSAST Web Portal to: $($config.Checkmarx.PortalSessionTimeout)")
    # Session timeout if you wish to change it. Default is 1440 minutes (1 day) 
    # Set-WebConfigurationProperty cmdlet is smart enough to convert it into minutes, which is what .net uses
    # See https://checkmarx.atlassian.net/wiki/spaces/PTS/pages/85229666/Configuring+session+timeout+in+Checkmarx
    # See https://blogs.iis.net/jeonghwan/iis-powershell-user-guide-comparing-representative-iis-ui-tasks for examples
    # $sessionTimeoutInMinutes = "01:20:00" # 1 hour 20 minutes - must use timespan format here (HH:MM:SS) and do NOT set any seconds as seconds are invalid options.
    # Prefer this over direct XML file access to support variety of session state providers
    Set-WebConfigurationProperty -pspath 'MACHINE/WEBROOT/APPHOST/Default Web Site/CxWebClient' -filter "system.web/sessionState" -name "timeout" -value "$($config.Checkmarx.PortalSessionTimeout)"
    $log.Info("... finished configuring timeout")
}


###############################################################################
# Open Firewall for Engine
###############################################################################
if ($isEngine) {
  # When the engine is installed by itself it can't piggy back on the opening of 80,443 by IIS install, so we need to explicitly open the port
  $log.Info("Adding host firewall rule for for the Engine Server")
  New-NetFirewallRule -DisplayName "CxScanEngine HTTP Port 80" -Direction Inbound -LocalPort 80 -Protocol TCP -Action Allow
  New-NetFirewallRule -DisplayName "CxScanEngine HTTP Port 443" -Direction Inbound -LocalPort 443 -Protocol TCP -Action Allow
}

###############################################################################
# Run the initial CxARM ETL Sync Job
###############################################################################
if (Test-Path -Path "C:\Program Files\Checkmarx\Checkmarx Risk Management\Config\db.properties") {
    # The db.properties file can have a bug where extra spaces are not trimmed off of the DB_HOST line
    # which can cause connection string concatenation to fail due to a space between the host and :port
    # For example:
    #     TARGET_CONNECTION_STRING=jdbc:sqlserver://sqlserverdev.ckbq3owrgyjd.us-east-1.rds.amazonaws.com :1433;DatabaseName=CxARM[class java.lang.String]
    #
    # As a work around we trim the end off of each line in db.properties
    $log.Info("Fixing db.properties")
    (Get-Content "C:\Program Files\Checkmarx\Checkmarx Risk Management\Config\db.properties") | ForEach-Object {$_.TrimEnd()} | Set-Content "C:\Program Files\Checkmarx\Checkmarx Risk Management\Config\db.properties"
    
    # DB_PORT can not be set in some cases which will cause the ETL Initial Sync silent invocation to fail, so make sure the DB_PORT is configured here. 
    (Get-Content -path "C:\Program Files\Checkmarx\Checkmarx Risk Management\Config\db.properties") | % { $_ -Replace '^DB_PORT=$', "DB_PORT=$($config.MsSql.Port)" } |  Set-Content "C:\Program Files\Checkmarx\Checkmarx Risk Management\Config\db.properties"
  
} else {
      $log.Info("C:\Program Files\Checkmarx\Checkmarx Risk Management\Config\db.properties file was NOT found")
}

try { 
    if ($isManager -and ($config.Checkmarx.Installer.Args.contains("BI=1"))) {
        # Check for the initial sync run status from the database
        [DbClient] $cxdb = [DbClient]::new($config.MsSql.Host, "CxDB", ($config.MsSql.UseSqlAuth.ToUpper() -eq "FALSE"), $config.MsSql.Username, $config.MsSql.Password)
        $arm_initial_sync_status = $cxdb.ExecuteSql("SELECT * FROM [CxARM].[dbo].[SyncLog] where sync_type = 'INITIAL'")
        
        if ($arm_initial_sync_status.state -eq "PASSED") {
            $log.Info("CxARM Initial Sync already completed")
        } else {
            $log.Info("CxARM initial sync has not run before")        
            $log.Info("Running the initial ETL sync for CxArm")
            Start-Process "C:\Program Files\Checkmarx\Checkmarx Risk Management\ETL\etl_executor.exe" -ArgumentList "-q -console -VSILENT_FLOW=true -VSOURCE_PASS_SILENT=""$($config.MsSql.Password)"" -VTARGET_PASS_SILENT=""$($config.MsSql.Password)"" -Dinstall4j.logToStderr=true -Dinstall4j.debug=true -Dinstall4j.detailStdout=true" -WorkingDirectory "C:\Program Files\Checkmarx\Checkmarx Risk Management\ETL" -NoNewWindow -Wait 
            $log.Info("Finished initial ETL sync")
        }
    } else {
        $log.Info("CxARM (BI) component not installed - skipping ARM Initial ETL sync check and execution")
    }    
} catch {
    $log.Error("An error occured running ETL sync")
    $_
}


###############################################################################
# Configure AWS Cloudwatch Logs
###############################################################################
if ($config.aws.UseCloudwatchLogs) {
    $log.Info("Configuring cloudwatch logs")
    C:\programdata\checkmarx\aws-automation\scripts\configure\configure-cloudwatch-logs.ps1
    $log.Info("... finished configuring cloudwatch logs")
}


###############################################################################
# Configure max scans on engine
###############################################################################
if ($config.Checkmarx.Installer.Args.Contains("ENGINE=1")) {
    $log.Info("Configuring engine MAX_SCANS_PER_MACHINE to $($config.Checkmarx.MaxScansPerMachine)")
    $config_file = "$(Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Checkmarx\Installation\Checkmarx Engine Server' -Name 'Path')\CxSourceAnalyzerEngine.WinService.exe.config"
    [Xml]$xml = Get-Content "$config_file"
    $obj = $xml.configuration.appSettings.add | where {$_.Key -eq "MAX_SCANS_PER_MACHINE" }
    $obj.value = "$($config.Checkmarx.MaxScansPerMachine)" 
    $xml.Save("$config_file")     
    $log.Info("... finished configuring engine MAX_SCANS_PER_MACHINE" )
}


###############################################################################
# Activate Git trace logging
###############################################################################
if ($isManager) {
    $log.Info("Enabling Git Trace Logging")
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
if ($isManager) {
    if ($config.PackageManagers.Python3 -ne $null) {
       [BasicInstaller]::new([DependencyFetcher]::new($config.PackageManagers.Python3).Fetch(),
                      "/quiet InstallAllUsers=1 PrependPath=1 Include_dev=0 Include_test=0").BaseInstall()
    }

    if ($config.PackageManagers.Nodejs -ne $null) {
        [BasicInstaller]::new([DependencyFetcher]::new($config.PackageManagers.Nodejs).Fetch(),
                    "/QN").BaseInstall()
    }

    if ($config.PackageManagers.Nuget -ne $null) {
        $nuget = [Utility]::Fetch($config.PackageManagers.Nuget)
        $log.Info("Installing Nuget from $Nuget")
        md -force "c:\programdata\nuget"
        move $nuget c:\programdata\nuget\nuget.exe
        [Utility]::Addpath("C:\programdata\nuget")
        $log.Info("...finished installing Nuget")
    }

    if ($config.PackageManagers.Maven -ne $null) {
        $maven = [Utility]::Fetch($config.PackageManagers.Maven)
        $log.Info("Installing Maven from $maven")
        Expand-Archive $maven -DestinationPath 'C:\programdata\checkmarx\artifacts' -Force
        $mvnfolder = [Utility]::Basename($maven).Replace("-bin.zip", "")
        [Utility]::Addpath("${mvnfolder}\bin")
        [Environment]::SetEnvironmentVariable('MAVEN_HOME', $mvnfolder, 'Machine')
        $log.Info("...finished installing Maven")
    }

    if ($config.PackageManagers.Gradle -ne $null) {
        $gradle = [Utility]::Fetch($config.PackageManagers.Gradle)
        $log.Info("Installing Gradle from $gradle")
        Expand-Archive $gradle -DestinationPath 'C:\programdata\checkmarx\artifacts' -Force
        $gradlefolder = [Utility]::Basename($gradle).Replace("-bin.zip", "")
        [Utility]::Addpath("${gradlefolder}\bin")
        $log.Info("...finished installing Gradle")
    }
}

###############################################################################
# Trusted Certs
###############################################################################
$certalias = 0
$config.Ssl.TrustedCerts | ForEach-Object {
    $certalias++
    if (!([String]::IsNullOrEmpty($_))) {

        $cert = [DependencyFetcher]::new($_).Fetch()  
        try {
            $log.Info("Attempting to import $_ into LocaMachine\Root and LocalMachine\TrustedPublisher cert stores")            
            Import-Certificate -FilePath  "${cert}" -CertStoreLocation "Cert:\LocalMachine\Root"
            Import-Certificate -FilePath  "${cert}" -CertStoreLocation "Cert:\LocalMachine\TrustedPublisher"            

        } catch {
            $log.Warn("An error occured attempting to import $_ into LocaMachine\Root and LocalMachine\TrustedPublisher cert stores")
        }

        $certalias = $_

        gci "C:\Program Files\Checkmarx" -Recurse -Filter "cacerts" | ForEach-Object {
            $cacerts = $_.FullName 
            try {
                if (![String]::IsNullOrEmpty($cacerts)) {
                    $log.Info("Importing ${cert} to ${cacerts} with alias $($certalias)")
                    keytool -importcert -file "${cert}" -keystore "${cacerts}" -storepass "changeit" -alias "$certalias" -noprompt
                    $log.Info("Finished import ${cert} to ${cacerts}")
                }
            } catch {
                 # Import the cert to the java keystore with its filename as alias. If that fails, use a incremental alias.
                if (![String]::IsNullOrEmpty($cacerts)) {
                    keytool -importcert -file "${cert}" -keystore "${cacerts}" -storepass "changeit" -alias "checkmarx_trustedcert_${certalias}" -noprompt
                }
                $log.Warn("Could not import cert into cacerts")
            }
        }
    }
}


###############################################################################
# SSL Configuration
###############################################################################
$log.Info("Configuring SSL")
$hostname = get-ec2instancemetadata -Category LocalHostname
$ssl_file = ""
if (!([String]::IsNullOrEmpty($config.Ssl.Url))) {
    try {
        $ssl_file = [Utility]::Fetch($config.Ssl.Url)
        if ([Utility]::Basename($ssl_file).EndsWith(".ps1")) {
            $log.Info("SSL URL identified as a powershell script. Executing $ssl_file")
            iex "$ssl_file -domainName ""$hostname"" -pfxpassword ""$($config.Ssl.PfxPassword)"""
            $log.Info("... finished executing $ssl_file")
        } elseif ([Utility]::Basename($ssl_File).EndsWith(".pfx")) {
            $log.Info("SSL URL is a .pfx file that has been downloaded")    
        }

        $log.Info("configuring ssl")
        C:\programdata\checkmarx\aws-automation\scripts\ssl\configure-ssl.ps1 -domainName $hostname -pfxpassword "$($config.Ssl.PfxPassword)"
        $log.Info("... finished configuring ssl")
    } catch {
        $log.Error("An exception was thrown while configuring SSL")
        $_ 

    }


    Write-Host "$(Get-Date) restarting services"
    Stop-Service cx* -Force
    if ($isManager) {
        start-service CxSystemManager
    }

    iisreset
    start-service cx*
} 


###############################################################################
# Disable the provisioning task
###############################################################################
$log.Info("disabling provision-checkmarx scheduled task")
Disable-ScheduledTask -TaskName "provision-checkmarx"

$log.Info("disabling checkmarx-ie4uinit-reaper scheduled task")
Disable-ScheduledTask -TaskName "checkmarx-ie4uinit-reaper"

# Create a scheduled task to run on the manager to keep engines in sync and up to date based on tags set by ASGs
if ($isManager) {
    if (!([String]::IsNullOrEmpty($config.AutomationOptions.EngineRegistrationScript))) {   
        $registrationscript = [DependencyFetcher]::new($config.AutomationOptions.EngineRegistrationScript).Fetch()
        Write-Output "$(get-date) Creating scheduled task for engine registration updates"
        $action = New-ScheduledTaskAction -Execute 'C:\Windows\System32\cmd.exe' -Argument "/C powershell.exe -NoProfile -NonInteractive -NoLogo -ExecutionPolicy Unrestricted -File `"${registrationscript}`"" 
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -DontStopOnIdleEnd -ExecutionTimeLimit 0
        $restartInterval = new-timespan -minute 3
        $triggers = @($(New-ScheduledTaskTrigger -AtStartup),$(New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval $restartInterval))
        $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest
        Register-ScheduledTask -Action $action -Principal $principal -Trigger $triggers -Settings $settings -TaskName "checkmarx-update-engine-registration" -Description "Looks for EC2 servers that are Checkmarx Engine Servers and updates the engine registration"
        Write-Output "$(get-date) engine registration task has been created"
    }
}

if ($isManager) {
    if (!([String]::IsNullOrEmpty($config.AutomationOptions.AutoUpdateSamlUserNames))) {   
        $updatescript = [DependencyFetcher]::new($config.AutomationOptions.AutoUpdateSamlUserNames).Fetch()
        Write-Output "$(get-date) Creating scheduled task for saml username updates"
        $action = New-ScheduledTaskAction -Execute 'C:\Windows\System32\cmd.exe' -Argument "/C powershell.exe -NoProfile -NonInteractive -NoLogo -ExecutionPolicy Unrestricted -File `"${updatescript}`"" 
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -DontStopOnIdleEnd -ExecutionTimeLimit 0
        $restartInterval = new-timespan -minute 3
        $triggers = @($(New-ScheduledTaskTrigger -AtStartup),$(New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval $restartInterval))
        $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest
        Register-ScheduledTask -Action $action -Principal $principal -Trigger $triggers -Settings $settings -TaskName "checkmarx-update-saml-usernames" -Description "Adds SAML prefix to user names that don't yet have it"
        Write-Output "$(get-date) SAML username update task has been created"
    }
}




#Reconfigure Access Control on Manager
if ($isManager) {
    Write-Host"$(Get-Date) reconfiguring access control"
    Start-Installer -command (Find-Artifact -artifact "CxSetup.exe") -installerArguments "/install /quiet RECONFIGURE_ACCESS_CONTROL=1"
    Write-Host"$(Get-Date) restarting IIS"
    iisreset
    Write-Host"$(Get-Date) waking up the identity authority"
    iwr -uri "https://$($config.Checkmarx.fqdn)/cxrestapi/auth" -UseBasicParsing
}




###############################################################################
# Generate the Engine Configuration File
###############################################################################
if ($isManager) {

    Write-Host "$(Get-Date) Exporting the engineConfiguration.json file"
    $p = Start-Process "dotnet" -ArgumentList ".\EngineConfigurationExporter.dll" -WorkingDirectory "C:\Program Files\Checkmarx\Tools\Engine Configuration Exporter" -Wait -NoNewWindow -PassThru
    Write-Host "$(Get-Date) EngineConfigurationExplorter exit code: $($p.ExitCode)"
    $engineConfigFile = (Get-ChildItem "C:\Program Files\Checkmarx\Tools" -Recurse -Filter "engineConfiguration.json" | Sort -Descending | Select -First 1 -ExpandProperty FullName)
    Write-Host "$(Get-Date) EngineConfigurationExplorter created config file at: $engineConfigFile)"
    Write-Host "$(Get-Date) Writing the $engineConfigFile file to s3://$($env:CheckmarxBucket)/$($env:CheckmarxEnvironment)/engineConfiguration.json"
    write-s3object -bucketname $env:CheckmarxBucket -key "$env:CheckmarxEnvironment/engineConfiguration.json" -file "$engineConfigFile"

    if ($isEngine) {
        Write-Host "$(Get-Date) Reconfiguring the local engine"
        $p = Start-Process (Find-Artifact -Artifact "*CxSetup.exe") -ArgumentList "/install /quiet RECONFIGURE_ENGINE=1 ENGINE_SETTINGS_FILE=""$engineConfigFile""" -Wait -NoNewWindow -PassThru
        Write-Host "$(Get-Date) Reconfigure engine exit code: $($p.ExitCode)"
    }

}






###############################################################################
#  Debug Info
###############################################################################

@"
###############################################################################
# Checking for all installed updates
################################################################################
"@ | Write-Output
Wmic qfe list  | Format-Table


$log.Info("provisioning has completed. Rebooting.")

# Copy the log to installation folder so it can be downloaded by server administrator
try {
    Copy-Item C:\provision-checkmarx.log 'C:\Program Files\Checkmarx\Logs\Installation\provision-checkmarx.log'
} catch {
    $_
}
restart-computer -force 
sleep 900
