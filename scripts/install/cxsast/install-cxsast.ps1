<#
.SYNOPSIS
Installs / Checkmarx CxSAST 8.9 w/ Hotfix

.NOTES
The installer file is determined in this order:
  IF the installer argument is passed then:
    - the absolute path will be used as the installer
    - neither the local expected path or s3 bucket will be searched
    - no download over the internet will take place
  OTHERWISE the installation file will be searched for in this order
    1. The local expected path i.e. c:\programdata\checkmarx\ will be searched for a file that matches the typical installer filename. This allows you to place an installer here via any means
    2. IF the CheckmarxBucket environment variable is set, the bucket will be searched for a file that matches the typical installer filename with an appropriate key prefix (ie installation/common)
  AS A LAST RESORT
    The latest version will be download from the offical source over the internet 

  * When searching based on file prefix, if more than 1 file is found the files are sorted by file name and the first file is selected. This typically will mean the most recent version available is selected. 

#>

param (
 # Automation args
 [Parameter(Mandatory = $False)] [String] $installer = "CxSAST.890.Release.Setup_8.9.0.210.zip",
 [Parameter(Mandatory = $False)] [String] $hotfix_installer = "8.9.0.HF24.zip",
 [Parameter(Mandatory = $False)] [String] $expectedpath ="C:\programdata\checkmarx\automation\installers",
 [Parameter(Mandatory = $False)] [String] $s3prefix = "installation/cxsast",
 [Parameter(Mandatory = $False)] [switch] $ACCEPT_EULA = $False,
 
 # Install Options
 [Parameter(Mandatory = $False)] [String] $PORT = "80",
 [Parameter(Mandatory = $False)] [String] $INSTALLFOLDER = "installation/cxsast",
 
 # Cx Components
 [Parameter(Mandatory = $False)] [switch] $MANAGER = $False,
 [Parameter(Mandatory = $False)] [switch] $WEB = $False,
 [Parameter(Mandatory = $False)] [switch] $ENGINE = $False, 
 [Parameter(Mandatory = $False)] [switch] $BI = $False,  
 [Parameter(Mandatory = $False)] [switch] $AUDIT = $False,

 # CxDB SQL
 [Parameter(Mandatory = $False)] [switch] $SQLAUTH = $False,
 [Parameter(Mandatory = $False)] [String] $SQLSERVER = "localhost\SQLExpress",
 [Parameter(Mandatory = $False)] [String] $SQLUSER = "",
 [Parameter(Mandatory = $False)] [String] $SQLPWD = "",

 # CxARM
 [Parameter(Mandatory = $False)] [String] $MQHTTPPORT = "61616",
 [Parameter(Mandatory = $False)] [String] $TOMCATUSERNAME = "checkmarx",
 [Parameter(Mandatory = $False)] [String] $TOMCATPASSWORD = "changeme",
 [Parameter(Mandatory = $False)] [String] $TOMCATHTTPPORT = "8080",
 [Parameter(Mandatory = $False)] [String] $TOMCATHTTPSPORT = "8443",
 [Parameter(Mandatory = $False)] [String] $TOMCATSHUTDOWNPORT = "8005 ",
 [Parameter(Mandatory = $False)] [String] $TOMCATAJPPORT = "8009 ",
 
 # CxArm SQL
 [Parameter(Mandatory = $False)] [switch] $CXARM_SQLAUTH = $False,
 [Parameter(Mandatory = $False)] [String] $CXARM_DB_HOST = "localhost\SQLExpress",
 [Parameter(Mandatory = $False)] [String] $CXARM_DB_USER = "",
 [Parameter(Mandatory = $False)] [String] $CXARM_DB_PASSWORD = "" 
)

# Force TLS 1.2+ and hide progress bars to prevent slow downloads
Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; 
$ProgressPreference = "SilentlyContinue"

function log([string] $msg) { Write-Host "$(Get-Date -Format G) [$PSCommandPath] $msg" }

function testNetworkConnection($hostname, $port) { 
  $results = Test-NetConnection -ComputerName $hostname -Port $port
  $sqltest
  if ($sqltest.TcpTestSucceeded -eq $False) {
    log "Could not connect to ${hostname}:${port}. Is the firewall open? Is SQL Server running?"
    exit 1
  } 
}

