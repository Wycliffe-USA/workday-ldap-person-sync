#!/usr/bin/powershell -noprofile
[CmdletBinding(SupportsShouldProcess=$true)]
param (
  [string]$workdayRptUsr,
  [string]$workdayRptPwd,
  [string]$workdayRptUri,
  [string]$aDActiveAccountSearchBase   = 'CN=Users,DC=CONTOSO,DC=COM',
  [string]$aDDisabledAccountSearchBase = 'OU=zzz,DC=CONTOSO,DC=COM',
  [string]$domainName                  = 'CONTOSO.COM',
  [string]$accountDisablePrefix        = 'zz',
  [string]$aDActiveAccountsDN          = "CN=Users,DC=CONTOSO,DC=COM",
  [string]$aDDisabledAccountsDN        = 'OU=zzz,DC=CONTOSO,DC=COM',
  [int]$failsafeRecordChangeLimit      = 5,
  [int]$minSafeUserCount               = 1000
)

## Notes
# Purpose : Sync Workday user attributes to Active Directory
# -workdayRptUsr : User account to access workday report containing workday user information.
# -workdayRptPwd : Password for workdayRptUsr.
# -workdayRptUri : Uri location of workday report.
# -aDActiveAccountSearchBase : Search base in Active Directory when searching for list of users.
# -domainName : which domain are the AD users a part of?
# -aDServer : dns name of domain controller to connect to.
# -aDActiveAccountsDN : Where new accounts and reenabled accounts will be placed in the directory.
# -adDisabledAccountsDN : Where to place disabled accounts.
# -failsafeRecordChangeLimit : Sets a limit of changes to user's accounts. Each change to any record is counted.  The script exists at the end of processing a user and when it has reached this threshold.
# -minSafeUserCount : Minimum amount of users expected from both Workday and AD.  If the query returns less than this amount, something is presumed to have gone wrong.
#
# Also supports -Confirm:$true to confirm each action.
# This script uses powershell.  It could be ported to powershell-core when the active directory module is supported.
#
# Setting WorkdayManged: To manually exclude an account from the sync process, set workday managed in their 'info' field.  The info field is found under the telephone tab and is otherwise known as the 'Notes' field.
#  Depending on the information already in this field, you may need to add this to the existing information, but the field should include "WorkdayManaged" as in the example below.
# {
#   "WorkdayManaged":  false
# }

#####################################################
###VVVVVVVVVVVVV Import modules VVVVVVVVVVVVVV#######
Import-Module ./Functions/JSON-To-Hashtable.psm1

#####################################################
###VVVVVVVVV Initial Variable Assignment VVVVVVVVV###
#Check for variable assignment via system environment variables.  This allows the operator to use docker environment vars.
if ($env:workdayRptUsr){$workdayRptUsr = $env:workdayRptUsr}
if ($env:workdayRptPwd){$workdayRptPwd = $env:workdayRptPwd}
if ($env:workdayRptUri){$workdayRptUri = $env:workdayRptUri}
if ($env:aDActiveAccountSearchBase){$aDActiveAccountSearchBase = $env:aDActiveAccountSearchBase}
if ($env:aDDisabledAccountSearchBase){$aDDisabledAccountSearchBase = $env:aDDisabledAccountSearchBase}
if ($env:domainName){$domainName = $env:domainName}
if ($env:accountDisablePrefix){$accountDisablePrefix = $env:accountDisablePrefix}
if ($env:aDActiveAccountsDN){$aDActiveAccountsDN = $env:aDActiveAccountsDN}
if ($env:aDDisabledAccountsDN){$aDDisabledAccountsDN = $env:aDDisabledAccountsDN}
if ($env:failsafeRecordChangeLimit){$failsafeRecordChangeLimit = $env:failsafeRecordChangeLimit}

$recordChanges = 0
$error.Clear()
$errors = @()
$workdayAndADMatchingUsers = @()
$runTimeStart = Get-Date
$global:ProgressPreference = "SilentlyContinue"
$aDUsers = @{}
$aDDisabledUsers = @{}
$workdayUsers = @{}

