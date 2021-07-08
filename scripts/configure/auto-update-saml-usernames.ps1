# This script will automatically update usernames to the expected SAML prefix when a user
# has a user type of 6 (SAML) but does not yet have the prefix.

$config = Import-PowerShellDataFile -Path C:\checkmarx-config.psd1
. $PSScriptRoot\..\CheckmarxAWS.ps1

###############################################################################
# Get secrets
###############################################################################
$config.MsSql.Username = [Utility]::TryGetSSMParameter($config.MsSql.Username)
$config.MsSql.Password = [Utility]::TryGetSSMParameter($config.MsSql.Password)


###############################################################################
# Add the SAML prefix to user names
###############################################################################
[DbClient] $cxdb = [DbClient]::new($config.MsSql.Host, "CxDB", ($config.MsSql.UseSqlAuth.ToUpper() -eq "FALSE"), $config.MsSql.Username, $config.MsSql.Password)
$log.Info("Updating GIT_EXE_PATH")
$cxdb.ExecuteNonQuery("UPDATE u SET u.username = 'SAML\' + u.username FROM cxdb.dbo.users u JOIN cxdb.dbo.usertype ut on u.ID = ut.UserId WHERE ut.type = 6 And u.username not like 'SAML\%'")
$cxdb.ExecuteNonQuery("UPDATE ut SET ut.username = 'SAML\' + ut.username FROM cxdb.dbo.usertype ut WHERE ut.type = 6 and ut.username not like 'SAML\%'")
