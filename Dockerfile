# escape=`
FROM mcr.microsoft.com/windows/servercore:ltsc2019
#Workday to AD LDAP Person Sync

SHELL ["powershell", "-Command", "$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'; $verbosePreference='Continue';"]

# Using powershell core in Windows container as a base.
#RUN Install-PackageProvider -Name chocolatey -RequiredVersion 2.8.5.130 -Force; `
#    Install-Package -Name powershell-core-Force;

#Install AD tools
RUN Install-WindowsFeature RSAT-AD-PowerShell ; `
    Import-Module ActiveDirectory

#Copy sync source into image
COPY src /app
WORKDIR /app

ENTRYPOINT [ "powershell", "-C" ]
CMD ["/app/sync.ps1", "$verbosePreference='SilentlyContinue'"]