#Configure an array of field names.  Since workday and AD use different field names for the same data, we'll keep track of those here and use them in this script.
$userFieldMapping = @{
  'accountLocked'    = @{ 'wd' = 'accountLocked' ; 'ad' = 'userAccountControl' }
  'company'          = @{ 'wd' = 'company' ; 'ad' = 'company' }
  'country'          = @{ 'wd' = 'country' ; 'ad' = 'co' }
  'department'       = @{ 'wd' = 'department' ; 'ad' = 'department' }
  'displayName'      = @{ 'wd' = 'displayName' ; 'ad' = 'displayName' }
  'email'            = @{ 'wd' = 'email' ; 'ad' = 'mail' }
  'givenName'        = @{ 'wd' = 'givenName' ; 'ad' = 'givenName' }
  'lastName'         = @{ 'wd' = 'lastName' ; 'ad' = 'sn' }
  'managerEmail'     = @{ 'wd' = 'managerEmail' ; 'ad' = 'info' }
  'mobileNumber'     = @{ 'wd' = 'mobileNumber' ; 'ad' = 'mobile' ; 'adSecondary' = 'otherMobile' }
  'positionLocation' = @{ 'wd' = 'positionLocation' ; 'ad' = 'physicalDeliveryOfficeName' }
  'staffID'          = @{ 'wd' = 'staffID' ; 'ad' = 'employeeNumber' }
  'staffType'        = @{ 'wd' = 'staffType' ; 'ad' = 'employeeType' }
  'state'            = @{ 'wd' = 'state' ; 'ad' = 'st' }
  'telephoneNumber'  = @{ 'wd' = 'telephoneNumber' ; 'ad' = 'telephoneNumber' ; 'adSecondary' = 'otherTelephone' }
  'title'            = @{ 'wd' = 'title' ; 'ad' = 'title' }
  'userName'         = @{ 'wd' = 'userName' ; 'ad' = 'name' }
}
###^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^###
#####################################################
###VVVVVVVVVVVVVV Functions VVVVVVVVVVVVV###
function finalStatusReport(){
  if (($errors.Count -ge 1) -Or ($error.Count -ge 1)){
    #There were errors during the process.  Report the error and exit with a status 1
    $output = "Workday-LDAP-Person-Sync completed with error(s) in " + [math]::Round(((Get-Date) - $runTimeSTart).TotalMinutes,2) + " minutes."
    Write-Error $output
    exit 1
  }else{
    #No errors during the process.  Exit with status 0
    $output = "Workday-LDAP-Person-Sync completed successfully with no errors in " + [math]::Round(((Get-Date) - $runTimeSTart).TotalMinutes,2) + " minutes."
    Write-Output $output
    exit 0
  }
}
###^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^###

#####################################################
###VVVVVVVVV Get User Data From Workday VVVVVVVVVV###
#Get Workday Report containing user list.
$secWorkdayPwd = $workdayRptPwd| ConvertTo-SecureString -AsPlainText -Force
$workdayCreds = New-Object System.Management.Automation.PSCredential ($workdayRptUsr, $secWorkdayPwd)
$workdayRestResponse = Invoke-RestMethod -Credential $workdayCreds -Uri $workdayRptUri -ErrorVariable errorOutput

#Error handling in case the workday response is blank or has too few entries.
if (($errorOutput) -Or !($workdayRestResponse) -Or (($workdayRestResponse.Report_Entry|Measure-Object).Count -lt $minSafeUserCount)){Write-Error "Workday-LDAP-Person-Sync Error: Got less than $minSafeUserCount results from Workday or an error occurred.  Possible source data issue." ; exit 1}

###
#Save workdayresponse entries into workdayUsers array.
ForEach ($user in $workdayRestResponse.Report_Entry){
  #As we take the report response and add user entries into the $workdayUsers variable, we will first make sure each account has required values.
  # These issues sometimes arrise temporarily as workday staff add details to the user's account.
  if (!($user.staffID)){
    #Missing a staffID.  This could happen when a person's record is first created.
    $output = "Workday user missing staffID: || username: '" + $user.userName + "', displayname: '" + $user.displayName +"', email: '" + $user.email +"'. Not including this user in this run."
    Write-Warning $output 
  }elseif (!($user.userName)){
    #Missing a userName.  This could happen when a person's record is first created.
    $output = "Workday user missing userName: || staffID: '" + $user.staffID + "', displayname: '" + $user.displayName +"', email: '" + $user.email +"'. Not including this user in this run."
    Write-Warning $output 
  }elseif ($user.staffID -like '[A-Z]*'){
    #staffIDs should not contain letters.  However, they have sometimes briefly been created or modified to contain letters.
    $output = "Workday user's staffID contains a letter: || staffID: '" + $user.staffID + "',  username: '" + $user.userName + "', displayname: '" + $user.displayName +"', email: '" + $user.email +"'. Not including this user in this run."
    Write-Warning $output 
  }else{
    $workdayUsers[$user.staffID] = $user
  }
}

