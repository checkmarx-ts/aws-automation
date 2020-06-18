<#
.SYNOPSIS
Installs / Checkmarx CxSAST 9.0 w/ Hotfix

.NOTES
The installer file is determined in this order:
  IF the installer argument is passed then:
    - the absolute path will be used as the installer
    - neither the local expected path or s3 bucket will be searched
    - no download over the internet will take place
  OTHERWISE the installation file will be searched for in this order
    1. The local expected path i.e. c:\programdata\checkmarx\ will be searched for a file that matches the typical installer filename. This allows you to place an installer here via any means
    2. IF the CheckmarxBucket environment variable is set, the bucket will be searched for a file that matches the typical installer filename with an appropriate key prefix (ie installation/common)

  * When searching based on file prefix, if more than 1 file is found the files are sorted by file name and the first file is selected. This typically will mean the most recent version available is selected. 
#>
param (
 # Automation args
 # installers should be the filename of the zip file as distributed by Checkmarx but stripped of any password protection
 [Parameter(Mandatory = $False)] [String] $installer = "CxSAST.900.Release.Setup_9.0.0.40085.zip",
 [Parameter(Mandatory = $False)] [String] $hotfix_installer = "0",

 # The default paths are a convention and not normally changed. Take caution if passing in args. 
 [Parameter(Mandatory = $False)] [String] $expectedpath ="C:\programdata\checkmarx\automation\installers",
 [Parameter(Mandatory = $False)] [String] $s3prefix = "installation/cxsast",
 
 # Install Options
 [Parameter(Mandatory = $False)] [switch] $ACCEPT_EULA = $False,
 [Parameter(Mandatory = $False)] [String] $PORT = "80",
 [Parameter(Mandatory = $False)] [String] $INSTALLFOLDER = "C:\Program Files\Checkmarx",
 [Parameter(Mandatory = $False)] [String] $LIC = "",
 [Parameter(Mandatory = $False)] [String] $CX_JAVA_HOME = "C:\Program Files\AdoptOpenJDK\jre",
 [Parameter(Mandatory = $False)] [String] $CxSAST_ADDRESS = "http://localhost:80",

 # Cx Components
 [Parameter(Mandatory = $False)] [switch] $MANAGER = $False,
 [Parameter(Mandatory = $False)] [switch] $WEB = $False,
 [Parameter(Mandatory = $False)] [switch] $ENGINE = $False, 
 [Parameter(Mandatory = $False)] [switch] $BI = $False,  
 [Parameter(Mandatory = $False)] [switch] $AUDIT = $False,
 [Parameter(Mandatory = $False)] [switch] $ACCESSCONTROL = $False,
 [Parameter(Mandatory = $False)] [switch] $ACTIVEMQ = $False,

 # Access Control Options
 [Parameter(Mandatory = $False)] [switch] $VALIDATED_ACCESSCONTROL_MIGRATION = $False, 

 # CxDB SQL
 [Parameter(Mandatory = $False)] [switch] $SQLAUTH = $False,
 [Parameter(Mandatory = $False)] [String] $SQLSERVER = "localhost\SQLExpress",
 [Parameter(Mandatory = $False)] [String] $SQLUSER = "",
 [Parameter(Mandatory = $False)] [String] $SQLPWD = "",

 # Remediation Intelligence Options
 [Parameter(Mandatory = $False)] [String] $RIHTTPPORT = "8082",

 #ActiveMQ
 [Parameter(Mandatory = $False)] [String] $MQHTTPPORT = "61616",
 [Parameter(Mandatory = $False)] [String] $MQMANAGERHTTPPORT = "8161",

 # CxARM
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

<##################################
    Functions & Classes - main execution will begin below
###################################>
function log([string] $msg) { Write-Host "$(Get-Date -Format G) [$PSCommandPath] $msg" }

function testNetworkConnection($hostname, $port) { 
  $results = Test-NetConnection -ComputerName $hostname -Port $port
  $results
  if ($results.TcpTestSucceeded -eq $False) {
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

function VerifyFileExists($path) {
    if ([String]::IsNullOrEmpty($path) -or !(Test-Path "$path")) {
        log "ERROR: file does not exist or is empty: path `"$path`""
        exit 1
    } 
}

function GetInstaller ([string] $candidate, [string] $expectedPath, [string] $s3prefix) {
    try {  
        $pattern = $candidate
        if (![String]::IsNullOrEmpty($candidate) -and (Test-Path $candidate)) {
          log "The specified file $installer will be used for install"
          return $candidate
        } 

        $candidate = $(Get-ChildItem "$expectedpath" -Recurse -Filter "${pattern}" | Sort-Object -Descending | Select-Object -First 1 -ExpandProperty FullName)
        if (![String]::IsNullOrEmpty($candidate) -and (Test-Path $candidate)) {
          log "Found $candidate in expected path"
          return $candidate
        } else {
          log "Found no candidate in $expectedPath"
        }

        if ($env:CheckmarxBucket) {
          log "Searching s3://$env:CheckmarxBucket/$s3prefix/"	    
          $s3object = (Get-S3Object -BucketName $env:CheckmarxBucket -Prefix "$s3prefix/" | Select-Object -ExpandProperty Key | Where-Object { $_ -match $pattern } | Sort-Object -Descending | Select-Object -First 1)
          if (![String]::IsNullOrEmpty($s3object)) {
            log "Found s3://$env:CheckmarxBucket/$s3object"
            $filename = $s3object.Substring($s3object.LastIndexOf("/") + 1)
            Read-S3Object -BucketName $env:CheckmarxBucket -Key $s3object -File "$expectedpath\$filename"
            $candidate = (Get-ChildItem "$expectedpath" -Recurse -Filter "${pattern}*" | Sort-Object -Descending | Select-Object -First 1 -ExpandProperty FullName)
            return [String]$candidate[0].FullName
          } else {
            log "Found no candidate in s3://$env:CheckmarxBucket/$s3prefix"
          }
        } else {
          log "No CheckmarxBucket environment variable defined - not searching s3"
        }
    } catch {
      Write-Error $_.Exception.ToString()
      log $_.Exception.ToString()
      $_
      log "ERROR: An error occured. Check IAM policies? Is AWS Powershell installed?"
      exit 1
    }
}

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
      if ($null -ne $dataset.Tables[0]) {$table = $dataset.Tables[0]}
      elseif ($table.Rows.Count -eq 0) { $table = [System.Collections.ArrayList]::new() }

      $sqlConnection.Close()
      return $table

    } catch {
      log "An error occured executing sql: $sql"
      log "Error message: $($_.Exception.Message))"
      log "Error exception: $($_.Exception))"
      throw $_
    } finally {
      $sqlConnection.Close()
    }
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
mkdir -force "$expectedpath" | Out-Null

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
# Todo: evaluate this check - can it work?
#if ($MANAGER.IsPresent -or $Web.IsPresent) { testDatabaseConnection $SQLSERVER }
#if ($BI.IsPresent) { testDatabaseConnection $CXARM_DB_HOST }


<##################################
    Search & obtain the installers
###################################>
log "Searching for the CxSAST Installer"
$installer = GetInstaller $installer $expectedpath $s3prefix
log "Found installer $installer"
VerifyFileExists $installer

#log "Searching for the CxSAST Hotfix Installer"
#$hotfix_installer = GetInstaller $hotfix_installer $expectedpath $s3prefix
#VerifyFileExists $hotfix_installer


$files = $(Get-ChildItem "$expectedpath" -Recurse -Filter "*zip" | Select-Object -ExpandProperty FullName)
$files | ForEach-Object {
    Expand-Archive -Path $_ -DestinationPath $expectedpath -Force
}

# At this point the installer vars are actually pointing to zip files.. Lets find the actual executables now that they're unzipped.
$installer = $(Get-ChildItem "$expectedpath" -Recurse -Filter "CxSetup.exe" | Sort-Object -Descending | Select-Object -First 1 -ExpandProperty FullName)
#$hotfix_installer = $(Get-ChildItem "$expectedpath" -Recurse -Filter "*HF*.exe" | Sort-Object -Descending | Select-Object -First 1 -ExpandProperty FullName)
VerifyFileExists $installer
#VerifyFileExists $hotfix_installer

<#################################
    Check for a license
##################################>
# By convention, the license-from-alg.ps1 script will leave a license at this location for the install script to find and use.
# A license helps to speed up the install because there is less time waiting for services to start and timeout due to no license
if ([String]::IsNullOrEmpty($LIC)) {
  log "No license specified, searching for one..."
  $LIC = (Get-ChildItem "c:\programdata\checkmarx\automation\installers\license*cxl"  | Sort-Object LastWriteTime | Select-Object -last 1).FullName
  if (![String]::IsNullOrEmpty($LIC) -and (Test-Path $LIC)) { log "Found license: $LIC" }
}

<##################################
    Install Checkmarx
###################################>
# Build up the installer command line options
$MANAGER_BIT = $WEB_BIT = $ENGINE_BIT = $BI_BIT = $AUDIT_BIT = $SQLAUTH_BIT = $CXARM_SQLAUTH_BIT = $ACCESSCONTROL_BIT = $ACTIVEMQ_BIT = $RI_BIT = "0"
if ($SQLAUTH.IsPresent) { $SQLAUTH_BIT = "1" }
if ($CXARM_SQLAUTH.IsPresent) { $CXARM_SQLAUTH_BIT="1" }

$VALIDATED_ACCESSCONTROL_MIGRATION_BIT = "N"
if ($VALIDATED_ACCESSCONTROL_MIGRATION.IsPresent) { $VALIDATED_ACCESSCONTROL_MIGRATION_BIT = "Y" }

$cx_component_options = " MANAGER=${MANAGER_BIT} WEB=${WEB_BIT} ENGINE=${ENGINE_BIT} BI=${BI_BIT} AUDIT=${AUDIT_BIT} ACCESSCONTROL=${ACCESSCONTROL_BIT} RI=${$RI_BIT} "
$cx_options = "/install /quiet ACCEPT_EULA=Y PORT=${PORT} INSTALLFOLDER=`"${INSTALLFOLDER}`" LIC=`"${LIC}`" CX_JAVA_HOME=`"$CX_JAVA_HOME`"" # Note you must quote INSTALLFOLDER and other paths to handle spaces
$cx_db_options = " SQLAUTH=${SQLAUTH_BIT} SQLSERVER=${SQLSERVER} SQLUSER=${SQLUSER} SQLPWD=${SQLPWD} "
$cx_armdb_options = " CXARM_SQLAUTH=${CXARM_SQLAUTH_BIT} CXARM_DB_HOST=${CXARM_DB_HOST} CXARM_DB_USER=${CXARM_DB_USER} CXARM_DB_PASSWORD=${CXARM_DB_PASSWORD} "
$cx_tomcat_mq_options = " MQHTTPPORT=${MQHTTPPORT} TOMCATUSERNAME=${TOMCATUSERNAME} TOMCATPASSWORD=${TOMCATPASSWORD} TOMCATHTTPPORT=${TOMCATHTTPPORT} TOMCATHTTPSPORT=${TOMCATHTTPSPORT} TOMCATSHUTDOWNPORT=${TOMCATSHUTDOWNPORT} TOMCATAJPPORT=${TOMCATAJPPORT} "
$cx_ac_options = " VALIDATED_ACCESSCONTROL_MIGRATION=${VALIDATED_ACCESSCONTROL_MIGRATION_BIT} "
$cx_static_options = "${cx_options} ${cx_db_options} ${cx_armdb_options} ${cx_tomcat_mq_options} ${cx_ac_options}"
# Now do run the installer, keep tracking of component bit state along the way. Multiple runs of the installer are required or else the database hangs (which is why we keep track of the state). 
if ($MANAGER.IsPresent) {
  $MANAGER_BIT = "1" ;
  if ($BI.IsPresent) { $BI_BIT = "1" } # BI Should install w/ manager
  $ACTIVEMQ_BIT = $ACCESSCONTROL_BIT = $RI_BIT = "1"  # Active MQ and access control need to install w/ manager even if they were not selected
  log "Installing MANAGER/BI/AC"
  $cx_component_options = " MANAGER=${MANAGER_BIT} WEB=${WEB_BIT} ENGINE=${ENGINE_BIT} BI=${BI_BIT} AUDIT=${AUDIT_BIT} ACCESSCONTROL=${ACCESSCONTROL_BIT} ACTIVEMQ=${ACTIVEMQ_BIT}  RI=${RI_BIT}  "
  log "install options: $("${cx_component_options} ${cx_static_options}".Replace("SQLPWD=$SQLPWD", "SQLPWD=***"").Replace("CXARM_DB_PASSWORD=$CXARM_DB_PASSWORD", "CXARM_DB_PASSWORD=***").Replace("TOMCATPASSWORD=$TOMCATPASSWORD", "TOMCATPASSWORD=***"))"
  Start-Process "$installer" -ArgumentList "${cx_component_options} ${cx_static_options} " -Wait -NoNewWindow
}

if ($WEB.IsPresent) {
  $WEB_BIT = "1"
  log "Installing WEB"
  $cx_component_options = " MANAGER=${MANAGER_BIT} WEB=${WEB_BIT} ENGINE=${ENGINE_BIT} BI=${BI_BIT} AUDIT=${AUDIT_BIT} ACCESSCONTROL=${ACCESSCONTROL_BIT} ACTIVEMQ=${ACTIVEMQ_BIT}  RI=${RI_BIT}  "
  log "install options: $("${cx_component_options} ${cx_static_options}".Replace("SQLPWD=$SQLPWD", "SQLPWD=***"").Replace("CXARM_DB_PASSWORD=$CXARM_DB_PASSWORD", "CXARM_DB_PASSWORD=***").Replace("TOMCATPASSWORD=$TOMCATPASSWORD", "TOMCATPASSWORD=***"))"
  Start-Process "$installer" -ArgumentList "${cx_component_options} ${cx_static_options} " -Wait -NoNewWindow
}

if ($ENGINE.IsPresent) {
  $ENGINE_BIT = "1"
  log "Installing ENGINE"
  $cx_component_options = " MANAGER=${MANAGER_BIT} WEB=${WEB_BIT} ENGINE=${ENGINE_BIT} BI=${BI_BIT} AUDIT=${AUDIT_BIT} ACCESSCONTROL=${ACCESSCONTROL_BIT} ACTIVEMQ=${ACTIVEMQ_BIT}  RI=${RI_BIT}  "
  log "install options: $("${cx_component_options} ${cx_static_options}".Replace("SQLPWD=$SQLPWD", "SQLPWD=***"").Replace("CXARM_DB_PASSWORD=$CXARM_DB_PASSWORD", "CXARM_DB_PASSWORD=***").Replace("TOMCATPASSWORD=$TOMCATPASSWORD", "TOMCATPASSWORD=***"))"
  Start-Process "$installer" -ArgumentList "${cx_component_options} ${cx_static_options} " -Wait -NoNewWindow
}

if ($AUDIT.IsPresent) {
  $AUDIT_BIT = "1"
  log "Installing AUDIT"
  $cx_component_options = " MANAGER=${MANAGER_BIT} WEB=${WEB_BIT} ENGINE=${ENGINE_BIT} BI=${BI_BIT} AUDIT=${AUDIT_BIT} ACCESSCONTROL=${ACCESSCONTROL_BIT} ACTIVEMQ=${ACTIVEMQ_BIT}  RI=${RI_BIT}  "
  log "install options: $("${cx_component_options} ${cx_static_options}".Replace("SQLPWD=$SQLPWD", "SQLPWD=***"").Replace("CXARM_DB_PASSWORD=$CXARM_DB_PASSWORD", "CXARM_DB_PASSWORD=***").Replace("TOMCATPASSWORD=$TOMCATPASSWORD", "TOMCATPASSWORD=***"))"
  Start-Process "$installer" -ArgumentList "${cx_component_options} ${cx_static_options} " -Wait -NoNewWindow
}


<##################################
    Post Install Configuration
###################################>
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
  # Todo: replace w/ IIS Reverse Proxy to CxARM
}

<#
[DbClient] $CxDb = [DbClient]::New($SQLSERVER, "CxDb", ($SQLAUTH -eq $False), $SQLUSER, $SQLPWD)
$CxDb.ExecuteSql("DELETE from [dbo].[InstallationMap] WHERE [DNSName] <> '$Hostname'")
$CxDb.ExecuteSql("UPDATE [dbo].[CxComponentConfiguration] SET [Value] = 'http://localhost' WHERE [Key] = 'IdentityAuthority'")
$CxDb.ExecuteSql("UPDATE [dbo].[CxComponentConfiguration] SET [Value] = 'tcp://localhost:$MQHTTPPORT' WHERE [Key] = 'ActiveMessageQueueURL'")
$CxDb.ExecuteSql("UPDATE [dbo].[CxComponentConfiguration] SET [Value] = 'http://localhost:8080' WHERE [Key] = 'CxARMPolicyURL'")
$CxDb.ExecuteSql("UPDATE [dbo].[CxComponentConfiguration] SET [Value] = 'http://localhost:8080' WHERE [Key] = 'CxARMURL'")
$CxDb.ExecuteSql("UPDATE [dbo].[CxComponentConfiguration] SET [Value] = 'http://localhost:8080' WHERE [Key] = 'CxARMWebClientUrl'")
$CxDb.ExecuteSql("update [dbo].[CxComponentConfiguration] set [value] = 'C:\Program Files\Git\bin\git.exe' where [key] = 'GIT_EXE_PATH'")

# Extra goodies
$CxDb.ExecuteSql("update [CxDB].[dbo].[CxComponentConfiguration] set [Value] = 'True' where [key] = 'DetailedAuditing'")
# Default as of 8.9, but ensure it is enabled anyway
$CxDb.ExecuteSql("update [CxDB].[dbo].[CxComponentConfiguration] set [value] = '1' where [key] = 'EnableUnzipLocalDrive'")

# Incremental scan settings
#$CxDb.ExecuteSql("update [CxDB].[dbo].[CxComponentConfiguration] set [value] = '7' where [key] = 'INCREMENTAL_SCAN_THRESHOLD'")
#$CxDb.ExecuteSql("update [CxDB].[dbo].[CxComponentConfiguration] set [value] = 'FULL' where [key] = 'INCREMENTAL_SCAN_THRESHOLD_ACTION'")

# Storage settings
#$CxDb.ExecuteSql("update [CxDB].[dbo].[CxComponentConfiguration] set [value] = 'C:\ExtSrc' where [key] = 'EX_SOURCE_PATH'")
#$CxDb.ExecuteSql("update [CxDB].[dbo].[CxComponentConfiguration] set [value] = 'C:\CxSRC' where [key] = 'SOURCE_PATH'")
#$CxDb.ExecuteSql("update [CxDB].[dbo].[CxComponentConfiguration] set [value] = 'C:\CxReports' where [key] = 'REPORTS_PATH'")

# Dynamic Engines requires NumberOfPromotableScans to be set to 0. Default: 3
#$CxDb.ExecuteSql("update [CxDB].[dbo].[CxComponentConfiguration] set [value] = '3' where [key] = 'NumberOfPromotableScans'")

# Long path support
#$CxDb.ExecuteSql("update [CxDB].[dbo].[CxComponentConfiguration] set [value] = 'False' where [key] = 'IsLongPathEnabled'")

# Defines if results attributes will be per team or per project (true = per team, false = per project)
#$CxDb.ExecuteSql("update [CxDB].[dbo].[CxComponentConfiguration] set [value] = 'true' where [key] = 'RESULT_ATTRIBUTES_PER_SIMILARITY'")

# Defines the service provider (checkmarx) id - the issuer of SAML request
#$CxDb.ExecuteSql("update [CxDB].[dbo].[CxComponentConfiguration] set [value] = '' where [key] = 'SamlServiceProviderIssuer'")

# URL the identity authority aka rest api. Must be resolvable/reachable/trusted by manager and end users
#$CxDb.ExecuteSql("update [CxDB].[dbo].[CxComponentConfiguration] set [value] = 'http://localhost' where [key] = 'IdentityAuthority'")

# Defines the web server url used in reports for deep links
#$CxDb.ExecuteSql("update [CxDB].[dbo].[CxComponentConfiguration] set [value] = '' where [key] = 'WebServer'")
#>

<##################################
    Install Checkmarx Hotfix
###################################>
log "Stopping services to install hotfix"
stop-service cx*; 
if ($WEB.IsPresent) { iisreset /stop } 
log "Installing $hotfix_installer"
#Start-Process "$hotfix_installer" -ArgumentList "-cmd" -Wait -NoNewWindow
log "Finished hotfix installation"

log "Restarting services"
Restart-Service cx*
iisreset


# Todo: run fixes ( remove doulbe enc in active mq properties if arm installed
# Todo: run initial ETL if BI.IsPresent AND not run before?

if ($BI.IsPresent) {
  # The db.properties file can have a bug where extra spaces are not trimmed off of the DB_HOST line
  # which can cause connection string concatenation to fail due to a space between the host and :port
  # For example:
  #     TARGET_CONNECTION_STRING=jdbc:sqlserver://sqlserverdev.ckbq3owrgyjd.us-east-1.rds.amazonaws.com :1433;DatabaseName=CxARM[class java.lang.String]
  #
  # As a work around we trim the end off of each line in db.properties
  log "Fixing db.properties"
  (Get-Content "C:\Program Files\Checkmarx\Checkmarx Risk Management\Config\db.properties") | ForEach-Object {$_.TrimEnd()} | Set-Content "C:\Program Files\Checkmarx\Checkmarx Risk Management\Config\db.properties"

  log "Running the initial ETL sync for CxArm"
  Start-Process "C:\Program Files\Checkmarx\Checkmarx Risk Management\ETL\etl_executor.exe" -ArgumentList "-q -console -VSOURCE_PASS_SILENT=${db_password} -VTARGET_PASS_SILENT=${db_password} -VSILENT_FLOW=true -Dinstall4j.logToStderr=true -Dinstall4j.debug=true -Dinstall4j.detailStdout=true" -WorkingDirectory "C:\Program Files\Checkmarx\Checkmarx Risk Management\ETL" -NoNewWindow -Wait 
  log "Finished initial ETL sync"
}

log "Finished installing"
