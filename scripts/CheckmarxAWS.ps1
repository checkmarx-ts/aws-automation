
function log([string] $msg) { Write-Host "$(Get-Date -Format G) [$PSCommandPath] $msg" }


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


function  TryGetSSMParameter([String] $parameter) {
    if(!$parameter) { return $null }

    try {
        $ssmParam = Get-SSMParameter -Name $parameter -WithDecryption $True
    
        if($ssmParam) {
        log "Using the value found for $parameter"
        return $ssmParam.value
        } else {
        log "Using argument as provided"
        return $parameter
    }
    } catch {
        $_
        log "An error occured while fetching SSM parameter key"
        log "Using argument as provided"
        return $parameter
    }
}

Class InstallerLocator {
  [String] $pattern
  [String] $s3pattern
  [String] $expectedpath
  [String] $s3prefix
  [String] $sourceUrl
  [String] $filename
  [String] $installer
  [bool] $isInstallerAvailable
  
  InstallerLocator([String] $pattern, [String] $expectedpath, [String] $s3prefix, [String] $sourceUrl) {
      $this.pattern = $pattern
      # remove anything after the first wild card for the s3 search pattern
      $this.s3pattern = $pattern.Substring(0, $pattern.IndexOf("*")) 
      # Defend against trailing paths that will cause errors
      $this.expectedpath = $expectedpath.TrimEnd("/\")
      $this.s3prefix = $s3prefix.TrimEnd("/")
      $this.sourceUrl = $sourceUrl.TrimEnd("/")
      $this.filename = $this.sourceUrl.Substring($sourceUrl.LastIndexOf("/") + 1)     
  }

  InstallerLocator([String] $pattern, [String] $expectedpath, [String] $s3prefix) {
    $this.pattern = $pattern
    # remove anything after the first wild card for the s3 search pattern
    $this.s3pattern = $pattern.Substring(0, $pattern.IndexOf("*")) 
    # Defend against trailing paths that will cause errors
    $this.expectedpath = $expectedpath.TrimEnd("/\")
    $this.s3prefix = $s3prefix.TrimEnd("/")
    $this.sourceUrl = ""
}

  [bool] IsValidInstaller() {
    if (![String]::IsNullOrEmpty($this.installer) -and (Test-Path -Path "$($this.installer)" -PathType Leaf)) {
        return $True
    }
    return $False
  }

  Locate() {
    $this.EnsureLocalPathExists()

    # Search for the installer on the filesystem already in case something out of band placed it there
    $this.installer = $this.TryFindLocal()
    if ($this.IsValidInstaller()) {
      $this.isInstallerAvailable = $True
      return
    }

    # If no installer found yet then try download from s3 and find the downloaded file
    $this.TryDownloadFromS3()
    $this.installer = $this.TryFindLocal()
    if ($this.IsValidInstaller()) {
      $this.isInstallerAvailable = $True
      return
    }

    # If no installer found yet then try download from source and find the downloaded file
    $this.TryDownloadFromSource()
    $this.installer = $this.TryFindLocal()
    if ($this.IsValidInstaller()) {
      $this.isInstallerAvailable = $True
      return
    }

    # If we've reached this point then nothing can be installed
    Throw "Could not find an installer"
  }

  EnsureLocalPathExists() {
    md -force "$($this.expectedpath)" | Out-Null
  }

  [string] TryFindLocal() {
    return $(Get-ChildItem $this.expectedpath -Recurse -Filter $this.pattern | Sort -Descending | Select -First 1 -ExpandProperty FullName)
  }

  TryDownloadFromS3() {
     if (!(Test-Path env:CheckmarxBucket)) {
       Write-Host "Skipping s3 search, CheckmarxBucket environment variable has not been set"
       return
     }

     Write-Host "Searching s3://$env:CheckmarxBucket/$($this.s3prefix)/$($this.s3pattern)"
     try {
        $s3object = (Get-S3Object -BucketName $env:CheckmarxBucket -Prefix "$($this.s3prefix)/$($this.s3pattern)" | Select -ExpandProperty Key | Sort -Descending | Select -First 1)
     } catch {
        Write-Host "ERROR: An exception occured calling Get-S3Object cmdlet. Check IAM Policies and if AWS Powershell is installed"
        exit 1
     }
     if ([String]::IsNullOrEmpty($s3object)) {
        Write-Host "No suitable file found in s3"
        return
     }

     Write-Host "Found s3://$env:CheckmarxBucket/$s3object"
     $this.filename = $s3object.Substring($s3object.LastIndexOf("/") + 1)
     try {
        Write-Host "Downloading from s3://$env:CheckmarxBucket/$s3object"
        Read-S3Object -BucketName $env:CheckmarxBucket -Key $s3object -File "$($this.expectedpath)\$($this.filename)"
        Write-Host "Finished downloading $($this.filename)"
     } catch {
        Write-Host "ERROR: An exception occured calling Read-S3Object cmdlet. Check IAM Policies and if AWS Powershell is installed"
        exit 1
     }
  }  

  TryDownloadFromSource() {
    if ([string]::IsNullOrEmpty($this.sourceUrl)) {
        return
    }
    Write-Host "Downloading from $($this.sourceUrl)"
    Invoke-WebRequest -UseBasicParsing -Uri $this.sourceUrl -OutFile (Join-Path $this.expectedpath $this.filename)
    Write-Host "Finished downloading $($this.filename)"
  }
}