$result = $workdayUsers.keys|Measure-Object
$output = "Beginning sync for "+$result.Count+ " users."; Write-Output $output
###^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^###
#####################################################

#####################################################
###VVVVVVVVV Get User Data From AD LDAP VVVVVVVVVV###
# Can simplify these when ActiveDirecotry Module available to powershell-core
ForEach ($aDUser in (Get-ADUser -Filter * -SearchBase $aDActiveAccountSearchBase -Properties "Name","sAMAccountName","displayName","givenName","sn","mail","employeeNumber","department","company","co","manager","mobile","otherMobile","physicalDeliveryOfficeName","st","telephoneNumber","otherTelephone","title","employeeType","UserAccountControl","DistinguishedName","ObjectGUID","info" -ErrorVariable errorOutput)){
  #Build a Hashtable of AD Users.  This will help to save time later by calling up the workdayUser's staffID in the able rather than cycle through the AD user list in each and every nested for loop.  
  if ($aDUser.employeeNumber){
    $aDUsers[$aDUser.employeeNumber] = $aDUser
  }
}
if ($errorOutput){Write-Error "An error occurred getting data from AD." ; exit 1}
ForEach ($aDDisabledUser in (Get-ADUser -Filter * -SearchBase $aDDisabledAccountSearchBase -Properties "Name","sAMAccountName","displayName","givenName","sn","mail","employeeNumber","department","company","co","manager","mobile","otherMobile","physicalDeliveryOfficeName","st","telephoneNumber","otherTelephone","title","employeeType","UserAccountControl","DistinguishedName","ObjectGUID","info" -ErrorVariable errorOutput)){
  #Build a Hashtable of disabled AD Users.
  if ($aDDisabledUser.employeeNumber){
    $aDDisabledUsers[$aDDisabledUser.employeeNumber] = $aDDisabledUser
  }
}
if ($errorOutput){Write-Error "An error occurred getting data from AD." ; exit 1}
if (($aDUsers.keys|Measure-Object).Count -lt $minSafeUserCount){Write-Error "Workday-LDAP-Person-Sync Error: Got less than $minSafeDisabledUserCount results from AD.  Possible source data issue." ; exit 1}
###^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^###
#####################################################

#####################################################
###VVVVVVVVVVVVVVVV Main Logic VVVVVVVVVVVVVVVVVVV###

