[CmdletBinding()]
param(
    [PSCredential] $Credential,
    [Parameter(HelpMessage='Tenant ID (This is a GUID which represents the "Directory ID" of the AzureAD tenant into which you want to create the apps')]
    [string] $tenantId
)

<#
 This script creates the Azure AD applications needed for this sample and updates the configuration files
 for the visual Studio projects from the data in the Azure AD applications.

 Before running this script you need to install the AzureAD cmdlets as an administrator. 
 For this:
 1) Run Powershell as an administrator
 2) in the PowerShell window, type: Install-Module AzureAD

 There are four ways to run this script. For more information, read the AppCreationScripts.md file in the same folder as this script.
#>

# Create a password that can be used as an application key
Function ComputePassword
{
    $aesManaged = New-Object "System.Security.Cryptography.AesManaged"
    $aesManaged.Mode = [System.Security.Cryptography.CipherMode]::CBC
    $aesManaged.Padding = [System.Security.Cryptography.PaddingMode]::Zeros
    $aesManaged.BlockSize = 128
    $aesManaged.KeySize = 256
    $aesManaged.GenerateKey()
    return [System.Convert]::ToBase64String($aesManaged.Key)
}

# Create an application key
# See https://www.sabin.io/blog/adding-an-azure-active-directory-application-and-key-using-powershell/
Function CreateAppKey([DateTime] $fromDate, [double] $durationInYears, [string]$pw)
{
    $endDate = $fromDate.AddYears($durationInYears) 
    $keyId = (New-Guid).ToString();
    $key = New-Object Microsoft.Open.AzureAD.Model.PasswordCredential
    $key.StartDate = $fromDate
    $key.EndDate = $endDate
    $key.Value = $pw
    $key.KeyId = $keyId
    return $key
}

