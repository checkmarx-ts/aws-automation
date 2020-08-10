param (

 [Parameter(Mandatory = $False)] [String] $domainJoinUsername = "corp\Admin",
 [Parameter(Mandatory = $True)] [String] $domainJoinUserPassword,
 [Parameter(Mandatory = $True)] [String] $primaryDns,
 [Parameter(Mandatory = $True)] [String] $secondaryDns,
 [Parameter(Mandatory = $True)] [String] $domainName
)
function log($msg) {
  Write-Host $msg
}

# Helper function to fetch SSM Parameters
function  TryGetSSMParameter([String] $parameter) {
  if(!$parameter) { return $null }

  try {
      $ssmParam = Get-SSMParameter -Name $parameter -WithDecryption $True
  
      if($ssmParam) {
      Write-Host "Using the value found for $parameter"
      return $ssmParam.value
      } else {
      Write-Host "Using argument as provided"
      return $parameter
  }
  } catch {
      Write-Host "An error occured while fetching SSM parameter key"
      Write-Host "Using argument as provided"
      return $parameter
  }
}

# Check the input and override with SSM Parameter if it exists, 
# otherwise use the argument values as they were provided
if ($domainJoinUsername.IndexOf("/") -eq 0) {
  Write-Host "domainJoinUsername appears to be an SSM Parameter path - attempting to retrieve"
  $domainJoinUsername = TryGetSSMParameter "$domainJoinUsername"
} else {
  Write-Host "Using domainJoinUsername argument as provided"
}

if ($domainJoinUserPassword.IndexOf("/") -eq 0) {
  Write-Host "domainJoinUserPassword appears to be an SSM Parameter path - attempting to retrieve"
  $domainJoinUserPassword = TryGetSSMParameter "$domainJoinUserPassword"
} else {
  Write-Host "Using domainJoinUserPassword argument as provided"
}

if ($domainName.IndexOf("/") -eq 0) {
  Write-Host "domainName appears to be an SSM Parameter path - attempting to retrieve"
  $domainName = TryGetSSMParameter "$domainName"
} else {
  Write-Host "Using domainName argument as provided"
}

log "domainJoinUsername: ${domainJoinUsername}"
log "domainJoinUserPassword: ${domainJoinUserPassword}"
log "primaryDns: ${primaryDns}"
log "secondaryDns: ${secondaryDns}"
log "domainName: ${domainName}" 

$serverAddresses = @()
$serverAddresses += $primaryDns
$serverAddresses += $secondaryDns

log "serverAddresses: ${serverAddresses}"

$domainJoinCredential = New-Object -TypeName PSCredential -ArgumentList $domainJoinUsername, (ConvertTo-SecureString $domainJoinUserPassword -AsPlainText -Force)
 

# Get the network adapter in use so we can configure it
# AWS EC2 instances probably have just one adapater that is up unless you configure others
# If you configure others you may want to modify this to handle them separately for DNS.
# We assume here that the first one that is up will suffice for DNS setttings for joining
# the domain.

$interface = Get-NetAdapter | Where-Object {$_.Status -eq 'Up'} | Select -First 1
log "Using interface $($interface.ifAlias)"

log "Initial DNS:"
$dnsAddresses = Get-DnsClientServerAddress -InterfaceAlias $interface.ifAlias 
$dnsAddresses

# Set the DNS servers for the domain so we can find it when joining...
log "Updating dns with command:"
log "Set-DnsClientServerAddress -InterfaceAlias $($interface.ifAlias) -ServerAddresses ${serverAddresses}"

Set-DnsClientServerAddress -InterfaceAlias $interface.ifAlias -ServerAddresses $serverAddresses

log "Readback updated DNS:"
$dnsAddresses = Get-DnsClientServerAddress -InterfaceAlias $interface.ifAlias 
$dnsAddresses 

# Now join the domain - this will require a reboot
log "Joining machine to ${domainName}. A reboot will occur"
Add-Computer -DomainName $domainName -Credential $domainJoinCredential -Restart
 