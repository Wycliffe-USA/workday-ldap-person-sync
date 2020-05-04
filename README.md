# Workday to AD LDAP Person Sync

Synchronizes users from Workday to AD's LDAP environment.  Responsible for new account creation, account information updates, and account deactivations.  Does not sync account passwords.

## Project Information

This project is designed to run in a docker container.  It utilizes the powershell language and powershell command line interpreter.  Currently, powershell core is not supported due to lack of AD module support.

It can be run from a container which has a managed group service account or by using the sync.ps1 script via powershell.

An example of how to run the script is:
```
.\sync.ps1 -workdayRptUsr '[report_access_username]' -workdayRptPwd '[report_access_password]' -workdayRptUri '[workday_report_uri]' -Confirm:$true
```
Workday Report URI example: `https://services1.myworkday.com/ccx/service/customreport2/[tenant]/[user]/[report_name]?format=json`
Other options can be overridden by passing them on the command prompt.

## Requirements
 - Expected Workday report field names: The process expects a Workday report with specific field names for user information.  The field names are 'accountLocked', 'company', 'country', 'department', 'displayName', 'email', 'givenName', 'lastName', 'managerEmail', 'mobileNumber', 'positionLocation', 'staffID', 'staffType', 'state', 'telephoneNumber', 'title', 'userName'
 - Expected AD fields
   - employeeNumber: The sync matches users based on Workday's `staffID` field and this `employeeNumber` field in AD.  The `employeeNumber` field should be populated on all existing users before starting the process for the first time.
 - If running in a container, Container based domain permissions - see below.

## Building and storing the docker image:
The container runs from an image that is build and stored in the local docker hub repository. This must be built from a system that supports the servercore image (server, not windows 10)
### Build
```
cd [this directory]
docker build -t workday-ldap-person-sync:latest .
```

### Configure domain/container permissions.
In order for docker containers to authenticate to and interact with AD Domain resources, they must use group managed service service accounts.  There are publicly available [instructions](https://docs.microsoft.com/en-us/virtualization/windowscontainers/manage-containers/manage-serviceaccounts) on how to set up a gMSA.  After which, you'll have a JSON credential file.  Use the credential file when running the container, below.

### Run the container
```
docker run -h 'wd-ldap-per-syc' --security-opt 'credentialspec=file://credential_file.json' -e workdayRptUsr='[report_access_username]' -e workdayRptPwd='[report_access_password]' -e workdayRptUri='https://services1.myworkday.com/ccx/service/customreport2/[tenant]/[username]/[report_name]?format=json' -e failsafeRecordChangeLimit=15 --network default_nat workday-ldap-person-sync:latest
```
The `-h` hostname is somewhat arbitrary, but should match that which was setup with the gMSA.

### Managing exceptions
In order to help manage one-time exceptions, you can add a field to the user's `info` field called `WorkdayManaged` and set it to `false`.  This allows the user to be managed manually, while having the sync process ignore the user.  AD's `info` field is also displayed as the `notes` field in the AD Users and Computers snap-in.  The information must be json formatted.  To set WorkdayManaged to false, enter the following
```
{
  "WorkdayManaged": false
}
```

### Common Issues
* `ConvertFrom-Json : Invalid JSON primitive.`: This occurs when an AD User's 'info' field has been set with invalid JSON.  This sync uses the info field to store extra attributes in JSON format. Edit the code to show which user this error is occurring on and resolve the invalid syntax.
* `no matching manifest for unknown in the manifest list entries`: Build the image on a server system instead of Windows 10.