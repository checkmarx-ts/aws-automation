  
<#
.SYNOPSIS
  Updates checkmarx routes to the application fqdn and sets a local hosts file entry to
  use the loopback when talking to itself.
#>

param (
 [Parameter(Mandatory = $False)] [String] $fqdn = "",
 [Parameter(Mandatory = $False)] [String] $connectionstring = "localhost\SQLEXPRESS",
 [Parameter(Mandatory = $False)] [String] $username = "",
 [Parameter(Mandatory = $False)] [String] $password = ""
)

# Force TLS 1.2+ and hide progress bars to prevent slow downloads
Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; 
$ProgressPreference = "SilentlyContinue"

function log([string] $msg) { Write-Host "$(Get-Date -Format G) [$PSCommandPath] $msg" }


if ([String]::IsNullOrEmpty($fqdn)) {
    log "$fqdn parameter empty, checking tags"
    $tags = Get-EC2Tag -filter @{Name="resource-id";Value="$(Get-EC2InstanceMetaData -Category InstanceId)"}
    [string]$dns = $tags | Where-Object { $_.Key -eq "checkmarx:dns" } | Select-Object -ExpandProperty Value
    if ([String]::IsNullOrEmpty($dns)) { log "No dns tag found"; exit 1 }
    log "Found dns tag: $dns"
    $fqdn = $dns
}

log "Configuring for $fqdn..."

$config_update_statements = @"
    update [CxDB].[dbo].[CxComponentConfiguration] set [value] = 'tcp://${fqdn}:61616' where [key] = 'ActiveMessageQueueURL'
    update [CxDB].[dbo].[CxComponentConfiguration] set [value] = 'https://${fqdn}' where [key] = 'CxSASTManagerUri'
    update [CxDB].[dbo].[CxComponentConfiguration] set [value] = 'https://${fqdn}' where [key] = 'CxARMPolicyURL'
    update [CxDB].[dbo].[CxComponentConfiguration] set [value] = 'https://${fqdn}' where [key] = 'CxARMURL'
    -- 9.0 version update [CxDB].[dbo].[CxComponentConfiguration] set [value] = 'https://${fqdn}/CxRestAPI/auth' where [key] = 'IdentityAuthority'
    -- 8.9 version update [CxDB].[dbo].[CxComponentConfiguration] set [value] = 'https://${fqdn}' where [key] = 'IdentityAuthority'
"@

log "updating database configuration"
Invoke-Sqlcmd -ServerInstance $connectionstring -Query $config_update_statements

log "Updating the hosts file to resolve $domainname to 127.0.0.1 to avoid load balancer round trips for web-to-services web-services"
"# Checkmarx will resolve the servername to localhost to bypass load balancer hops for inner-app communication" | Add-Content -PassThru "$env:windir\system32\drivers\etc\hosts"
"127.0.0.1 $fqdn" | Add-Content -PassThru "$env:windir\system32\drivers\etc\hosts"

<# Todo: notes on 9.0:

update [CxDB].[dbo].[CxComponentConfiguration] set [value] = 'tcp://localhost:61616' where [key] = 'ActiveMessageQueueURL'
update [CxDB].[dbo].[CxComponentConfiguration] set [value] = 'http://localhost' where [key] = 'CxSASTManagerUri'
update [CxDB].[dbo].[CxComponentConfiguration] set [value] = 'http://localhost' where [key] = 'CxARMPolicyURL'
update [CxDB].[dbo].[CxComponentConfiguration] set [value] = 'http://localhost' where [key] = 'CxARMURL'
update [CxDB].[dbo].[CxComponentConfiguration] set [value] = 'http://localhost/CxRestAPI/auth' where [key] = 'IdentityAuthority'



update [CxDB].[dbo].[CxComponentConfiguration] set [value] = 'https://sekots9.dev.checkmarx-ts.com' where [key] = 'CxSASTManagerUri'
update [CxDB].[dbo].[CxComponentConfiguration] set [value] = 'https://sekots9.dev.checkmarx-ts.com' where [key] = 'CxARMPolicyURL'
update [CxDB].[dbo].[CxComponentConfiguration] set [value] = 'https://sekots9.dev.checkmarx-ts.com' where [key] = 'CxARMURL'
update [CxDB].[dbo].[CxComponentConfiguration] set [value] = 'https://sekots9.dev.checkmarx-ts.com/CxRestAPI/auth' where [key] = 'IdentityAuthority'
update [CxDB].[accesscontrol].[ConfigurationItems] set [value] = 'https://sekots9.dev.checkmarx-ts.com' where [key] = 'SERVER_PUBLIC_ORIGIN'


insert into [accesscontrol].[ClientRedirectUris]  ( ClientId, RedirectUri) 
values ('6', 'https://sekots9.dev.checkmarx-ts.com/CxWebClient/authCallback.html?')

insert into [accesscontrol].[ClientRedirectUris]  ( ClientId, RedirectUri) 
values ('6', 'https://sekots9.dev.checkmarx-ts.com/CxWebClient/authSilentCallback.html?')

insert into [accesscontrol].[ClientRedirectUris]  ( ClientId, RedirectUri) 
values ('6', 'https://sekots9.dev.checkmarx-ts.com/CxWebClient/SPA/#/redirect?')

insert into [accesscontrol].[ClientRedirectUris]  ( ClientId, RedirectUri) 
values ('6', 'https://sekots9.dev.checkmarx-ts.com/CxWebClient/SPA/#/redirectSilent?')
#>