#Add new users & sync current user data.  We'll handle disabling users separately.
###vvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvv###
#After getting a list of users from workday, we process each against AD user information, looking for differences and rectifying them.
ForEach ($key in $workdayUsers.keys){
  $workdayUser = $workdayUsers[$key]
  #Syncronize data on existing accounts (including those existing in the disabled users OU.)
  ###vvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvv###
  
  If ($aDUsers.Keys -Contains $workdayUser.staffID){
    $aDUser = $aDUsers[$workdayUser.staffID]

    #Initialize the info field.
    # Later fill this object with data from Workday that doesn't fit into other fields.
    # First, we get the 'WorkdayManaged' field from AD, since it doesn't come from Workday, so we can carry it over.
    if (($aDUser.info) -And (($aDUser.info|ConvertFrom-Json|ConvertTo-HashTable).Keys -Contains 'WorkdayManaged')){
      $workdayUserInfoField = @{'WorkdayManaged' = ($aDUser.info|ConvertFrom-Json|ConvertTo-HashTable).WorkdayManaged}
    }else{
      $workdayUserInfoField = @{}
    }


    #We won't manage AD user accounts that have 'WorkdayMangaed: false' in their info field.
    $workdayManaged = $true
    If(($workdayUserInfoField.Keys -Contains 'WorkdayManaged') -And ($workdayUserInfoField.WorkdayManaged -eq $False)){
      $workdayManaged = $false
    }

    If($workdayManaged){
      #Synchronize fields between workday and ldap.
      # For some fields we'll have to take special care.  For others we'll just compare the fields.
      ForEach ($field in @('accountLocked', 'company', 'country', 'department', 'displayName', 'email', 'givenName', 'lastName', 'managerEmail', 'mobileNumber', 'positionLocation', 'staffID', 'staffType', 'state', 'telephoneNumber', 'title', 'userName')){
        #Special care fields - We need to take special care where certain feild types or methods do not align cleanly.  Then we'll just compare the rest.
        if ($field -eq 'accountLocked'){
          #Field - Account Locked
          ###vvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvv###
          if ($workdayUser.accountLocked -eq 'True'){
            #The workday account is locked.  The ad userAccountControl integer should contain the '2' bit.
            if (!($aDUser.userAccountControl -band 2)){
              #This user isn't locked in AD, but should be.
              $output = "Disable: Workday User " + $workdayUser.staffID + " (" +  $workdayUser.displayName + ") matching AD user " + $aDUser.employeeNumber + " (" + $aDUser.displayName + ") (SID: " + $adUser.SID + ") should be disabled in AD, but is not."
              Write-Output $output

              #Set this AD user's account to be disabled.
              $output = "Disabling account for AD User: " + $aDUser.displayName + " (" + $aDUser.SID + ")"
              Write-Output $output
              Disable-ADAccount -Identity $aDUser.ObjectGUID -ErrorVariable errorOutput
              if($errorOutput){$errors += $errorOutput}
              $recordChanges += 1
            }
          }Else{
            #The workday account is not locked.  The ad userAccountControl integer should NOT contain the '2' bit.
            if ($aDUser.userAccountControl -band 2){
              $output = "Enable: Workday User " + $workdayUser.staffID + " (" +  $workdayUser.displayName + ") matching AD user " + $aDUser.employeeNumber + " (" + $aDUser.displayName + ") (SID: " + $adUser.SID + ") should not be disabled in AD, but is."
              Write-Output $output

              #Set this AD user's account to be enabled.
              $output = "Enabling account for AD User: " + $aDUser.displayName + " (" + $aDUser.SID + ")"
              Write-Output $output
              Enable-ADAccount -Identity $aDUser.ObjectGUID -ErrorVariable errorOutput
              if($errorOutput){$errors += $errorOutput}
              $recordChanges += 1
            }
          }
          ###^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^###
        }elseif(($field -eq 'mobileNumber') -Or ($field -eq 'telephoneNumber')){
          #Field - Mobile Number OR Telephone Number
          ###vvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvv###
          # Workday provides multiple mobile & telephone numbers (per field).  In AD, these are split into two separate fields.  We have to separate those out as we deal with them.
          if ($field -eq 'mobileNumber') { $aDPrimaryPhoneField = 'mobile'; $aDSecondaryPhoneField = 'otherMobile'}
          if ($field -eq 'telephoneNumber') { $aDPrimaryPhoneField = 'telephoneNumber'; $aDSecondaryPhoneField = 'otherTelephone'}

          #Test to see if there is even a number listed.
          if ($workdayUser.($field)){
            #Workday has numbers listed.
            $phoneNumbers = $workdayUser.($field) -split ";[ ]?"

            # First make sure the first phone number we got from workday is present in AD.
            #  Using '$field' here, because it could be either the mobileNumber or the telephoneNumber we're dealing with.
            if ($phoneNumbers[0] -ne $aDUser.($aDPrimaryPhoneField)){
              #The first number listed does not match the AD field for either telephoneNumber or mobile.
              $output = $field + ": Workday user " + $workdayUser.staffID + " (" +  $workdayUser.displayName +")'s "+ $field + " '" + $phoneNumbers[0] + "' did not match AD user "+ $aDUser.employeeNumber + " (" + $aDUser.displayName + ") (SID: " + $adUser.SID + ")'s " + $aDPrimaryPhoneField + " '" + $aDUser.($aDPrimaryPhoneField) + "'."
              Write-Output $output
              $output = "Replacing AD field '" + $aDPrimaryPhoneField + "' with value '" + $phoneNumbers[0] + "' for user " + $aDUser.employeeNumber + " (" + $aDUser.displayName + ") (SID: " + $adUser.SID + ")"
              Write-Output $output

              Set-AdUser -Identity $aDUser.ObjectGUID -Replace @{$aDPrimaryPhoneField=$phoneNumbers[0]} -ErrorVariable errorOutput
              if($errorOutput){$errors += $errorOutput}
              $recordChanges += 1
            }

            #Next, we make sure any additional phone numbers we got from workday are present in the AD 'secondary' fields.
            $secondaryPhoneNumbers = ''
            For($i=1; $i -lt ($phoneNumbers|Measure-Object).Count; $i++){
              $secondaryPhoneNumbers += $phoneNumbers[$i] + "; "
            }

            #Trim the trailing '; '
            $secondaryPhoneNumbers = $secondaryPhoneNumbers.Trim(';[ ]?')

            #If there are secondary numbers listed, see if they need to be changed.
            if ($secondaryPhoneNumbers -ne ''){
              if ($secondaryPhoneNumbers -ne $aDUser.($aDSecondaryPhoneField)){
                $output = $field + ": Workday user " + $workdayUser.staffID + " (" +  $workdayUser.displayName +")'s other "+ $field + "[s] '" + $secondaryPhoneNumbers + "' did not match AD user "+ $aDUser.employeeNumber + " (" + $aDUser.displayName + ") (SID: " + $adUser.SID + ")'s " + $aDSecondaryPhoneField + " '" + $aDUser.($aDSecondaryPhoneField) + "'."
                Write-Output $output
                $output = "Replacing AD field '" + $aDSecondaryPhoneField + "' with value '" + $secondaryPhoneNumbers + "' for user " + $aDUser.employeeNumber + " (" + $aDUser.displayName + ") (SID: " + $adUser.SID + ")"
                Write-Output $output

                Set-AdUser -Identity $aDUser.ObjectGUID -Replace @{$aDSecondaryPhoneField=$secondaryPhoneNumbers} -ErrorVariable errorOutput
                if($errorOutput){$errors += $errorOutput}
                $recordChanges += 1
              }
            }else{
              if ($aDUser.($aDSecondaryPhoneField)){
                #There are no secondary numbers from workday, but there is one listed in AD. Clear it.
                $output = $field + ": Workday user " + $workdayUser.staffID + " (" +  $workdayUser.displayName +")'s other "+ $field + "[s] were empty.  Clearing AD user "+ $aDUser.employeeNumber + " (" + $aDUser.displayName + ") (SID: " + $adUser.SID + ")'s " + $aDSecondaryPhoneField + " '" + $aDUser.($aDSecondaryPhoneField) + "'."
                Write-Output $output
                $output = "Clearing AD field '" + $aDSecondaryPhoneField + "' with value '" + $aDUser.($aDSecondaryPhoneField) + "' for user " + $aDUser.employeeNumber + " (" + $aDUser.displayName + ") (SID: " + $adUser.SID + ")"
                Write-Output $output

                Set-AdUser -Identity $aDUser.ObjectGUID -Clear $aDSecondaryPhoneField -ErrorVariable errorOutput
                if($errorOutput){$errors += $errorOutput}
                $recordChanges += 1
              }
            }
          }else{
            #Workday has no numbers, so we should clear AD.
            if ($aDUser.($aDPrimaryPhoneField) -Or $aDUser.($aDSecondaryPhoneField)){
              $output = $field + ": Workday user " + $workdayUser.staffID + " (" +  $workdayUser.displayName +")'s "+ $field + " was not set.  Should remove AD " + $aDPrimaryPhoneField + " value '" + $aDUser.($aDPrimaryPhoneField) + "' and " + $aDSecondaryPhoneField + " value '" + $aDUser.($aDSecondaryPhoneField) + "'"
              Write-Output $output
              $output = "Clearing AD field '" + $aDPrimaryPhoneField + "' with value '" + $aDUser.($aDPrimaryPhoneField) + "' and field " + $aDSecondaryPhoneField + "' with value '" + $aDUser.($aDSecondaryPhoneField) + "' for user " + $aDUser.employeeNumber + " (" + $aDUser.displayName + ") (SID: " + $adUser.SID + ")"
              Write-Output $output

              Set-AdUser -Identity $aDUser.ObjectGUID -Clear $aDPrimaryPhoneField -ErrorVariable errorOutput
              if($errorOutput){$errors += $errorOutput}
              Set-AdUser -Identity $aDUser.ObjectGUID -Clear $aDSecondaryPhoneField -ErrorVariable errorOutput
              if($errorOutput){$errors += $errorOutput}
              $recordChanges += 1
            }
          }
          ###^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^###
        }elseif($field -eq 'userName'){
          #Field - userName
          ###vvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvv###

          #Due to some data quality issues, some workday usernames have spaces in them instead of underscores.
          # Replace spaces with underscores.
          if ($workdayUser.userName -Like "* *"){
            $output = "Incoming workday user "+ $workdayUser.staffID + " (" +  $workdayUser.displayName +")'s username '" + $workdayUser.userName + "' contained a space. Replacing with underscore."
            Write-Warning $output
            $workdayUser.userName = $workdayUser.userName -Replace " ","_" ;
          }

          #Check to see if there are descrepencies in the user names - like a user has been renamed.
          if ($workdayUser.userName -ne $aDUser.name){
            #The username is different.  It was probably changed in Workday.
            $output = "userName: Workday user "+ $workdayUser.staffID + " (" +  $workdayUser.displayName +")'s username '" + $workdayUser.userName + "' did not match AD user "+ $aDUser.employeeNumber + " (" + $aDUser.displayName + ") (SID: " + $adUser.SID + ")'s username '" + $aDUser.name + "'."
            Write-Output $output

            If ($PSCmdlet.ShouldProcess($aDUser,"Rename AD User '" + $aDUser.name + "' to '" + $workdayUser.userName + "'.")) {
              $output = "Renaming AD user '" + $aDUser.name + "' (SID: " + $adUser.SID + ") to '" + $workdayUser.userName + "'."
              Write-Output $output

              #Build UserPrincipalName
              $userPrincipalName = $workdayUser.userName + "@" + $domainName

              rename-adobject -Identity $aDUser.ObjectGUID -NewName $workdayUser.userName -ErrorVariable errorOutput
              if($errorOutput){$errors += $errorOutput}
              
              #SamAcountName must be 20 characters or less.
              $samAcountName = $workdayUser.userName.subString(0, [System.Math]::Min(20, $workdayUser.userName.Length)) 

              Set-AdUser -Identity $aDUser.ObjectGUID -Replace @{SamAccountName=$samAcountName;UserPrincipalName=$userPrincipalName} -ErrorVariable errorOutput
              if($errorOutput){$errors += $errorOutput}
              $recordChanges += 1
            }
          }
          ###^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^###
        }elseif($field -eq 'managerEmail'){
          #Field - manager
          ###vvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvv###
          # We use the info (aka notes) AD field to report the manager email.
          # The info field is used instead of the manager field in AD since the manager field must be tied to an actual AD account.
          # This could be complex if the managers username(s) are not present.
          # Instead, we add the manager's email to a list of other relevant information ($workdayUserInfoField) which will be placed in the 'info' field later.
          if ($workdayUser.managerEmail){
            $workdayUserInfoField['ManagerEmail'] = $workdayUser.managerEmail
          }
          ###^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^###
        }elseif($field -eq 'staffID'){
          #Field - StaffID - Skip
        }else{
          #All Other Fields
          ###vvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvv###
          if ($workdayUser.($field) -ne $aDUser.($userFieldMapping[$field]['ad'])){
            $output = $field + ": Workday user " + $workdayUser.staffID + " (" +  $workdayUser.displayName +")'s "+ $field + " '" + $workdayUser.($field) + "' did not match AD user "+ $aDUser.employeeNumber + " (" + $aDUser.displayName + ") (SID: " + $adUser.SID + ")'s " + $userFieldMapping[$field]['ad'] + " '" + $aDUser.($userFieldMapping[$field]['ad']) + "'."
            Write-Output $output

            $output = "Replacing AD field '" + $userFieldMapping[$field]['ad'] + "' with value '" + $workdayUser.($field) + "' for user " + $aDUser.employeeNumber + " (" + $aDUser.displayName + ") (SID: " + $adUser.SID + ")"
            Write-Output $output

            #If the workday data is not provided or blank, clear the data.  Otherwise set it.
            if (!($workdayUser.($field)) -Or $workdayUser.($field) -eq ''){
              Set-AdUser -Identity $aDUser.ObjectGUID -Clear $userFieldMapping[$field]['ad'] -ErrorVariable errorOutput
            }else{
              Set-AdUser -Identity $aDUser.ObjectGUID -Replace @{$userFieldMapping[$field]['ad']=$workdayUser.($field)} -ErrorVariable errorOutput
            }
            if($errorOutput){$errors += $errorOutput}
            $recordChanges += 1
          }
          ###^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^###
        }
      }

      #Now we will deal with info (aka notes) field in AD.
      #Convert our info array into json.  We'll store the json in the info field in AD.
      $workdayUserInfoField = $workdayUserInfoField|ConvertTo-Json
      if ($workdayUserInfoField -ne $adUser.info){
          $output = "Info: Workday user " + $workdayUser.staffID + " (" +  $workdayUser.displayName +")'s additional info '" + $workdayUserInfoField + "' did not match AD user "+ $aDUser.employeeNumber + " (" + $aDUser.displayName + ") (SID: " + $adUser.SID + ")'s info '" + $aDUser.info + "'."
          Write-Output $output

          if (!($workdayUserInfoField) -Or $workdayUserInfoField -eq ''){
            $output = "Clearing AD field 'info' with value '" + $workdayUserInfoField + "' for user " + $aDUser.employeeNumber + " (" + $aDUser.displayName + ") (SID: " + $adUser.SID + ")"
            Write-Output $output

            Set-AdUser -Identity $aDUser.ObjectGUID -Clear info -ErrorVariable errorOutput
            if($errorOutput){$errors += $errorOutput}
            $recordChanges += 1
          }else{
            $output = "Replacing AD field 'info' with value '" + $workdayUserInfoField + "' for user " + $aDUser.employeeNumber + " (" + $aDUser.displayName + ") (SID: " + $adUser.SID + ")"
            Write-Output $output

            Set-AdUser -Identity $aDUser.ObjectGUID -Replace @{'info'=$workdayUserInfoField} -ErrorVariable errorOutput
            if($errorOutput){$errors += $errorOutput}
            $recordChanges += 1
          }
      }

      ###vvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvv###
      #Determine if account move is necessary.
      if (!($aDUser.DistinguishedName -like "*$aDActiveAccountsDN")){
        $output = "Moving AD user '" + $aDUser.name + "' (SID: " + $aDUser.SID + ") to '" + $aDActiveAccountsDN + "' because it was previously disabled but now found in Workday."
        Write-Output $output
        Move-ADObject -Identity $aDUser.ObjectGUID -TargetPath $aDActiveAccountsDN -ErrorVariable errorOutput
        if($errorOutput){$errors += $errorOutput}
        $recordChanges += 1
      }
      ###^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^###
    }
  }ElseIf($aDDisabledUsers.Keys -Contains $workdayUser.staffID){
    $aDUser = $aDDisabledUsers[$workdayUser.staffID]
    ###vvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvv###
    #Find any user account that is not in the active user container and move them.  (Most likely a previously disabled user account.)
    #Determine if account move is necessary.
    if (!($aDUser.DistinguishedName -like "*$aDActiveAccountsDN")){
      $output = "Moving AD user '" + $aDUser.name + "' (SID: " + $aDUser.SID + ") to '" + $aDActiveAccountsDN + "' because it was previously disabled but now found in Workday."
      Write-Output $output
      Move-ADObject -Identity $aDUser.ObjectGUID -TargetPath $aDActiveAccountsDN -ErrorVariable errorOutput
      if($errorOutput){$errors += $errorOutput}
      $recordChanges += 1
    }
    ###^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^###

  }Else{
    If (!($workdayUserFound)){
      #Did not find a matching user among the active or disabled users.
      # Create a new account.
      $output = "Account Creation: Create an acccount for " + $workdayUser.displayName + " (" +  $workdayUser.staffID + ")"
      Write-Output $output

      $userPrincipalName = $workdayUser.userName + "@" + $domainName
      $rndPassword = ([char[]]([char]33..[char]95) + ([char[]]([char]97..[char]126)) + 0..9 | sort {Get-Random})[0..30] -join ''|convertto-securestring -AsPlainText -Force

      #SamAcountName must be 20 characters or less.
      $samAcountName = $workdayUser.userName.subString(0, [System.Math]::Min(20, $workdayUser.userName.Length)) 

      #New-ADUser doesn't support ErrorVariable so we use try, catch
      try
      {
        New-ADUser -Name $workdayUser.userName -DisplayName $workdayUser.displayName -GivenName $workdayUser.givenName -Surname $workdayUser.lastName -SamAccountName $samAcountName -UserPrincipalName $userPrincipalName -EmployeeNumber $workdayUser.staffID -Path $aDActiveAccountsDN -AccountPassword $rndPassword -Enabled $True
      }
      catch
      {
        Write-Error $_.Exception.Message
        $errors += $_.Exception.Message
      }
      Remove-Variable rndPassword -Confirm:$false
      $recordChanges += 1
    }
    ###^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^###
  }

  #Test to see how many changes we're making.  Exit if it exceeds a limit.
  if ($recordChanges -gt $failsafeRecordChangeLimit){
    $output = "Exiting due to reaching failsafeRecordChangeLimit record change limit of " + $failsafeRecordChangeLimit + "."
    Write-Error $output
    $errors += $output
    finalStatusReport
  } 
}
###^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^###