# Adds the requiredAccesses (expressed as a pipe separated string) to the requiredAccess structure
# The exposed permissions are in the $exposedPermissions collection, and the type of permission (Scope | Role) is 
# described in $permissionType
Function AddResourcePermission($requiredAccess, `
                               $exposedPermissions, [string]$requiredAccesses, [string]$permissionType)
{
        foreach($permission in $requiredAccesses.Trim().Split("|"))
        {
            foreach($exposedPermission in $exposedPermissions)
            {
                if ($exposedPermission.Value -eq $permission)
                 {
                    $resourceAccess = New-Object Microsoft.Open.AzureAD.Model.ResourceAccess
                    $resourceAccess.Type = $permissionType # Scope = Delegated permissions | Role = Application permissions
                    $resourceAccess.Id = $exposedPermission.Id # Read directory data
                    $requiredAccess.ResourceAccess.Add($resourceAccess)
                 }
            }
        }
}

#
# Exemple: GetRequiredPermissions "Microsoft Graph"  "Graph.Read|User.Read"
# See also: http://stackoverflow.com/questions/42164581/how-to-configure-a-new-azure-ad-application-through-powershell
Function GetRequiredPermissions([string] $applicationDisplayName, [string] $requiredDelegatedPermissions, [string]$requiredApplicationPermissions, $servicePrincipal)
{
    # If we are passed the service principal we use it directly, otherwise we find it from the display name (which might not be unique)
    if ($servicePrincipal)
    {
        $sp = $servicePrincipal
    }
    else
    {
        $sp = Get-AzureADServicePrincipal -Filter "DisplayName eq '$applicationDisplayName'"
    }
    $appid = $sp.AppId
    $requiredAccess = New-Object Microsoft.Open.AzureAD.Model.RequiredResourceAccess
    $requiredAccess.ResourceAppId = $appid 
    $requiredAccess.ResourceAccess = New-Object System.Collections.Generic.List[Microsoft.Open.AzureAD.Model.ResourceAccess]

    # $sp.Oauth2Permissions | Select Id,AdminConsentDisplayName,Value: To see the list of all the Delegated permissions for the application:
    if ($requiredDelegatedPermissions)
    {
        AddResourcePermission $requiredAccess -exposedPermissions $sp.Oauth2Permissions -requiredAccesses $requiredDelegatedPermissions -permissionType "Scope"
    }
    
    # $sp.AppRoles | Select Id,AdminConsentDisplayName,Value: To see the list of all the Application permissions for the application
    if ($requiredApplicationPermissions)
    {
        AddResourcePermission $requiredAccess -exposedPermissions $sp.AppRoles -requiredAccesses $requiredApplicationPermissions -permissionType "Role"
    }
    return $requiredAccess
}


# Replace the value of an appsettings of a given key in an XML App.Config file.
Function ReplaceSetting([string] $configFilePath, [string] $key, [string] $newValue)
{
    [xml] $content = Get-Content $configFilePath
    $appSettings = $content.configuration.appSettings; 
    $keyValuePair = $appSettings.SelectSingleNode("descendant::add[@key='$key']")
    if ($keyValuePair)
    {
        $keyValuePair.value = $newValue;
    }
    else
    {
        Throw "Key '$key' not found in file '$configFilePath'"
    }
   $content.save($configFilePath)
}


Set-Content -Value "<html><body><table>" -Path createdApps.html
Add-Content -Value "<thead><tr><th>Application</th><th>AppId</th><th>Url in the Azure portal</th></tr></thead><tbody>" -Path createdApps.html

Function ConfigureApplications
{
<#.Description
   This function creates the Azure AD applications for the sample in the provided Azure AD tenant and updates the
   configuration files in the client and service project  of the visual studio solution (App.Config and Web.Config)
   so that they are consistent with the Applications parameters
#> 

    # $tenantId is the Active Directory Tenant. This is a GUID which represents the "Directory ID" of the AzureAD tenant
    # into which you want to create the apps. Look it up in the Azure portal in the "Properties" of the Azure AD.

    # Login to Azure PowerShell (interactive if credentials are not already provided:
    # you'll need to sign-in with creds enabling your to create apps in the tenant)
    if (!$Credential -and $TenantId)
    {
        $creds = Connect-AzureAD -TenantId $tenantId
    }
    else
    {
        if (!$TenantId)
        {
            $creds = Connect-AzureAD -Credential $Credential
        }
        else
        {
            $creds = Connect-AzureAD -TenantId $tenantId -Credential $Credential
        }
    }

    if (!$tenantId)
    {
        $tenantId = $creds.Tenant.Id
    }

    $tenant = Get-AzureADTenantDetail
    $tenantName =  ($tenant.VerifiedDomains | Where { $_._Default -eq $True }).Name

    $perm = [Microsoft.Open.AzureAD.Model.RequiredResourceAccess]@{
    ResourceAppId  = "00000002-0000-0000-c000-000000000000"; # Windows Azure Active Directory/Microsoft.Azure.ActiveDirectory
    ResourceAccess = [Microsoft.Open.AzureAD.Model.ResourceAccess]@{
        Id   = "311a71cc-e848-46a1-bdf8-97ff7156d8e6"; #access scope: Delegated permission to sign in and read user profile
        Type = "Scope"
        }
    }
   # Create the service AAD application
   Write-Host "Creating the AAD appplication (TodoListService-AppIdentity)"
   $serviceAadApplication = New-AzureADApplication -DisplayName "TodoListService-AppIdentity" `
                                                   -HomePage "https://localhost:44321/" `
                                                   -IdentifierUris "https://$tenantName/TodoListService-AppIdentity" `
                                                   -RequiredResourceAccess $perm `
                                                   -PublicClient $False


   $currentAppId = $serviceAadApplication.AppId
   $serviceServicePrincipal = New-AzureADServicePrincipal -AppId $currentAppId -Tags {WindowsAzureActiveDirectoryIntegratedApp}

   # add this user as app owner
   $user = Get-AzureADUser -ObjectId $creds.Account.Id
   Add-AzureADApplicationOwner -ObjectId $serviceAadApplication.ObjectId -RefObjectId $user.ObjectId
   Write-Host "'$($user.UserPrincipalName)' added as an application owner to app '$($serviceServicePrincipal.DisplayName)'"

   Write-Host "Done creating the service application (TodoListService-AppIdentity)"

   # URL of the AAD application in the Azure portal
   $servicePortalUrl = "https://portal.azure.com/#@"+$tenantName+"/blade/Microsoft_AAD_IAM/ApplicationBlade/appId/"+$serviceAadApplication.AppId+"/objectId/"+$serviceAadApplication.ObjectId
   Add-Content -Value "<tr><td>service</td><td>$currentAppId</td><td><a href='$servicePortalUrl'>TodoListService-AppIdentity</a></td></tr>" -Path createdApps.html

   # Create the WebApp AAD application
   Write-Host "Creating the AAD appplication (TodoListWebApp-AppIdentity)"
   # Get a 2 years application key for the WebApp Application
   $pw = ComputePassword
   $fromDate = [DateTime]::Now;
   $key = CreateAppKey -fromDate $fromDate -durationInYears 2 -pw $pw
   $WebAppAppKey = $pw
   $WebAppAadApplication = New-AzureADApplication -DisplayName "TodoListWebApp-AppIdentity" `
                                                  -HomePage "https://localhost:44322/" `
                                                  -ReplyUrls "https://localhost:44322/" `
                                                  -IdentifierUris "https://$tenantName/TodoListWebApp-AppIdentity" `
                                                  -PasswordCredentials $key `
                                                  -RequiredResourceAccess $perm `
                                                  -PublicClient $False


   $currentAppId = $WebAppAadApplication.AppId
   $WebAppServicePrincipal = New-AzureADServicePrincipal -AppId $currentAppId -Tags {WindowsAzureActiveDirectoryIntegratedApp}

   # add this user as app owner
   $user = Get-AzureADUser -ObjectId $creds.Account.Id
   Add-AzureADApplicationOwner -ObjectId $WebAppAadApplication.ObjectId -RefObjectId $user.ObjectId
   Write-Host "'$($user.UserPrincipalName)' added as an application owner to app '$($WebAppServicePrincipal.DisplayName)'"

   Write-Host "Done creating the WebApp application (TodoListWebApp-AppIdentity)"

   # URL of the AAD application in the Azure portal
   $WebAppPortalUrl = "https://portal.azure.com/#@"+$tenantName+"/blade/Microsoft_AAD_IAM/ApplicationBlade/appId/"+$WebAppAadApplication.AppId+"/objectId/"+$WebAppAadApplication.ObjectId
   Add-Content -Value "<tr><td>WebApp</td><td>$currentAppId</td><td><a href='$WebAppPortalUrl'>TodoListWebApp-AppIdentity</a></td></tr>" -Path createdApps.html

   $requiredResourcesAccess = New-Object System.Collections.Generic.List[Microsoft.Open.AzureAD.Model.RequiredResourceAccess]
    # Re-add the existing Sign-in and read user profile permission to the collection
    $requiredResourcesAccess.Add($perm)

   # Add Required Resources Access (from 'WebApp' to 'service')
   Write-Host "Getting access from 'WebApp' to 'service'"
   $requiredPermissions = GetRequiredPermissions -applicationDisplayName "TodoListService-AppIdentity" `
                                                 -requiredDelegatedPermissions "user_impersonation";
   $requiredResourcesAccess.Add($requiredPermissions)
   Set-AzureADApplication -ObjectId $WebAppAadApplication.ObjectId -RequiredResourceAccess $requiredResourcesAccess
   Write-Host "Granted ."

   # Update config file for 'service'
   $configFile = $pwd.Path + "\..\TodoListService\Web.Config"
   Write-Host "Updating the sample code ($configFile)"
   ReplaceSetting -configFilePath $configFile -key "ida:Tenant" -newValue $tenantName
   ReplaceSetting -configFilePath $configFile -key "ida:Audience" -newValue $serviceAadApplication.IdentifierUris
   ReplaceSetting -configFilePath $configFile -key "todo:TrustedCallerClientId" -newValue $WebAppAadApplication.AppId

   # Update config file for 'WebApp'
   $configFile = $pwd.Path + "\..\TodoListWebApp\Web.Config"
   Write-Host "Updating the sample code ($configFile)"
   ReplaceSetting -configFilePath $configFile -key "ida:Tenant" -newValue $tenantName
   ReplaceSetting -configFilePath $configFile -key "ida:ClientId" -newValue $WebAppAadApplication.AppId
   ReplaceSetting -configFilePath $configFile -key "ida:RedirectUri" -newValue $WebAppAadApplication.ReplyUrls
   ReplaceSetting -configFilePath $configFile -key "ida:AppKey" -newValue $WebAppAppKey
   ReplaceSetting -configFilePath $configFile -key "todo:TodoListResourceId" -newValue $serviceAadApplication.IdentifierUris
   ReplaceSetting -configFilePath $configFile -key "todo:TodoListBaseAddress" -newValue $serviceAadApplication.HomePage

   Add-Content -Value "</tbody></table></body></html>" -Path createdApps.html  
}


# Run interactively (will ask you for the tenant ID)
ConfigureApplications -Credential $Credential -tenantId $TenantId