function testDatabaseConnection($connectionstring) {

    $DBHOST = $connectionstring.Split("\,")[0]
    $PORT = "1433"
    $INSTANCE = ""

    if ($connectionstring.Contains("\") -and $connectionstring.Contains(",")) {
      $INSTANCE = $connectionstring.Split("\,")[1]
      $PORT     = $connectionstring.Split("\,")[2]
    } elseif ($connectionstring.Contains("\")) {
      $INSTANCE = $connectionstring.Split("\,")[1]
    } elseif ($connectionstring.Contains(",")) {
      $PORT     = $connectionstring.Split("\,")[1]
    }

    log "Parsed connection string into these fragments: "
    log "  HOST: $DBHOST"
    log "  INSTANCE: $INSTANCE"
    log "  PORT: $PORT"
        
    log "Testing network connection to ${DBHOST}:${PORT}"
    testNetworkConnection $DBHOST $PORT
}

function GetInstaller ([string] $candidate, [string] $expectedPath, [string] $s3prefix) {
    $pattern = $candidate
    if (![String]::IsNullOrEmpty($candidate) -and (Test-Path $candidate)) {
      log "The specified file $installer will be used for install"
      return $candidate
    } 

    $candidate = $(Get-ChildItem "$expectedpath" -Recurse -Filter "${pattern}" | Sort -Descending | Select -First 1 -ExpandProperty FullName)
    if (![String]::IsNullOrEmpty($candidate) -and (Test-Path $candidate)) {
      log "Found $candidate in expected path"
      return $candidate
    } else {
      log "Found no candidate in $expectedPath"
    }

    if ($env:CheckmarxBucket) {
      log "Searching s3://$env:CheckmarxBucket/$s3prefix/"	    
      $s3object = (Get-S3Object -BucketName $env:CheckmarxBucket -Prefix "$s3prefix/" | Select -ExpandProperty Key | Where { $_ -match $pattern } | Sort -Descending | Select -First 1)
      if (![String]::IsNullOrEmpty($s3object)) {
        log "Found s3://$env:CheckmarxBucket/$s3object"
        $filename = $s3object.Substring($s3object.LastIndexOf("/") + 1)
        Read-S3Object -BucketName $env:CheckmarxBucket -Key $s3object -File "$expectedpath\$filename"
        sleep 5
        $candidate = (Get-ChildItem "$expectedpath" -Recurse -Filter "${pattern}*" | Sort -Descending | Select -First 1 -ExpandProperty FullName).ToString()
        return [String]$candidate[0].FullName
      } else {
        log "Found no candidate in s3://$env:CheckmarxBucket/$s3prefix"
      }
    } else {
      log "No CheckmarxBucket environment variable defined - not searching s3"
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
md -force "$expectedpath" | Out-Null

<##################################
    Argument Validation
###################################>

if (($MANAGER.IsPresent -or $WEB.IsPresent) -and ($SQLAUTH.IsPresent -and ([String]::IsNullOrEmpty($SQLUSER) -or [String]::IsNullOrEmpty($SQLPWD)))) {
  log "MANGER or WEB component is selected with SQLAUTH but SQLUSER, SQLPWD, or both are empty. SQLUSER and SQLPWD must be specified for SQLAUTH."
  exit 1
}

if (($MANAGER.IsPresent -or $WEB.IsPresent) -and ([String]::IsNullOrEmpty($SQLSERVER))) {
  log "MANGER or WEB component is selected but SQLSERVER is empty. SQLSERVER must be specified."
  exit 1
}

if ($BI.IsPresent -and ($CXARM_SQLAUTH.IsPresent -and ([String]::IsNullOrEmpty($CXARM_DB_USER) -or [String]::IsNullOrEmpty($CXARM_DB_PASSWORD)))) {
  log "BI component is selected with CXARM_SQLAUTH but CXARM_DB_USER, CXARM_DB_PASSWORD, or both are empty. CXARM_DB_USER and CXARM_DB_PASSWORD must be specified for CXARM_SQLAUTH."
  exit 1
}

if (($BI.IsPresent) -and ([String]::IsNullOrEmpty($CXARM_DB_HOST))) {
  log "BI component is selected but CXARM_DB_HOST is empty. CXARM_DB_HOST must be specified."
  exit 1
}

<##################################
    Inexpensive connectivity tests to fail fast
###################################>

#if ($MANAGER.IsPresent -or $Web.IsPresent) { testDatabaseConnection $SQLSERVER }
#if ($BI.IsPresent) { testDatabaseConnection $CXARM_DB_HOST }


<##################################
    Search & obtain the installers
###################################>
try {
  log "Searching for the CxSAST Installer"
  $installer = GetInstaller $installer $expectedpath $s3prefix
} catch {
  Write-Error $_.Exception.ToString()
  log $_.Exception.ToString()
  $_
  log "ERROR: An error occured. Check IAM policies? Is AWS Powershell installed?"
  exit 1
}

try {
  log "Searching for the CxSAST Hotfix Installer"
  $hotfix_installer = GetInstaller $hotfix_installer $expectedpath $s3prefix
} catch {
  Write-Error $_.Exception.ToString()
  log $_.Exception.ToString()
  $_
  log "ERROR: An error occured. Check IAM policies? Is AWS Powershell installed?"
  exit 1
}


if (!(Test-Path "$installer")) {
  log "ERROR: No file exists at $installer"
  exit 1
} 
if (!(Test-Path "$hotfix_installer")) {
  log "ERROR: No file exists at $hotfix_installer"
  exit 1
} 

log "Unzipping installers"
Expand-Archive $installer -DestinationPath $expectedpath -Force
Expand-Archive $hotfix_installer -DestinationPath $expectedpath -Force
log "Finished unzipping installers"

# At this point the installer vars are actually pointing to zip files.. Lets find the actual executables now that they're unzipped.
$expectedpath = "C:\programdata\checkmarx\automation\installers"
$installer = $(Get-ChildItem "$expectedpath" -Recurse -Filter "CxSetup.exe" | Sort -Descending | Select -First 1 -ExpandProperty FullName)
$hotfix_installer = $(Get-ChildItem "$expectedpath" -Recurse -Filter "*HF*.exe" | Sort -Descending | Select -First 1 -ExpandProperty FullName)

if ([String]::IsNullOrEmpty($installer) -or !(Test-Path "$installer")) {
  log "ERROR: installer does not exist or is empty: $installer `"$installer`""
  exit 1
} 
if ([String]::IsNullOrEmpty($hotfix_installer) -or !(Test-Path "$hotfix_installer")) {
  log "ERROR: hotfix installer does not exist or is empty: $hotfix_installer `"$hotfix_installer`""
  exit 1
} 


<##################################
    Install Checkmarx
###################################>


# Build up the installer command line options
$MANAGER_BIT = "0"
$WEB_BIT = "0"
$ENGINE_BIT = "0"
$BI_BIT = "0"
$AUDIT_BIT = "0"
$SQLAUTH_BIT = "0"
$CXARM_SQLAUTH_BIT = "0"
if ($SQLAUTH.IsPresent) { $SQLAUTH_BIT = "1" }
if ($CXARM_SQLAUTH.IsPresent) { $CXARM_SQLAUTH_BIT="1" }

$cx_component_options = " MANAGER=${MANAGER_BIT} WEB=${WEB_BIT} ENGINE=${ENGINE_BIT} BI=${BI_BIT} AUDIT=${AUDIT_BIT} "
$cx_options = "/install /quiet ACCEPT_EULA=Y PORT=${PORT} INSTALLFOLDER=${INSTALLFOLDER} "
$cx_db_options = " SQLAUTH=${SQLAUTH_BIT} SQLSERVER=${SQLSERVER} SQLUSER=${SQLUSER} SQLPWD=${SQLPWD} "
$cx_armdb_options = " CXARM_SQLAUTH=${CXARM_SQLAUTH_BIT} CXARM_DB_HOST=${CXARM_DB_HOST} CXARM_DB_USER=${CXARM_DB_USER} CXARM_DB_PASSWORD=${CXARM_DB_PASSWORD} "
$cx_tomcat_mq_options = " MQHTTPPORT=${MQHTTPPORT} TOMCATUSERNAME=${TOMCATUSERNAME} TOMCATPASSWORD=${TOMCATPASSWORD} TOMCATHTTPPORT=${TOMCATHTTPPORT} TOMCATHTTPSPORT=${TOMCATHTTPSPORT} TOMCATSHUTDOWNPORT=${TOMCATSHUTDOWNPORT} TOMCATAJPPORT=${TOMCATAJPPORT} "

# Now do run the installer, keep tracking of component bit state along the way. Multiple runs of the installer are required or else the database hangs (which is why we keep track of the state). 
if ($MANAGER.IsPresent -or $BI.IsPresent) {
  $MANAGER_BIT = $BI_BIT = "1"
  $cx_component_options = " MANAGER=${MANAGER_BIT} WEB=${WEB_BIT} ENGINE=${ENGINE_BIT} BI=${BI_BIT} AUDIT=${AUDIT_BIT} "
  log "Installing MANAGER/BI"
  log "install options: $("${cx_options} ${cx_component_options} ${cx_db_options} ${cx_armdb_options} ${cx_tomcat_mq_options}".Replace("SQLPWD=$SQLPWD", "SQLPWD=***"").Replace("CXARM_DB_PASSWORD=$CXARM_DB_PASSWORD", "CXARM_DB_PASSWORD=***").Replace("TOMCATPASSWORD=$TOMCATPASSWORD", "TOMCATPASSWORD=***"))"
  Start-Process "$installer" -ArgumentList "${cx_options} ${cx_component_options} ${cx_db_options} ${cx_armdb_options} ${cx_tomcat_mq_options}" -Wait -NoNewWindow
}

if ($WEB.IsPresent) {
  $WEB_BIT = "1"
  $cx_component_options = " MANAGER=${MANAGER_BIT} WEB=${WEB_BIT} ENGINE=${ENGINE_BIT} BI=${BI_BIT} AUDIT=${AUDIT_BIT} "
  log "Installing WEB"
  log "install options: $("${cx_options} ${cx_component_options} ${cx_db_options} ${cx_armdb_options} ${cx_tomcat_mq_options}".Replace("SQLPWD=$SQLPWD", "SQLPWD=***"").Replace("CXARM_DB_PASSWORD=$CXARM_DB_PASSWORD", "CXARM_DB_PASSWORD=***").Replace("TOMCATPASSWORD=$TOMCATPASSWORD", "TOMCATPASSWORD=***"))"
  #Start-Process "$installer" -ArgumentList "${cx_options} ${cx_component_options} ${cx_db_options} ${cx_armdb_options} ${cx_tomcat_mq_options}" -Wait -NoNewWindow
}

