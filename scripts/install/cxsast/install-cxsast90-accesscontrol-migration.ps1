<#
.SYNOPSIS
Installs / Checkmarx CxSAST 9.0 Access Control and Migration

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

 # The default paths are a convention and not normally changed. Take caution if passing in args. 
 [Parameter(Mandatory = $False)] [String] $expectedpath ="C:\programdata\checkmarx\automation\installers",
 [Parameter(Mandatory = $False)] [String] $s3prefix = "installation/cxsast",
 
 # Install Options
 [Parameter(Mandatory = $False)] [switch] $ACCEPT_EULA = $False,
 [Parameter(Mandatory = $False)] [String] $PORT = "443",
 [Parameter(Mandatory = $False)] [String] $INSTALLFOLDER = "C:\Program Files\Checkmarx",
 [Parameter(Mandatory = $False)] [String] $CxSAST_ADDRESS = "https://sekots.dev.checkmarx-ts.com",

 # Cx Components
 [Parameter(Mandatory = $False)] [switch] $ACCESSCONTROL = $False,
 
 # CxDB SQL
 [Parameter(Mandatory = $False)] [switch] $SQLAUTH = $False,
 [Parameter(Mandatory = $False)] [String] $SQLSERVER = "localhost\SQLExpress",
 [Parameter(Mandatory = $False)] [String] $SQLUSER = "",
 [Parameter(Mandatory = $False)] [String] $SQLPWD = ""

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



<##################################
    Search & obtain the installers
###################################>
log "Searching for the CxSAST Installer"
$installer = GetInstaller $installer $expectedpath $s3prefix
log "Found installer $installer"
VerifyFileExists $installer


$files = $(Get-ChildItem "$expectedpath" -Recurse -Filter "*zip" | Select-Object -ExpandProperty FullName)
$files | ForEach-Object {
    Expand-Archive -Path $_ -DestinationPath $expectedpath -Force
}

# At this point the installer vars are actually pointing to zip files.. Lets find the actual executables now that they're unzipped.
$installer = $(Get-ChildItem "$expectedpath" -Recurse -Filter "CxSetup.AC_and_Migration.exe" | Sort-Object -Descending | Select-Object -First 1 -ExpandProperty FullName)
VerifyFileExists $installer


<##################################
    Install AC
###################################>
# Build up the installer command line options
$ACCESSCONTROL_BIT = "0"
if ($ACCESSCONTROL.IsPresent) { $ACCESSCONTROL_BIT = "1" } 
if ($SQLAUTH.IsPresent) { $SQLAUTH_BIT = "1" }

$cx_component_options = " ACCESSCONTROL=${ACCESSCONTROL_BIT} "
$cx_options = "/install /quiet ACCEPT_EULA=Y PORT=${PORT} INSTALLFOLDER=`"${INSTALLFOLDER}`" CXSAST_ADDRESS=`"${CxSAST_ADDRESS}`"" # Note you must quote INSTALLFOLDER and other paths to handle spaces
$cx_db_options = " SQLAUTH=${SQLAUTH_BIT} SQLSERVER=${SQLSERVER} SQLUSER=`"${SQLUSER}`" SQLPWD=`"${SQLPWD}`" "
$cx_static_options = "${cx_options} ${cx_db_options} "
# Now do run the installer, keep tracking of component bit state along the way. Multiple runs of the installer are required or else the database hangs (which is why we keep track of the state). 

log "install options: $("${cx_component_options} ${cx_static_options}".Replace("SQLPWD=$SQLPWD", "SQLPWD=***""))"
Start-Process "$installer" -ArgumentList "${cx_component_options} ${cx_static_options} " -Wait -NoNewWindow

log "Finished installing"
