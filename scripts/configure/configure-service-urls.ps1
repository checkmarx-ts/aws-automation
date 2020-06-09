# Todo, in 9.0, a work in progress

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