if ($ENGINE.IsPresent) {
  $ENGINE_BIT = "1"
  $cx_component_options = " MANAGER=${MANAGER_BIT} WEB=${WEB_BIT} ENGINE=${ENGINE_BIT} BI=${BI_BIT} AUDIT=${AUDIT_BIT} "
  log "Installing ENGINE"
  log "install options: $("${cx_options} ${cx_component_options} ${cx_db_options} ${cx_armdb_options} ${cx_tomcat_mq_options}".Replace("SQLPWD=$SQLPWD", "SQLPWD=***"").Replace("CXARM_DB_PASSWORD=$CXARM_DB_PASSWORD", "CXARM_DB_PASSWORD=***").Replace("TOMCATPASSWORD=$TOMCATPASSWORD", "TOMCATPASSWORD=***"))"
  #Start-Process "$installer" -ArgumentList "${cx_options} ${cx_component_options} ${cx_db_options} ${cx_armdb_options} ${cx_tomcat_mq_options}" -Wait -NoNewWindow
}

if ($AUDIT.IsPresent) {
  $AUDIT_BIT = "1"
  $cx_component_options = " MANAGER=${MANAGER_BIT} WEB=${WEB_BIT} ENGINE=${ENGINE_BIT} BI=${BI_BIT} AUDIT=${AUDIT_BIT} "
  log "Installing AUDIT"
  log "install options: $("${cx_options} ${cx_component_options} ${cx_db_options} ${cx_armdb_options} ${cx_tomcat_mq_options}".Replace("SQLPWD=$SQLPWD", "SQLPWD=***"").Replace("CXARM_DB_PASSWORD=$CXARM_DB_PASSWORD", "CXARM_DB_PASSWORD=***").Replace("TOMCATPASSWORD=$TOMCATPASSWORD", "TOMCATPASSWORD=***"))"
  #Start-Process "$installer" -ArgumentList "${cx_options} ${cx_component_options} ${cx_db_options} ${cx_armdb_options} ${cx_tomcat_mq_options}" -Wait -NoNewWindow
}

