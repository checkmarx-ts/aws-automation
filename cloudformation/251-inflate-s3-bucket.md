#  The Checkmarx s3 bucket folder structure
Checkmarx automation relies on known paths both on the file system and in the Checkmarx s3 bucket to help keep scripts simple and provide stable locations for support and troubleshooting. It is highly recommended that you do not deviate from this structure. Below are helper commands to help you inflate your s3 bucket with the required dependencies in the right location.

Access to these locations is granted to the Checkmarx IAM roles to allow them to fetch dependencies or write logs, etc. 

## Create the structure

```powershell
$your_bucket = "your bucket name here"

# For storing Checkmarx Installation Media for version 9.0
aws s3api put-object --bucket ${your_bucket} --key installation/cxsast/9.0/


# For storing Checkmarx Installation Media for version 8.9:
aws s3api put-object --bucket ${your_bucket} --key installation/cxsast/8.9/


# For storing common binaries and Checkmarx dependencies:
aws s3api put-object --bucket ${your_bucket} --key installation/common/


# For EC2-Image Builder log files
aws s3api put-object --bucket ${your_bucket} --key imagebuilder/


# For storing Checkmarx field solutions
aws s3api put-object --bucket ${your_bucket} --key installation/field/alg
aws s3api put-object --bucket ${your_bucket} --key installation/field/cloudwatchlogs
aws s3api put-object --bucket ${your_bucket} --key installation/field/dynamic-engines
```

## Uploading Dependencies
### Checkmarx installer bundle
A number of dependencies are available in your Checkmarx installer zip file. Obtain a Checkmarx installer zip from checkmarx.com/downloads (enter your email to recieve a download link) and extract the zip to your local filesystem. The zip file itself and most of the dependencies in the third_party folder must be copied to s3. If you have a different version than the example commands below use then upload the zip file itself and all dependencies in the ```third_party``` folder. 

#### Helper script for version 9.0 (Powershell)
```powershell
# Configure your bucket name and path to your zip file. By default we'll search your downloads folder for the zip where it most likely is.
$your_bucket = "your bucket name here"
$zip = (gci "$((New-Object -ComObject Shell.Application).NameSpace('shell:Downloads').Self.Path)" -Recurse -Filter CxSAST.900.Release.Setup_9.0.0.40085.zip).FullName

### Shouldn't need to modify below here ###
# Make a temp folder
$scratch = Join-Path $env:TEMP $(New-Guid) 
md -force $scratch
$ProgressPreference = "SilentlyContinue"
Expand-Archive -Path "$zip" -DestinationPath "$scratch"

# Dotnet Core Hosting
aws s3 cp "$(Join-Path "$scratch\third_party\.NET Core - Windows Server Hosting\" "dotnet-hosting-2.1.16-win.exe")" s3://${your_bucket}/installation/common/

# C++ Redistributable 2015
aws s3 cp "$(Join-Path "$scratch\third_party\C++_Redist\" "vc_redist2015.x64.exe")" s3://${your_bucket}/installation/common/

# C++ Redistributable 2010
aws s3 cp "$(Join-Path "$scratch\third_party\C++_Redist\" "vcredist_x64.exe")" s3://${your_bucket}/installation/common/

# SQL Server Express 2012
aws s3 cp "$(Join-Path "$scratch\third_party\SQL_Express\" "SQLEXPR_x64_ENU.exe")" s3://${your_bucket}/installation/common/

# The actual zip itself
aws s3 cp "$zip" s3://${your_bucket}/installation/cxsast/9.0/
```

#### Helper script for version 8.9 (Powershell)
```powershell
# Configure your bucket name and path to your zip file. By default we'll search your downloads folder for the zip where it most likely is.
$your_bucket = "your bucket name here"
$zip = (gci "$((New-Object -ComObject Shell.Application).NameSpace('shell:Downloads').Self.Path)" -Recurse -Filter CxSAST.890.Release.Setup_8.9.0.210.zip).FullName

### Shouldn't need to modify below here ###
# Make a temp folder
$scratch = Join-Path $env:TEMP $(New-Guid) 
md -force $scratch
$ProgressPreference = "SilentlyContinue"
Expand-Archive -Path "$zip" -DestinationPath "$scratch"

# C++ Redistributable 2010
aws s3 cp "$(Join-Path "$scratch\third_party\C++_Redist\" "vcredist_x64.exe")" s3://${your_bucket}/installation/common/

# SQL Server Express 2012
aws s3 cp "$(Join-Path "$scratch\third_party\SQL_Express\" "SQLEXPR_x64_ENU.exe")" s3://${your_bucket}/installation/common/

# The actual zip itself
aws s3 cp "$zip" s3://${your_bucket}/installation/cxsast/8.9/
```

### Checkmarx Hotfix Installer and Content Packs
Download any hotfix or content packs from checkmarx.com/downloads and upload those also. These go into the ```s3://${your_bucket}/installation/cxsast/$version/``` path.

