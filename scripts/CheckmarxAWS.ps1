
function log([string] $msg) { Write-Host "$(Get-Date -Format G) [$PSCommandPath] $msg" }

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
    Write-Host "Downloading from $($this.sourceUrl)"
    Invoke-WebRequest -UseBasicParsing -Uri $this.sourceUrl -OutFile (Join-Path $this.expectedpath $this.filename)
    Write-Host "Finished downloading $($this.filename)"
  }
}