if ($ENGINE.IsPresent -And (!$MANAGER.IsPresent -and !$WEB.IsPresent)) {
  # When the engine is installed by itself it can't piggy back on the opening of 80,443 by IIS install, so we need to explicitly open the port
  log "Adding host firewall rule for $PORT for the Engine Server"
  New-NetFirewallRule -DisplayName "CxScanEngine HTTPs Port $PORT" -Direction Inbound -LocalPort $PORT -Protocol TCP -Action Allow
}

if ($BI.IsPresent) {
  log "Adding host firewall rule for $TOMCATHTTPPORT for CxARM"
  New-NetFirewallRule -DisplayName "CxArm HTTP Port $TOMCATHTTPPORT" -Direction Inbound -LocalPort $TOMCATHTTPPORT -Protocol TCP -Action Allow
  log "Adding host firewall rule for $TOMCATHTTPSPORT for CxARM"
  New-NetFirewallRule -DisplayName "CxArm HTTPs Port $TOMCATHTTPSPORT" -Direction Inbound -LocalPort $TOMCATHTTPSPORT -Protocol TCP -Action Allow
}



<##################################
    Post Install Configuration
###################################>

# We need to access the database for these settings so we build a client for the access.
Class DbClient {
  hidden [String] $connectionString
  [Int] $sqlTimeout = 60

  DbClient([String] $sqlHost, [String] $database, [bool] $useWindowsAuthentication, [String] $username, [String] $password) {
    if ($useWindowsAuthentication) {
        $this.connectionString = "Server={0}; Database={1}; Trusted_Connection=Yes; Integrated Security=SSPI;" -f $sqlHost, $database
    } else {
        $this.connectionString = "Server={0}; Database={1}; User ID={2}; Password={3}" -f $sqlHost, $database, $username, $password
    }
  }

  [Object] ExecuteSql([String] $sql) {
    [System.Data.SqlClient.SqlConnection] $sqlConnection = [System.Data.SqlClient.SqlConnection]::new($this.connectionString)
    $table = $null

    try {
      $sqlConnection.Open()

      #build query object
      $command = $sqlConnection.CreateCommand()
      $command.CommandText = $sql
      $command.CommandTimeout = $this.sqlTimeout

      #run query
      $adapter = [System.Data.SqlClient.SqlDataAdapter]::new($command)
      $dataset = [System.Data.DataSet]::new()
      $adapter.Fill($dataset) | out-null

      #return the first collection of results or an empty array
      if ($dataset.Tables[0] -ne $null) {$table = $dataset.Tables[0]}
      elseif ($table.Rows.Count -eq 0) { $table = [System.Collections.ArrayList]::new() }

      $sqlConnection.Close()
      return $table

    } catch {
      $this.log.Error("An error occured executing sql: $sql")
      $this.log.Error("Error message: $($_.Exception.Message))")
      $this.log.Error("Error exception: $($_.Exception))")
      throw $_
    } finally {
      $sqlConnection.Close()
    }
  } 
}

