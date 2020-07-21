# Overview
A set of Ansible playbooks to automate the installation and configuration of Checkmarx. 

# Target Host Requirements

Target hosts need to enable WinRM remoting, CredSSP, and have an account to use for Ansible. The below script can be pasted into user data fields for AWS EC2 to achieve this

Note: change the password, and review the ```ConfigureRemotingForAnsible.ps1``` script per your needs (you are trusting remote code).

```
<powershell>
# Enable WinRM for Ansible's remoting to target host
$url = "https://raw.githubusercontent.com/ansible/ansible/devel/examples/scripts/ConfigureRemotingForAnsible.ps1"
$file = "$env:temp\ConfigureRemotingForAnsible.ps1"
(New-Object -TypeName System.Net.WebClient).DownloadFile($url, $file)
powershell.exe -ExecutionPolicy ByPass -File $file 

# Enable CredSSP on target host
#Enable-WSManCredSSP -Role Server -Force

# Set the admin password to connect with
net user Administrator redacted  # Change to your own password
</powershell>
```

# Ansible control node
Any Ansible control node should do (ie any linux box/linux jump host).

## Control node from Windows Subsystem for Linux (WSL)

Ansible works ok using WSL/Ubuntu as the control node for development and testing. Find out how to enable it here: https://docs.microsoft.com/en-us/windows/wsl/install-win10 then install Control Node Requirements packages. 

## Control Node Requirements

 Install these packages required by this playbook.

```
sudo apt install python-pip
pip install "pywinrm>=0.2.2"
pip install pywinrm[credssp]
```

# Limitations and Workarounds

## Checkmarx CxSAST Component Installation Order
For unknown reasons the Checkmarx components cannot be installed all at once (for an "All-in-One" - they must be installed component by component ie Audit->Engine->Web->Manager->BI). If you do not do it this way the installer hangs while, I think, trying to run the database migrations and the result is that there is no CxDB database ever created and the installation hangs forever until timeout. The installers also are not great at being run more than once on the same machine (hang ups will happen).

The role ```cxsast-all-in-one``` will handle this for you if you do not want to manually control it in your playbooks.

Other installers, like for Hot Fixes, Plugins, Utilities, are all available and can be downloaded from the Checkmarx website. 

## DBConnectionData.config
The component installers may delete the ```DBConnectionData.config``` when they are executed individually like the playbooks must do (see above). 

# Roles

For convienience, only high level roles are in the roles folder while other supporting roles for dependencies and for good factoring are nested. End users are encouraged to stick to the high level roles and rely on role dependencies to pull in whatever other roles are needed. This keeps playbooks nice and short. 


# Usage

Configure your inventory in your hosts file, then run the playbook:

```ansible-playbook -i hosts cxmanager.yml```