#### Helper script (Powershell)
```powershell
# Chose your hotfix, matching version, and s3 bucket and run the script to populate your s3 bucket.
$hotfix=24
$version = "8.9.0" # valid values: 8.9.0, 9.0.0
$your_bucket = "your bucket name here"

### Shouldn't need to modify below here ###
# Make a temp folder
$scratch = Join-Path $env:TEMP $(New-Guid) 
md -force $scratch
$ProgressPreference = "SilentlyContinue"
$s3_key = $version.Substring(0, $version.LastIndexOf("."))

# Tip: set i to a lower value to fetch many hotfixes up to the specified one
For ($i=$hotfix; $i -lt $($hotfix + 1); $i++) {
  "Uploading ${version}.HF${i}.zip to s3 ${s3_key} folder"
  Invoke-WebRequest -UseBasicParsing -Uri https://download.checkmarx.com/${version}/HF/${version}.HF${i}.zip -OutFile "${scratch}/${version}.HF${i}.zip"
  aws s3 cp "${scratch}/8.9.0.HF${i}.zip" s3://${your_bucket}/installation/cxsast/${s3_key}/ --no-progress
}

# 8.9 Content Packs
if ( $version -eq "8.9.0") {
  Invoke-WebRequest -UseBasicParsing -Uri https://download.checkmarx.com/8.9.0/CP/CxSAST.8.9.0-CP94.zip -OutFile (Join-Path $scratch "CxSAST.8.9.0-CP94.zip")
  aws s3 cp "${scratch}/CxSAST.8.9.0-CP94.zip" s3://${your_bucket}/installation/cxsast/${s3_key}/ --no-progress

  Invoke-WebRequest -UseBasicParsing -Uri https://download.checkmarx.com/8.9.0/CP/CSharp/CxSAST.8.9.0-CP60123.zip -OutFile (Join-Path $scratch "CxSAST.8.9.0-CP60123.zip")
  aws s3 cp "${scratch}/CxSAST.8.9.0-CP60123.zip" s3://${your_bucket}/installation/cxsast/${s3_key}/ --no-progress
}




```

### Unbundled dependencies
The Checkmarx manager needs Java and Git, and both Manager and Engine servers need .Net Framework 4.7.1 or higher (latest & backwards compatible is 4.8).

 1. Download the latest Java 8 from https://adoptopenjdk.net/ and copy to ```installation/common```
 1. Download the latest Git for Windows from https://git-scm.com/download/win and copy to ```installation/common```
 1. Download the .NET Framework 4.8 installer from https://dotnet.microsoft.com/download/dotnet-framework/thank-you/net48-offline-installer and copy to ```installation/common```
 1. Download the IIS Rewrite Module from https://www.microsoft.com/en-us/download/confirmation.aspx?id=47337 and copy to ```installation/common```

#### Helper script (Powershell)

```powershell
# Enter your s3 bucket name here:
$your_bucket = "your bucket name here"

### Shouldn't need to modify below here ###
$scratch = Join-Path $env:TEMP $(New-Guid) 
md -force $scratch
$ProgressPreference = "SilentlyContinue"
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072;

# Download latest java
$jdk = (Invoke-RestMethod -Method GET -Uri "https://api.adoptopenjdk.net/v3/assets/latest/8/hotspot" -UseBasicParsing).binary | Where-Object { $_.architecture -eq "x64" -and $_.heap_size -eq "normal" -and $_.image_type -eq "jdk" -and $_.jvm_impl -eq "hotspot" -and $_.os -eq "windows" }
$jdk_file = $jdk.installer.link.Substring($jdk.installer.link.LastIndexOf("/") + 1)
Invoke-WebRequest -UseBasicParsing -Uri "$($jdk.installer.link)" -OutFile (Join-Path $scratch $jdk_file)
aws s3 cp "$(Join-Path $scratch $jdk_file)" s3://${your_bucket}/installation/common/ --no-progress

# Download the latest Git
$git = (Invoke-RestMethod -Method GET -Uri "https://api.github.com/repos/git-for-windows/git/releases/latest" -UseBasicParsing).assets | Where-Object { $_.name -match "Git-\d\.\d\d\.\d-64-bit\.exe" }
Invoke-WebRequest -UseBasicParsing -Uri "$($git.browser_download_url)" -OutFile (Join-Path $scratch $git.name)
aws s3 cp "$(Join-Path $scratch $git.name)" s3://${your_bucket}/installation/common/ --no-progress

# Download .Net 4.8
Invoke-WebRequest -UseBasicParsing -Uri "https://download.visualstudio.microsoft.com/download/pr/014120d7-d689-4305-befd-3cb711108212/0fd66638cde16859462a6243a4629a50/ndp48-x86-x64-allos-enu.exe" -OutFile (Join-Path $scratch "ndp48-x86-x64-allos-enu.exe")
aws s3 cp "$(Join-Path $scratch "ndp48-x86-x64-allos-enu.exe")" s3://${your_bucket}/installation/common/ --no-progress

# Download IIS Rewrite Module
Invoke-WebRequest -UseBasicParsing -Uri "https://download.microsoft.com/download/C/9/E/C9E8180D-4E51-40A6-A9BF-776990D8BCA9/rewrite_amd64.msi" -OutFile (Join-Path $scratch "rewrite_amd64.msi")
aws s3 cp "$(Join-Path $scratch "rewrite_amd64.msi")" s3://${your_bucket}/installation/common/ --no-progress
```