[DbClient] $CxDb = [DbClient]::New($SQLSERVER, "CxDb", $SQLAUTH, $SQLUSER, $SQLPWD)
$CxDb.ExecuteSql("DELETE from [dbo].[InstallationMap] WHERE [DNSName] <> '$Hostname'")
$CxDb.ExecuteSql("UPDATE [dbo].[CxComponentConfiguration] SET [Value] = 'http://localhost' WHERE [Key] = 'IdentityAuthority'")
$CxDb.ExecuteSql("UPDATE [dbo].[CxComponentConfiguration] SET [Value] = 'tcp://localhost:$MQHTTPPORT' WHERE [Key] = 'ActiveMessageQueueURL'")
$CxDb.ExecuteSql("UPDATE [dbo].[CxComponentConfiguration] SET [Value] = 'http://localhost:8080' WHERE [Key] = 'CxARMPolicyURL'")
$CxDb.ExecuteSql("UPDATE [dbo].[CxComponentConfiguration] SET [Value] = 'http://localhost:8080' WHERE [Key] = 'CxARMURL'")
$CxDb.ExecuteSql("UPDATE [dbo].[CxComponentConfiguration] SET [Value] = 'http://localhost:8080' WHERE [Key] = 'CxARMWebClientUrl'")

# todo: git path


<##################################
    Install Checkmarx Hotfix
###################################>
log "Stopping services to install hotfix"
#stop-service cx*; 
#if ($WEB.IsPresent) { iisreset /stop } 
#Start-Process "$hotfix_installer" -ArgumentList "-cmd" -Wait -NoNewWindow



###
###
### Todo
# 0 install sql server
# 1. add command line args from cli isntaller to this cript
# run installer 3 times, passing args each time
# run hotfix
# run fixes ( remove doulbe enc in active mq properties if arm installed



log "Installing from $installer"
#
if (Test-Path "${installer}.log") { log "Last 50 lines of installer:"; Get-content -tail 50 "${installer}.log" }
log "Finished installing. Log file is at ${installer}.log."