#Disable & rename old accounts
###vvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvv###
ForEach ($key in $aDUsers.keys){
  $adUser = $aDUsers[$key]
  If (($workdayUsers.keys -NotContains $aDUser.employeeNumber) -And ($workdayUsers.keys.Count -gt $minSafeUserCount)){ #Count for sanity check.

    #We won't manage AD user accounts that have 'WorkdayMangaed: false' in their ldap info field.
    $workdayManaged = $true
    if (($aDUser.info) -And (($aDUser.info|ConvertFrom-Json|ConvertTo-HashTable).Keys -Contains 'WorkdayManaged') -And (($aDUser.info|ConvertFrom-Json|ConvertTo-HashTable).WorkdayManaged -eq $False)){
      $workdayManaged = $false
    }

    If($workdayManaged){
      #User found in AD that that does not match any user from Workday.  Disable, Rename, and move it if necessary.

      #Determine if account deactivation is necessary.
      if (!($aDUser.userAccountControl -band 2)){
        #Set this AD user's account to be disabled.
        $output = "Disabling account for AD User: " + $aDUser.displayName + " (" + $aDUser.SID + ") who was found to be active in AD but did not appear in Workday."
        Write-Output $output
        Disable-ADAccount -Identity $aDUser.ObjectGUID -ErrorVariable errorOutput
        if($errorOutput){$errors += $errorOutput}
        $recordChanges += 1
      }

      #Determine if account rename is necessary.
      if (!($aDUser.name -like "$accountDisablePrefix*")){
        $disabledAccountUserName = $accountDisablePrefix + $aDUser.name
        $output = "Renaming AD user '" + $aDUser.name + "' (SID: " + $adUser.SID + ") to '" + $disabledAccountUserName + "' because user did not appear in Workday."
        Write-Output $output
    
        #Build UserPrincipalName
        $userPrincipalName = $disabledAccountUserName + "@" + $domainName
    
        #SamAcountName must be 20 characters or less.
        $samAcountName = $disabledAccountUserName.subString(0, [System.Math]::Min(20, $disabledAccountUserName.Length)) 

        $output = "Setting AD user '" + $aDUser.name + "' (SID: " + $aDUser.SID + ")'s SamAccountName field from '" + $aDUser.name + "' to '" + $samAcountName + "' and field UserPrincipalName from '" + $aDUser.UserPrincipalName + "' to '" + $userPrincipalName + "'."
        Write-Output $output

        Set-AdUser -Identity $aDUser.ObjectGUID -Replace @{SamAccountName=$samAcountName;UserPrincipalName=$userPrincipalName} -ErrorVariable errorOutput
        if($errorOutput){$errors += $errorOutput}
        $recordChanges += 1

        #Name field (CN)
        $output = "Setting AD user '" + $aDUser.name + "' (SID: " + $aDUser.SID + ")'s Name field from '" + $aDUser.Name + "' to '" + $disabledAccountUserName + "'."
        Write-Output $output
        Get-AdUser -Identity $aDUser.ObjectGUID|Rename-Adobject -NewName $disabledAccountUserName -ErrorVariable errorOutput
      }

      #Determine if account move is necessary.
      if (!($aDUser.DistinguishedName -like "*$aDDisabledAccountsDN")){
        $output = "Moving AD user '" + $aDUser.name + "' (SID: " + $adUser.SID + ") to '" + $aDDisabledAccountsDN + "' because the user did not appear in workday."
        Write-Output $output
        Move-ADObject -Identity $aDUser.ObjectGUID -TargetPath $aDDisabledAccountsDN -ErrorVariable errorOutput
        if($errorOutput){$errors += $errorOutput}
        $recordChanges += 1
      }
    }
  }

  #Test to see how many changes we're making.  Exit if it exceeds a failsafe change limit.
  if ($recordChanges -gt $failsafeRecordChangeLimit){
    $output = "Exiting due to reaching failsafeRecordChangeLimit record change limit of " + $failsafeRecordChangeLimit + "."
    Write-Error $output
    $errors += $output
    finalStatusReport
  }
}
###^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^###

#Final error handling
###vvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvv###
finalStatusReport
###^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^###
###^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^###
#####################################################