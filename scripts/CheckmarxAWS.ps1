
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


Class CheckmarxSystemInfo {
  [String] $SystemManagerConfigFile
  [String] $JobsManagerConfigFile
  [String] $ScansManagerConfigFile
  [String] $WebConfigFile
  [String] $WebServicesConfigFile
  [String] $RestAPIConfigFile
  [String] $EngineConfigFile

  [bool] $IsEngine
  [bool] $IsWebPortal
  [bool] $IsSystemManager 
  [bool] $IsJobsManager 
  [bool] $IsScansManager

  CheckmarxSystemInfo() {
    $this.SystemManagerConfigFile = ("{0}\bin\{1}" -f (Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Checkmarx\Installation\Checkmarx System Manager' -Name "Path" -ErrorAction SilentlyContinue), 'CxSystemManagerService.exe.config')
    $this.JobsManagerConfigFile = ("{0}\bin\{1}" -f (Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Checkmarx\Installation\Checkmarx Jobs Manager' -Name "Path" -ErrorAction SilentlyContinue), 'CxJobsManagerWinService.exe.config')
    $this.ScansManagerConfigFile = ("{0}\bin\{1}" -f (Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Checkmarx\Installation\Checkmarx Scans Manager' -Name "Path" -ErrorAction SilentlyContinue), 'CxScansManagerWinService.exe.config')
    $this.WebConfigFile = ("{0}\web\{1}" -f (Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Checkmarx\Installation\CheckmarxWebPortal' -Name "Path" -ErrorAction SilentlyContinue), 'web.config')
    $this.WebServicesConfigFile = ("{0}\CxWebInterface\{1}" -f (Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Checkmarx\Installation\Checkmarx Web Services' -Name "Path" -ErrorAction SilentlyContinue), 'web.config')
    $this.RestAPIConfigFile = ("{0}\CxRestAPI\{1}" -f (Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Checkmarx\Installation\Checkmarx Web Services' -Name "PathRestAPI" -ErrorAction SilentlyContinue), 'web.config')
    $this.EngineConfigFile = ("{0}\{1}" -f ( Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Checkmarx\Installation\Checkmarx Engine Server' -Name 'Path' -ErrorAction SilentlyContinue), 'CxSourceAnalyzerEngine.WinService.exe.config')
  
    $this.IsEngine = ( !([String]::IsNullOrEmpty($this.EngineConfigFile)) -and (Test-Path -Path $this.EngineConfigFile))
    $this.IsWebPortal = ( !([String]::IsNullOrEmpty($this.WebConfigFile)) -and (Test-Path -Path $this.WebConfigFile))
    $this.IsSystemManager = ( !([String]::IsNullOrEmpty($this.isSystemManager)) -and (Test-Path -Path $this.isSystemManager))
    $this.IsJobsManager = ( !([String]::IsNullOrEmpty($this.isJobsManager)) -and (Test-Path -Path $this.isJobsManager))
    $this.IsScansManager = ( !([String]::IsNullOrEmpty($this.isScansManager)) -and (Test-Path -Path $this.isScansManager))
  }
}


Class DateTimeUtil {
  # Gets timestamp in UTC
  [DateTime] NowUTC() {
      return (Get-Date).ToUniversalTime()
  }
  static [String] GetFileNameTime() {
    $timestamp = Get-Date -Format o | foreach { $_ -replace ":", "" }
    $timestamp = $timestamp.Replace("-", "")
    return $timestamp
  }
}

Class Logger {
  hidden [String] $componentName
  hidden [DateTimeUtil] $dateUtil = [DateTimeUtil]::new()
  hidden [string] $outfile = "C:\CheckmarxSetup.log"

  Logger([String] $componentName) {
    $this.componentName = $componentName
    if (!(test-path $this.outfile)) {New-Item -ItemType "file" -Path $this.outfile}
  }

  Info([String] $message) {
    $this.Log("INFO", $message)
  }

  Warn([String] $message) {
    $this.Log("WARN", $message)
  }

  Error ([String] $message) {
    $this.Log("ERROR", $message)
  }

  hidden Log([String] $level, [String] $message) {
    [String] $enhancedMessage = $this.FormatLogMessage($level, $message)

    [String] $color = "White"
    if ($level -eq "WARN"){
      $color = "Yellow"
    } elseif ($level -eq "ERROR") {
      $color = "Red"
    }

    $this.Console($enhancedMessage, $color)
  }

  hidden [String] FormatLogMessage ([String] $level, [String] $message) {
    return $this.dateUtil.NowUTC().ToString("yyyy-MM-ddTHH:mm:ss.fff") + " " + $level.PadLeft(5, " ") + " [" + $this.componentName + "] : " + $message
  }

  hidden Console ([String] $message, $color) {
    Write-Host $message -ForegroundColor $color
    # Add-Content -Path $this.outfile -Value $message
    $message | Out-File $this.outfile -Append -Width 1000
  }
}

Class Base {
  [Logger] $log = [Logger]::new($this.GetType().Fullname)
}

Class CxSASTEngineTlsConfigurer : Base {
  hidden [String] $tlsPort
  hidden [String] $thumbprint

  CxSASTEngineTlsConfigurer([String] $thumbprint) {
    $this.tlsPort = "443"
  }
  Configure() {
     [CheckmarxSystemInfo] $cx = [CheckmarxSystemInfo]::new()
     if ($cx.isEngine -eq $False) {
       $this.log.Info("The engine was not found (no engine path), no configuration will take place")
       return
     }

     if ([String]::IsNullOrWhiteSpace($cx.EngineConfigFile) -Or -Not [System.IO.File]::Exists($cx.EngineConfigFile)){
       $this.log.Info("The engine config file was not found (no engine config file), no configuration will take place")
       return
     }

    $this.ConfigureNetsh()
    $this.ConfigureServiceConfigFile()
    Restart-Service -Name CxScanEngine
  }

  hidden [String] GetIp() {
    return (Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -ne $null -and $_.NetAdapter.Status -ne "Disconnected"}).IPv4Address.Ipaddress
  }

  hidden runCmd($cmd, $arguments, $label) {
    $this.log.Info("running command: $cmd $arguments")
    Start-Process "$cmd" -ArgumentList "$arguments" -Wait -NoNewWindow -RedirectStandardError "c:\${label}.err" -RedirectStandardOutput "c:\${label}.out"
    $this.log.Info("finished running command: $cmd $arguments")
    $this.log.Info("Standard output:")
    cat "c:\${label}.out"
    $this.log.Info("Standard error:")
    "c:\${label}.err"
  }

  hidden ConfigureNetsh() {
    # Delete any cert, then register our own
    $appid = "{00112233-4455-6677-8899-AABBCCDDEEFF}"
    $ipport = "0.0.0.0:$($this.tlsPort)"
    $this.runCmd("netsh.exe", ("http delete sslcert ipport={0}" -f $ipport), "netsh-delete")
    $this.runCmd("netsh.exe", ("http add sslcert ipport={0} certhash={1} appid={2}" -f $ipport, $($this.thumbprint) , $appid), "netsh-add-sslcert")
    $this.runCmd("netsh.exe", "http add urlacl url=https://+:$($this.tlsPort)/CxSourceAnalyzerEngineWCF/CxEngineWebServices.svc user=`"NT AUTHORITY\NETWORK SERVICE`"", "netsh-add-urlacl")
  }

  hidden ConfigureServiceConfigFile() {
    [CheckmarxSystemInfo] $cx = [CheckmarxSystemInfo]::new()
    [Xml]$xml = Get-Content $cx.EngineConfigFile

    $this.log.Info("Adding security mode = Transport")
    $bindingNode = Select-Xml -xml $xml -XPath "/configuration/*/bindings/basicHttpBinding/binding"
    $securityNode = $bindingNode.Node.SelectSingleNode('security')
    if (!$securityNode){
      $securityNode = $xml.CreateElement('security')
      $bindingNode.Node.AppendChild($securityNode)  | Out-Null
    }
    $securityNode.SetAttribute("mode", "Transport")

    $this.log.Info("Setting mexHttpsBinding")
    $mexNode = $xml.SelectSingleNode("/configuration/*/services/service/endpoint[@address='mex']")
    if (!$mexNode){
      $this.log.Error("ERROR: \<endpoint address=""mex"" not found in $($cx.EngineConfigFile) - aborting configuration")
      return
    }
    $mexNode.SetAttribute("binding", "mexHttpsBinding")
    $this.log.Info("Configuring baseAddress")
    $hostNode = $xml.SelectSingleNode("/configuration/*/services/service/host/baseAddresses/add")
    if (!$hostNode){
      $this.log.Error('ERROR: \<baseAddresses\>\<add\>... not found! - aborting configuration')
      return
    }

    [string]$hostAddress = $hostNode.SelectSingleNode("@baseAddress").Value
    $hostAddress = $hostAddress.Replace("http:", "https:").Replace(":80", ":" + $($this.tlsPort)).Replace("localhost", $($this.GetIp()))
    $hostNode.SetAttribute("baseAddress", $hostAddress)

    $serviceNode = $xml.SelectSingleNode("/configuration/*/behaviors/serviceBehaviors/behavior/serviceMetadata")
    if (!$serviceNode){
      $this.log.Error('ERROR: \<serviceMetadata\> not found! - aborting configuration')
      return
    }
    $serviceNode.SetAttribute("httpsGetEnabled", "true")
    $serviceNode.RemoveAttribute("httpGetEnabled")

    $this.log.Info("saving $($cx.EngineConfigFile)")
    $xml.Save($cx.EngineConfigFile)
  }
}

Class CxManagerIisTlsConfigurer : Base {
  hidden [String] $IISWebSite
  hidden [String] $tlsPort
  hidden [String] $thumbprint

  CxManagerIISTlsConfigurer([String] $IISWebSite, [String] $tlsPort, [String] $thumbprint) {
    $this.IISWebSite = $IISWebSite
    $this.tlsPort = $tlsPort
    $this.thumbprint = $thumbprint
  }

  Configure() {
    [CheckmarxSystemInfo] $cx = [CheckmarxSystemInfo]::new()
    if ($cx.isWebPortal -eq $False -and $cx.isSystemManager -eq $False) {
      $this.log.Warn("The WEB or MANAGER component is not installed. Skipping IIS configuration")
      return
    }
    $this.log.Info("Configuring IIS Bindings")
    $this.log.info("Site: $($this.IISWebSite)")
    $this.log.info("Port: $($this.tlsPort)")
    $bindings = Get-WebBinding -Name $this.IISWebSite -Port $this.tlsPort
    $this.log.info("Current binding: $bindings")
    if ($bindings) {
      $this.UpdateWebBinding()
    } else {
      $this.CreateWebBinding()
    }

    $this.log.Info("Restarting website...")
    try {
      Stop-Website -Name $($this.IISWebSite)
    } catch {
      $this.log.Error("Error stopping $($this.IISWebSite)")
      $this.log.Error("Error message: $($_.Exception.Message)")
      $this.log.Error("Error information: $($_)")
    }

    try {
      Start-Website -Name $($this.IISWebSite)
    } catch {
      $this.log.Error("Error starting $($this.IISWebSite)")
      $this.log.Error("Error message: $($_.Exception.Message)")
      $this.log.Error("Error information: $($_)")
    }
  }

  hidden UpdateWebBinding() {
    $this.log.Info("Updating existing IIS Binding (delete, and add new)")
    # Deleting and Binding new certificate
    try {
        $CxDeleteCertOut = $(cmd.exe /c "netsh.exe http delete sslcert ipport=0.0.0.0:$($this.tlsPort) 2>&1")
        $this.log.info("Cmd output: $CxDeleteCertOut")
        $CertBinding = Get-Item cert:\LocalMachine\My\$($this.thumbprint) | New-Item 0.0.0.0!$($this.tlsPort)
    } catch {
      $this.log.Error("An error occured while updating https binding in IIS")
      $this.log.error("Error message: $($_.Exception.Message))")
      $this.log.Error("Error exception: $($_.Exception))")
      Throw $_
    }
  }

  hidden CreateWebBinding() {
    $this.log.Info("Creating new IIS Web Binding for website $($this.IISWebSite) on port $($this.tlsPort) with certificate $($this.thumbprint)")
    try {
      $this.log.info("Creating new binding")
      New-WebBinding -Name $($this.IISWebSite) -IP '*' -Port $($this.tlsPort) -Protocol "https"
    } catch {
      $this.log.Error("An error occured while creating https binding in IIS")
      $this.log.error("Error message: $($_.Exception.Message))")
      $this.log.Error("Error exception: $($_.Exception))")
      Throw $_
    }
    try {
      $this.log.info("Adding SSL Certificate to binding")
      (Get-WebBinding -Name $($this.IISWebSite) -Port $($this.tlsPort) -Protocol "https").AddSslCertificate($($this.thumbprint), "MY")
    } catch {
      $this.log.Error("An error occured while Adding SSL Certificate to binding")
      $this.log.Error("Error message: $($_.Exception.Message))")
      $this.log.Error("Error exception: $($_.Exception))")
      Throw $_
    }
  }
}


Class CxManagerTlsConfigurer : Base {
  [String] $tlsPort
  [bool] $ignoreTlsCertificateValidationErrors
  [String] $domainName

  CxManagerTlsConfigurer([String] $tlsPort, [bool] $ignoreTlsCertificateValidationErrors, [String] $domainName) {
    $this.tlsPort = $tlsPort
    $this.ignoreTlsCertificateValidationErrors = $ignoreTlsCertificateValidationErrors
    $this.domainname = $domainName
  }

  Configure() {
    [CheckmarxSystemInfo] $cx = [CheckmarxSystemInfo]::new()

    $this.ConfigureTransportSecurity($cx.SystemManagerConfigFile)
    $this.ConfigureTransportSecurity($cx.JobsManagerConfigFile)
    $this.ConfigureTransportSecurity($cx.ScansManagerConfigFile)
    $this.ConfigureWebConfig($cx.WebConfigFile)

    if ($this.ignoreTlsCertificateValidationErrors) {
      $this.ConfigureIgnoreCertErr($cx.SystemManagerConfigFile)
      $this.ConfigureIgnoreCertErr($cx.JobsManagerConfigFile)
      $this.ConfigureIgnoreCertErr($cx.ScansManagerConfigFile)
      $this.ConfigureIgnoreCertErr($cx.WebConfigFile)
      $this.ConfigureIgnoreCertErr($cx.WebServicesConfigFile)
      $this.ConfigureIgnoreCertErr($cx.RestAPIConfigFile)
    }
  }

  hidden ConfigureWebConfig([string] $configfile){
    if (-Not [System.IO.File]::Exists($configfile)) {
      $this.log.Info("ConfigureWebConfig: $configfile does not exist - assuming it is not installed")
      return
    }
    $this.log.Info("ConfigureWebConfig: Configuring Web Portal resolver on $configfile")    
    #Update appSettings WebResolver
    [Xml]$xml = Get-Content $configfile
    $obj = $xml.configuration.appSettings.add | where {$_.Key -eq "CxWSResolver.CxWSResolver" }
    $hostAddress = $obj.value
    $hostAddress = $hostAddress.Replace("http:", "https:").Replace(":80", ":" + $($this.tlsPort)).Replace("localhost", $($this.domainName))
    $obj.value = $hostAddress
    $xml.Save($configfile)
}

  hidden ConfigureTransportSecurity([String] $configfile) {
    if (-Not [System.IO.File]::Exists($configfile)) {
      $this.log.Info("ConfigureTransportSecurity: $configfile does not exist - assuming it is not installed")
      return
    }
    $this.log.Info("Configuring transport security on $configfile")

    [Xml]$xml = Get-Content $configfile
    $securityNode = Select-Xml -xml $xml -XPath "/configuration/*/bindings/basicHttpBinding/binding/security"
    if (!$securityNode){
      $this.log.Error("ERROR: <transport> not found, cannot configure transport security")
      return
    }
    $securityNode.Node.SetAttribute("mode", "Transport")
    $xml.Save($configfile)
  }

  hidden ConfigureIgnoreCertErr([String] $configfile) {
    if (-Not [System.IO.File]::Exists($configfile)) {
      $this.log.Info("ConfigureIgnoreCertErr: $configfile does not exist - assuming it is not installed")
      return
    }
    $this.log.Info("Configuring ignore cert validation errors on $configfile")

    # Todo, add a check for if system.net w/ settings/spm already exists and update if it does. Suspect this adds multiple system.net blocks if run more than once which is invalid.
    [xml]$xml = Get-Content $configfile
    $system = $xml.CreateElement("system.net")
    $settings = $xml.CreateElement("settings")
    $spm = $xml.CreateElement("servicePointManager")
    $spm.SetAttribute("checkCertificateName","false")
    $spm.SetAttribute("checkCertificateRevocationList","false")
    $settings.AppendChild($spm)
    $system.AppendChild($settings)
    $xml.configuration.AppendChild($system)
    $xml.Save($configfile)
  }
}

class Utility {
  [bool] static Exists([String] $fpath) {
      return ((![String]::IsNullOrEmpty($fpath)) -and (Test-Path -Path "${fpath}"))
  }
  [String] static Addpath([String] $fpath){
      [Environment]::SetEnvironmentVariable('Path',[Environment]::GetEnvironmentVariable('Path', [EnvironmentVariableTarget]::Machine) + ";$fpath",[EnvironmentVariableTarget]::Machine)
      return [Environment]::GetEnvironmentVariable("Path", [EnvironmentVariableTarget]::Machine)
  }
  [String] static Basename([String] $fullname) {
      return $fullname.Substring($fullname.Replace("\","/").LastIndexOf("/") + 1)
  }
  [String] static Find([String] $filename) {
      return $(Get-ChildItem C:\programdata\checkmarx -Recurse -Filter $filename | Sort -Descending | Select -First 1 -ExpandProperty FullName)
  }
  [String] static Find([String] $fpath, [String] $filename) {
      return $(Get-ChildItem "$fpath" -Recurse -Filter $filename | Sort -Descending | Select -First 1 -ExpandProperty FullName)
  }
  [Void] static Debug([String] $stage) {
      sleep 2
      $msiexecs = Get-Process msiexe*
      $cxprocs = Get-Process cx*
      if ($msiexecs.count -gt 0 -or $cxprocs.count -gt 0) {
          Write-Host "#########################################"
          Write-Host "# Debugging ${stage} - found running processes"
          Write-Host "#########################################"
      }
      if ($msiexecs.count -gt 0){ 
          Write-Host "$(Get-Date) Found these running msiexec.exe process:"
          $msiexecs | Format-Table | Out-File -FilePath C:\cx.debug; cat c:\cx.debug
          $msiexecs | % { Get-WmiObject Win32_Process -Filter "ProcessId = $($_.Id)" }#| Select-Object ProcessId, Name, ExecutablePath, CommandLine | FL }
      }
      if ($cxprocs.count -gt 0) {
          Write-Host "$(Get-Date) Found these running cx* processes:"
          $cxprocs | Format-Table | Out-File -FilePath C:\cx.debug; cat c:\cx.debug
          $cxprocs | % { Get-WmiObject Win32_Process -Filter "ProcessId = $($_.Id)" } #| Select-Object ProcessId, Name, ExecutablePath, CommandLine | FL }
          Write-Host "#########################################"
      }
  }
  [String] static Fetch([String] $source) {
      $filename = [Utility]::Basename($source)
      if ($source.StartsWith("https://")) {
          Write-Host "$(Get-Date) Downloading $source"
          (New-Object System.Net.WebClient).DownloadFile("$source", "c:\programdata\checkmarx\artifacts\${filename}")
      } elseif ($source.StartsWith("s3://")) {        
          $bucket = $source.Replace("s3://", "").Split("/")[0]
          $key = $source.Replace("s3://${bucket}", "")
          Write-Host "$(Get-Date) Downloading $source from bucket $bucket with key $key"
          Read-S3Object -BucketName $bucket -Key $key -File "C:\programdata\checkmarx\artifacts\$filename"
      }
      $fullname = [Utility]::Find($filename)
      Write-Host "$(Get-Date) ... found $fullname"
      return $fullname
  }
}


Class SevenZipInstaller : Base {
  [String] $url
  SevenZipInstaller([String] $url) {
    $this.url = $url
  }
  Install() {
    $7zip_path = $(Get-ChildItem 'HKLM:\SOFTWARE\7*Zip\' | Get-ItemPropertyValue -Name Path)
    if ([Utility]::Exists($7zip_path)) {
      $this.log.Info("7-Zip is already installed at ${7zip_path} - skipping installation")
    } else {
      $sevenzipinstaller = [Utility]::Fetch($this.url)
      $this.log.Info("Installing 7zip from $sevenzipinstaller")
      Start-Process -FilePath "$sevenzipinstaller" -ArgumentList "/S" -Wait -NoNewWindow
      $newpath = [Utility]::Addpath($(Get-ChildItem 'HKLM:\SOFTWARE\7*Zip\' | Get-ItemPropertyValue -Name Path))
      [Utility]::Debug("post-7zip")
    }
  }
}

Class Cpp2010RedistInstaller : Base {
  [String] $url
  Cpp2010RedistInstaller($url) {
    $this.url = $url
  }
  Install() {
    $version = $(Get-ChildItem 'HKLM:\SOFTWARE\Wow6432Node\Microsoft\VisualStudio\10*0\VC\VCRedist\x64' -ErrorAction SilentlyContinue | Get-ItemPropertyValue -Name Installed -ErrorAction SilentlyContinue)
    if (![String]::IsNullOrEmpty($version)) {
      $this.log.Info("C++ 2010 Redistributable is already installed - skipping installation")
    } else {
        [Utility]::Debug("pre-cpp2010")
        $installer = [Utility]::Fetch($this.url)
        $this.log.Info("Installing C++ 2010 Redistributable from $installer")
        Start-Process -FilePath "$installer" -ArgumentList "/passive /norestart" -Wait -NoNewWindow
        [Utility]::Debug("post-cpp2010")
    }
  }
}

Class Cpp2015RedistInstaller : Base {
  [String] $url
  Cpp2015RedistInstaller($url) {
    $this.url = $url
  }
  Install() {
    $version = $(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14*0\VC\Runtimes\x64' -ErrorAction SilentlyContinue | Get-ItemPropertyValue -Name Installed -ErrorAction SilentlyContinue)
    if (![String]::IsNullOrEmpty($version)) {
      $this.log.Info("C++ 2015 Redistributable is already installed - skipping installation")
    } else {
        [Utility]::Debug("pre-cpp2015")
        $installer = [Utility]::Fetch($this.url)
        $this.log.Info("Installing C++ 2015 Redistributable from $installer")
        Start-Process -FilePath "$installer" -ArgumentList "/passive /norestart" -Wait -NoNewWindow
        [Utility]::Debug("post-cpp2015")
    }
  }
}

Class AdoptOpenJdkInstaller : Base {
  [String] $url
  AdoptOpenJdkInstaller($url) {
    $this.url = $url
  }
  Install() {    
    if ([Utility]::Exists("C:\Program Files\AdoptOpenJDK\bin\java.exe")) {
      $this.log.Info("Java is already installed - skipping installation")
    } else {
      $javainstaller = [Utility]::Fetch($this.url)
      [Utility]::Debug("pre-java")
      $this.log.Info("Installing Java from $javainstaller")
      Start-Process -FilePath "C:\Windows\System32\msiexec.exe" -ArgumentList "/i `"$javainstaller`" ADDLOCAL=FeatureMain,FeatureEnvironment,FeatureJarFileRunWith,FeatureJavaHome INSTALLDIR=`"c:\Program Files\AdoptOpenJDK\`" /quiet /L*V `"$javainstaller.log`"" -Wait -NoNewWindow
      $this.log.Info("Finished installing java")
      [Utility]::Debug("post-java")
      Start-Process "C:\Program Files\AdoptOpenJDK\bin\java.exe" -ArgumentList "-version" -RedirectStandardError ".\java-version.log" -Wait -NoNewWindow
      cat ".\java-version.log"
    }
  }
}

Class DotnetFrameworkInstaller : Base {
  [String] $url
  DotnetFrameworkInstaller($url) {
    $this.url = $url
  }
  Install() {  
    # https://docs.microsoft.com/en-us/dotnet/framework/migration-guide/how-to-determine-which-versions-are-installed#to-check-for-a-minimum-required-net-framework-version-by-querying-the-registry-in-powershell-net-framework-45-and-later
    $dotnet_release = $(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full\' | Get-ItemPropertyValue -Name Release)
    $dotnet_version = $(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full\' | Get-ItemPropertyValue -Name Version)
    $this.log.Info("Found .net version ${dotnet_version}; release string: $dotnet_release")
    if ($dotnet_release -gt 461308 ) {
        $this.log.Info("Dotnet 4.7.1 (release string: 461308 ) or higher already installed - skipping installation")
    } else {
        $dotnetinstaller = [Utility]::Fetch($this.url)
        [Utility]::Debug("pre-dotnetframework")
        $this.log.Info("Installing dotnet framework from $dotnetinstaller - a reboot will be required")
        Start-Process -FilePath "$dotnetinstaller" -ArgumentList "/passive /norestart" -Wait -NoNewWindow
        [Utility]::Debug("post-dotnetframework")
        $this.log.Info("Finished dotnet framework install. Rebooting.")  
        Restart-Computer -Force; 
        sleep 30 # force in case anyone is logged in
    }  
  }
}


Class GitInstaller : Base {
  [String] $url
  GitInstaller($url) {
    $this.url = $url
  }
  Install() {  
    if (Test-Path -Path "C:\Program Files\Git\bin\git.exe") {
      $this.log.Info("Git is already installed - skipping installation")
    } else {
      $gitinstaller = [Utility]::Fetch($this.url)
      [Utility]::Debug("pre-git")
      $this.log.Info("Installing Git from $gitinstaller")
      Start-Process -FilePath "$gitinstaller" -ArgumentList "/VERYSILENT /NORESTART /NOCANCEL /SP- /CLOSEAPPLICATIONS" -Wait -NoNewWindow
      $this.log.Info("finished installing Git")
      [Utility]::Debug("post-git")
      Start-Process "C:\Program Files\Git\bin\git.exe" -ArgumentList "--version" -RedirectStandardOutput ".\git-version.log" -Wait -NoNewWindow
      cat ".\git-version.log"
    } 
  }
}

Class IisInstaller : Base {
  IisInstaller() {
  }
  Install() { 
    if ([Utility]::Exists("c:\iis.lock")) {
      $this.log.Info("IIS is already installed - skipping installation")
    } else {
      $this.log.Info("Installing IIS")
      [Utility]::Debug("pre-iis")    
      Install-WindowsFeature -name Web-Server -IncludeManagementTools
      Add-WindowsFeature Web-Http-Redirect  
      Install-WindowsFeature -Name  Web-Health -IncludeAllSubFeature
      Install-WindowsFeature -Name  Web-Performance -IncludeAllSubFeature
      Install-WindowsFeature -Name Web-Security -IncludeAllSubFeature
      Install-WindowsFeature -Name  Web-Scripting-Tools -IncludeAllSubFeature
      [Utility]::Debug("post-iis")    
      $this.log.Info("... finished Installing IIS. Rebooting.")
      # the iis.lock file is used to track state and prevent reinstallation and reboots on subsequent script execution
      "IIS completed" | Set-Content c:\iis.lock
      Restart-Computer -Force
      Sleep 30
    } 
  }
}

Class IisUrlRewriteInstaller : Base {
  [String] $url
  IisUrlRewriteInstaller($url) {
    $this.url = $url
  }
  Install() {  
    if (Test-Path -Path "C:\Windows\System32\inetsrv\rewrite.dll") {
      $this.log.Info("IIS Rewrite Module is already installed - skipping installation")
    } else {
      $rewriteinstaller = [Utility]::Fetch()
      [Utility]::Debug("pre-iis-urlrewrite")  
      $this.log.Info("Installing IIS rewrite Module from $rewriteinstaller")
      Start-Process "C:\Windows\System32\msiexec.exe" -ArgumentList "/i `"$rewriteinstaller`" /L*V `".\rewrite_install.log`" /QN" -Wait -NoNewWindow
      [Utility]::Debug("post-iis-urlrewrite")  
    }
  }
}

Class IisApplicationRequestRoutingInstaller : Base {
  [String] $url
  IisApplicationRequestRoutingInstaller($url) {
    $this.url = $url
  }
  Install() {  
    if (($(C:\Windows\System32\inetsrv\appcmd.exe list modules) | Where  { $_ -match "ApplicationRequestRouting" } | ForEach-Object { echo $_ }).length -gt 1) {
     $this.log.Info("IIS Application Request Routing Module is already installed - skipping installation")
    } else {        
        $requestroutinginstaller = [Utility]::Fetch($this.url)
        [Utility]::Debug("pre-iis-apprequestrouting")  
        $this.log.Info("Installing IIS Application Request Routing Module from $requestroutinginstaller")
        Start-Process "C:\Windows\System32\msiexec.exe" -ArgumentList "/i `"$requestroutinginstaller`" /L*V `".\arr_install.log`" /QN" -Wait -NoNewWindow        
        [Utility]::Debug("post-iis-apprequestrouting")  
        $this.log.Info("... finished Installing IIS Application Request Routing Module")
    }
  }
}

Class DotnetCoreHostingInstaller : Base {
  [String] $url
  DotnetCoreHostingInstaller($url) {
    $this.url = $url
  }
  Install() {  
    if (Test-Path -Path "C:\Program Files\dotnet") {
      $this.log.Info("Microsoft .NET Core 2.1.16 Windows Server Hosting is already installed - skipping installation")
    } else {
      # Only required for 9.0+ so make sure it exists
      $dotnetcore_installer = [Utility]::Fetch($this.url)
      if ([Utility]::Exists($dotnetcore_installer)) {
          $this.log.Info("Installing Microsoft .NET Core 2.1.16 Windows Server Hosting from $dotnetcore_installer")
          [Utility]::Debug("pre-dotnetcore")  
          Start-Process -FilePath "$dotnetcore_installer" -ArgumentList "/quiet /install /norestart" -Wait -NoNewWindow
          [Utility]::Debug("post-dotnetcore")  
      }
    }
  }
}

Class MsSqlServerExpressInstaller : Base {
  [String] $url
  MsSqlServerExpressInstaller($url) {
    $this.url = $url
  }
  Install() {  
    # SQL Server install should come *after* the Checkmarx installation media is unzipped. The SQL Server
    # installer is packaged in the third_party folder from the zip. 
    if ((get-service sql*).length -eq 0) {
      $sqlserverexe = [Utility]::Fetch($this.url)
      $this.log.Info("Installing SQL Server from ${sqlserverexe}")
      [Utility]::Debug("pre-sql-server-express")  
      Start-Process -FilePath "$sqlserverexe" -ArgumentList "/IACCEPTSQLSERVERLICENSETERMS /Q /ACTION=install /INSTANCEID=SQLEXPRESS /INSTANCENAME=SQLEXPRESS /UPDATEENABLED=FALSE /BROWSERSVCSTARTUPTYPE=Automatic /SQLSVCSTARTUPTYPE=Automatic /TCPENABLED=1" -Wait -NoNewWindow
      [Utility]::Debug("post-sql-server-express")  
      $sqlserverlog = $(Get-ChildItem "C:\Program Files\Microsoft SQL Server\110\Setup Bootstrap\Log" -Recurse -Filter "Summary.txt" | Sort -Descending | Select -First 1 -ExpandProperty FullName) 
      $this.log.Info("...finished Installing SQL Server. Log is:")
      cat $sqlserverlog        
    } else {
      $this.log.Info("SQL Server Express is already installed - skipping installation")
    }
  }
}

Class CxSastInstaller : Base {
  [String] $url
  [String] $args
  CxSastInstaller($url, $args) {
    $this.url = $url
    $this.args = $args
  }
  Install() {     
    [Utility]::Debug("pre-cx-uninstall")  
    Start-Process -FilePath "$($this.url)" -ArgumentList "/uninstall /quiet" -Wait -NoNewWindow
    [Utility]::Debug("post-cx-uninstall")  
    # Components should be installed in a certain order or else the install can hang. Order is manager, then web, then engine. 
    # This is accomplished with temp_args and temporarily replacing component choices in order to install in order
    if ($this.args.Contains("MANAGER=1")){
        $temp_args = $this.args
        $temp_args = $temp_args.Replace("WEB=1", "WEB=0").Replace("ENGINE=1", "ENGINE=0").Replace("AUDIT=1", "AUDIT=0")
        $this.log.Info("Installing CxSAST with $temp_args")
        [Utility]::Debug("pre-cx-installer-mgr")  
        Start-Process -FilePath "$($this.url)" -ArgumentList "$temp_args" -Wait -NoNewWindow
        [Utility]::Debug("post-cx-installer-mgr")  
        $this.log.Info("...finished installing")
    }

    if ($this.args.Contains("WEB=1")){
        $temp_args = $this.args
        $temp_args = $temp_args.Replace("ENGINE=1", "ENGINE=0").Replace("AUDIT=1", "AUDIT=0")
        $this.log.Info("Installing CxSAST with $temp_args")
        [Utility]::Debug("pre-cx-installer-web")  
        Start-Process -FilePath "$($this.url)" -ArgumentList "$temp_args" -Wait -NoNewWindow
        [Utility]::Debug("post-cx-installer-web")  
        $this.log.Info("...finished installing")
    }

    $this.log.Info("Installing CxSAST with $($this.args)")
    [Utility]::Debug("pre-cx-installer-all")  
    Start-Process -FilePath "$($this.url)" -ArgumentList "$($this.args)" -Wait -NoNewWindow
    [Utility]::Debug("post-cx-installer-all")  
    $this.log.Info("...finished installing")
  }
}

















