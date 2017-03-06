<#
.SYNOPSIS
    Clones Azure V2 (ARM) resources from one resource group into a new resource group in the same Azure Subscriptions 
    
    
.DESCRIPTION
   Copies configurations of a resource group into a new one
   This is intended mostly for Azure V2 virtual machines and will include copying virtual disks, virtual
   network, load balancers, Public IPs and other associated storage accounts and blob files.

   
  Due to uniqueness requirements DNS names of source and targets, the following renaming occurs during reprovisioning
  ** Storage accounts will be renamed by appending an 8 character GUID to the original storage account name
  ** DNS Labels on Public IPs will be renamed by appending 'new' to the DNS name



.EXAMPLE
   .\Clone-AzureRMresourceGroup.ps1 -ResourceGroupName 'CONTOSO' -NewResourceGroupName 'NEWCONTOSO'

   Clones Resource Group CONTOSO as new resource group NEWCONTOSO into the same subscription, in the same location/region and environment

.EXAMPLE
   .\Clone-AzureRMresourceGroup.ps1 -ResourceGroupName 'CONTOSO' -NewResourceGroupName 'NEWCONTOSO' -NewLocation 'westus' -resume 

   Clones Resource Group CONTOSO as new resource group NEWCONTOSO in new location West US

.EXAMPLE
   .\Clone-AzureRMresourceGroup.ps1 -ResourceGroupName 'CONTOSO' -NewResourceGroupName 'NEWCONTOSO' -Environment 'AzureUSGovernment'

   Clones Resource Group CONTOSO as resource group NEWCONTOSO in Azure Government



.PARAMETER -ResourceGroupName [string]
  Name of resource group being copied

.PARAMETER -NewResourceGroupName [string]
  Name of resource group being created

.PARAMETER -NewLocation [string]
  Name of Azure location of new resource group

.PARAMETER -Environment [string]
  Name of the Environment. e.g. AzureUSGovernment. Defaults to AzureCloud

.PARAMETER -resume [switch]
  Resumes after the file copy


.NOTES

    Original Author:   https://github.com/JeffBow
    
 ------------------------------------------------------------------------
               Copyright (C) 2016 Microsoft Corporation

 You have a royalty-free right to use, modify, reproduce and distribute
 this sample script (and/or any modified version) in any way
 you find useful, provided that you agree that Microsoft has no warranty,
 obligations or liability for any sample application or script files.
 ------------------------------------------------------------------------
#>
#Requires -Version 4.0
#Requires -Module AzureRM.Profile
#Requires -Module AzureRM.Resources
#Requires -Module AzureRM.Storage
#Requires -Module AzureRM.Compute
#Requires -Module AzureRM.Network

param(

    [Parameter(Mandatory=$true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory=$true)]
    [string]$NewResourceGroupName,

    [Parameter(Mandatory=$false)]
    [string]$NewLocation,

    [Parameter(Mandatory=$false)]
    [string]$Environment,

    [Parameter(Mandatory=$false)]
    [switch]$resume


)

$resourceGroupVmResumePath = "$env:TEMP\$resourcegroupname.resourceGroupVMs.resume.json"
$VHDstorageObjectsResumePath = "$env:TEMP\$resourcegroupname.VHDstorageObjects.resume.json"
$jsonBackupPath = "$env:TEMP\$resourcegroupname.json"
$ProgressPreference = 'SilentlyContinue'

if ((Get-Module AzureRM.profile).Version -lt "2.1.0") {
   Write-warning "Old Version of Azure Modules  $((Get-Module AzureRM.profile).Version.ToString()) detected.  Minimum of 2.1.0 required. Run Update-AzureRM"
   BREAK
}


<###############################
 Get Storage Context function
################################>
function Get-StorageObject 
{ param($resourceGroupName, $srcURI) 
    
    $split = $srcURI.Split('/')
    $strgDNS = $split[2]
    $splitDNS = $strgDNS.Split('.')
    $storageAccountName = $splitDNS[0]
    # add uri and storage account name to custom PSobject
    $PSobjSourceStorage = New-Object -TypeName PSObject
    $PSobjSourceStorage | Add-Member -MemberType NoteProperty -Name srcStorageAccount -Value $storageAccountName  
    $PSobjSourceStorage | Add-Member -MemberType NoteProperty -Name srcURI -Value $srcURI 
    # retrieve storage account key and storage context
    $StorageAccountKey = (Get-AzureRmStorageAccountKey -ResourceGroupName $resourceGroupName -AccountName $StorageAccountName).Value[0]
    $StorageContext = New-AzureStorageContext -StorageAccountName $StorageAccountName -StorageAccountKey $StorageAccountKey
    # add storage context to psObject
    $PSobjSourceStorage | Add-Member -MemberType NoteProperty -Name SrcStorageContext -Value $StorageContext 
    # get storage account and add other attributes to psCustom object
    $storageAccount = Get-AzureRmStorageAccount -ResourceGroupName $resourceGroupName -Name $storageAccountName
    $PSobjSourceStorage | Add-Member -MemberType NoteProperty -Name SrcStorageEncryption -Value $storageAccount.Encryption
    $PSobjSourceStorage | Add-Member -MemberType NoteProperty -Name SrcStorageCustomDomain -Value $storageAccount.CustomDomain
    $PSobjSourceStorage | Add-Member -MemberType NoteProperty -Name SrcStorageKind -Value $storageAccount.Kind
    $PSobjSourceStorage | Add-Member -MemberType NoteProperty -Name SrcStorageAccessTier -Value $storageAccount.AccessTier
    # get storage account sku and convert to string that is required for creation
    $skuName = $storageAccount.sku.Name
 
    switch ($skuName) 
        { 
            'StandardLRS'   {$skuName = 'Standard_LRS'} 
            'StandardZRS'   {$skuName = 'Standard_ZRS'} 
            'StandardGRS'   {$skuName = 'Standard_GRS'} 
            'StandardRAGRS'{$skuName = 'Standard_RAGRS'} 
            'PremiumLRS'   {$skuName = 'Premium_LRS'} 
            default {$skuName = 'Standard_LRS'}
        }
     
     $PSobjSourceStorage | Add-Member -MemberType NoteProperty -Name SrcSkuName -Value $skuName
    
    return $PSobjSourceStorage

} # end of Get-StorageObject function



<###############################
  get available resources function
################################>
function get-availableResources
{ param($resourceType, $location)

    $resource = Get-AzureRmVMUsage -Location $location | where{$_.Name.value -eq $resourceType}
    [int32]$availabe = $resource.limit - $resource.currentvalue
    return $availabe 

}


<###############################
  Copy blob function
################################>
function copy-azureBlob 
{  param($srcUri, $srcContext, $destContext, $containerName)


    $split = $srcURI.Split('/')
    $blobName = $split[($split.count -1)]
    $blobSplit = $blobName.Split('.')
    $extension = $blobSplit[($blobSplit.count -1)]
    if($($extension.tolower()) -eq 'status' ){Write-Output "Status file blob $blobname skipped";return}

    if(! $containerName){$containerName = $split[3]}

    # add full path back to blobname 
    if($split.count -gt 5) 
      { 
        $i = 4
        do
        {
            $path = $path + "/" + $split[$i]
            $i++
        }
        while($i -lt $split.length -1)

        $blobName= $path + '/' + $blobName
        $blobName = $blobName.Trim()
        $blobName = $blobName.Substring(1, $blobName.Length-1)
      }
    
    
   # create container if doesn't exist    
    if (!(Get-AzureStorageContainer -Context $destContext -Name $containerName -ea SilentlyContinue)) 
    { 
         try
         {
            $newRtn = New-AzureStorageContainer -Context $destContext -Name $containerName -Permission Off -ea Stop 
            Write-Output "Container $($newRtn.name) was created." 
         }
         catch
         {
             $_ ; break
         }
    } 


   try 
   {
        $blobCopy = Start-AzureStorageBlobCopy -ea Stop `
            -srcUri $srcUri `
            -SrcContext $srcContext `
            -DestContainer $containerName `
            -DestBlob $blobName `
            -DestContext $destContext 

         write-output "$srcUri is being copied to $containerName"
    
   }
   catch
   { 
      $_ ; write-warning "Failed to copy to $srcUri to $containerName"
   }
  

} # end of copy-azureBlob function




<###############################

 Read resource group from old Sub

################################>

# Verify specified Environment
if($Environment -and (Get-AzureRMEnvironment -Name $Environment) -eq $null)
{
   write-warning "The specified -Environment could not be found. Specify one of these valid environments."
   $Environment = (Get-AzureRMEnvironment | select Name, ManagementPortalUrl | Out-GridView -title "Select a valid Azure environment for your subscription" -OutputMode Single).Name
}

# get Azure creds for source
write-host "Enter credentials for your Azure Subscription..." -f Yellow
if($Environment)
{
   $login= Login-AzureRmAccount -EnvironmentName $Environment
}
else
{
   $login= Login-AzureRmAccount 
} 
$loginID = $login.context.account.id
$sub = Get-AzureRmSubscription -TenantID $login.context.Subscription.TenantID
$SubscriptionId = $sub.SubscriptionId

# check for multiple subs under same account and force user to pick one
if($sub.count -gt 1) 
{
    $SubscriptionId = (Get-AzureRmSubscription | select * | Out-GridView -title "Select Target Subscription" -OutputMode Single).SubscriptionId
    Select-AzureRmSubscription -SubscriptionId $SubscriptionId | Out-Null
    $sub = Get-AzureRmSubscription -SubscriptionId $SubscriptionId
}

   

# check for valid sub
if(! $SubscriptionId) 
{
   write-warning "The provided credentials failed to authenticate or are not associcated to a valid subscription. Exiting the script."
   break
}

write-host "Logged into $($sub.SubscriptionName) with subscriptionID $SubscriptionId as $loginID" -f Green

# check for valid source resource group
if(-not ($sourceResourceGroup = Get-AzureRmResourceGroup  -ResourceGroupName $resourceGroupName)) 
{
   write-warning "The provided resource group $resourceGroupName could not be found. Exiting the script."
   break
}

if(! $resume)
{

# create export JSON for backup purposes
$RGexport = Export-AzureRmResourceGroup -ResourceGroupName $resourceGroupName -Path $jsonBackupPath -IncludeParameterDefaultValue -Force -wa SilentlyContinue



# get configuration details for different resources
[string] $location = $sourceResourceGroup.location
$resourceGroupStorageAccounts = Get-AzureRmStorageAccount -ResourceGroupName $resourceGroupName
$resourceGroupVirtualNetworks = Get-AzureRmVirtualNetwork -ResourceGroupName $resourceGroupName
$resourceGroupNICs = Get-AzureRmNetworkInterface -ResourceGroupName $resourceGroupName
$resourceGroupNSGs = Get-AzureRmNetworkSecurityGroup -ResourceGroupName $resourceGroupName
$resourceGroupAvSets = Get-AzureRmAvailabilitySet -ResourceGroupName $resourceGroupName 
$resourceGroupVMs = Get-AzureRMVM -ResourceGroupName $resourceGroupName
$resourceGroupPIPs = Get-AzureRmPublicIpAddress -ResourceGroupName $resourceGroupName
$resourceGroupNICs = Get-AzureRmNetworkInterface -ResourceGroupName $resourceGroupName
$resourceGroupLBs = Get-AzureRmLoadBalancer -ResourceGroupName $resourceGroupName
if(! $resourceGroupVMs){write-warning "No virtual machines found in resource group $resourceGroupName"; break}



# display what we found
write-host "The following items will be copied:" -f DarkGreen
write-host "Storage Accounts:" -f DarkGreen
$resourceGroupStorageAccounts.StorageAccountName
write-host "Virtual Machines:" -f DarkGreen
$resourceGroupVMs.name
write-host "Operating system disks:" -f DarkGreen
$resourceGroupVMs.storageProfile.osdisk.name
write-host "Data disks:" -f DarkGreen
$resourceGroupVMs.datadisknames
# check to make sure VMs are not running
write-host "Current status of VMs:" -f DarkGreen
$resourceGroupVMs | %{
   $status = ((get-azurermvm -ResourceGroupName $resourceGroupName -Name $_.name -status).Statuses|where{$_.Code -like 'PowerState*'}).DisplayStatus
   write-output "$($_.name) status is $status" 
   if($status -eq 'VM running'){write-warning "All virtual machines in this resource group are not stopped.  Please stop all VMs and try again"; break}
}

write-host "Virtual networks:" -f DarkGreen
$resourceGroupVirtualNetworks.name
write-host "Network Security Groups:" -f DarkGreen
$resourceGroupNSGs.name
write-host "Load Balancers:" -f DarkGreen
$resourceGroupLBs.name
write-host "Public IPs:" -f DarkGreen
$resourceGroupPIPs.name



# create array of custom PSobjects that contain storage account details and security context for each VHD that is found
# this is consumed later during the copy process after you log into the target subscription
[array]$sourceVHDstorageObjects = $()
write-verbose "Retrieving storage context for each source blob" -Verbose

foreach($vm in $resourceGroupVMs) 
{
    # get storage account name from VM.URI
    $vmURI = $vm.storageprofile.osdisk.vhd.uri
    $obj = $null
    $obj = Get-StorageObject -resourceGroupName $resourceGroupName -srcURI $vmURI
    [array]$sourceVHDstorageObjects += $obj 
    
    if($vm.storageProfile.datadisks)
    {
       foreach($disk in $vm.storageProfile.datadisks) 
       {
         $diskURI = $disk.vhd.uri
         $obj = $null
         $obj = Get-StorageObject -resourceGroupName $resourceGroupName -srcURI $diskURI
         [array]$sourceVHDstorageObjects += $obj
       }
    }
}

[array]$sourceStorageObjects = $()
#get any storage accounts and blobs that were not VHDs attached to VMs
foreach($sourceStorageAccount in $resourceGroupStorageAccounts)
{ 
  $sourceStorageAccountName = $sourceStorageAccount.StorageAccountName
  $sourceStorageAccountKey = (Get-AzureRmStorageAccountKey -ResourceGroupName $resourceGroupName -AccountName $sourceStorageAccountName).Value[0]
  $sourceStorageContext = New-AzureStorageContext -StorageAccountName $sourceStorageAccountName -StorageAccountKey $sourceStorageAccountKey 
  $sourceStorageContainers = Get-AzureStorageContainer -Context $sourceStorageContext
  foreach($container in $sourceStorageContainers)
  {
    $blobs = Get-AzureStorageBlob -Container $container.name -Context $sourceStorageContext

    foreach($blob in $blobs) 
    {
      # get storage account details from uri
      $URI = $blob.ICloudBlob.uri.Absoluteuri
      # only add to sourceStorageObjects if it isn't in sourceVHDstorageObjects - must do replace to adapt to absoluteURI
      if($sourceVHDstorageObjects.srcURI -notcontains ($URI.replace('https','http')) -and $sourceVHDstorageObjects.srcURI -notcontains $URI)
      {
        $obj = $null
        $obj = Get-StorageObject -resourceGroupName $resourceGroupName -srcURI $URI
        [array]$sourceStorageObjects += $obj 
      }
    }
  }
}

write-host "Additional storage blobs:" -f DarkGreen
$sourceStorageObjects.srcURI








    <###############################

    Create new Resource Group 

    ################################>

    $ResourceGroupName = $NewResourceGroupName

    <###############################
     Verify Location
    ################################>

    if($NewLocation)
    {
        $location = $NewLocation

        Write-Output "Verifying specified location: $location ..."
        # Prompt for location if provided location doesn't exist in current environment.
        $location = (Get-AzureRMlocation | where { $_.Providers -eq 'Microsoft.Compute' -and ( $_.DisplayName -like $location -or $_.location -like $location)}).DisplayName
        if(! $location) 
        {
            write-warning "$NewLocation is an invalid Azure Resource Group location for this environment.  Please select a valid location and click OK"
            $location = (Get-AzureRMlocation | where { $_.Providers -eq 'Microsoft.Compute'} | Select DisplayName, Providers | Out-GridView -Title "Select Azure Resource Group Location" -OutputMode Single).DisplayName
        }
    }

    <###############################
     Verify Available Resources 
    ################################>

    foreach ($vmSize in ($resourceGroupVMs.hardwareprofile.vmsize))
    {
     $cores = $null
     $cores = (Get-AzureRmVMSize -Location $location | where{$_.Name -eq $vmSize}).NumberOfCores
 
     $totalCoresNeeded = $cores + $totalCoresNeeded
    }


    $TotalAvailabeVMs = Get-availableResources -ResourceType 'virtualMachines' -Location $location
    if($resourceGroupVMs.count -gt $TotalAvailabeVMs){Write-Warning "Insufficent available VMs in location $location. Script halted."; break}

    $TotalAvailabeCores = Get-availableResources -ResourceType 'cores' -Location $location
    if($totalCoresNeeded -gt $TotalAvailabeCores){Write-Warning "Insufficent available cores in location $location. Script halted."; break}
    

    $TotalAvailabeAVs = Get-availableResources -ResourceType 'availabilitySets' -Location $location
    if($resourceGroupAvSets.count -gt $TotalAvailabeAVs){Write-Warning "Insufficent Availability Sets in location $location. Script halted."; break}
   


    <###############################
     Validate and create new resource group  
    ################################>
    do 
    {
        $RGexists = $null
        try
        {
            $RGexists = Get-AzureRmResourceGroup -Name $ResourceGroupName -ea stop
        }
        catch{}
        
        if($RGexists) 
        {
            write-warning "$ResourceGroupName already exists." 
            $ResourceGroupName = read-host   'Enter a different Resource Group Name'
        }  
    }
    while($RGexists)

    try
    {
        write-verbose "Creating new resource group $resourceGroupName in $location" -Verbose
        $NewResourceGroup  = New-AzureRmResourceGroup -Name $ResourceGroupName -Location $location -ea Stop -wa SilentlyContinue
        write-output "The resource group $resourceGroupName was created in subscription $($sub.SubscriptionName)"
    }
    catch
    {
        $_
        write-warning "The resource group $resourceGroupName was not created. Exiting the script."
        break
    }



<###############################

 Create new destination storage accounts
 and copy blobs
 
 ################################>


    # initialize array to store new destination storage account names relative to srcURI
    [array]$VHDstorageObjects = @()

    # get all the unique source storage accounts from custom psobject
    $srcStorageAccountNames = $sourceStorageObjects | Select-Object -Property srcStorageAccount -Unique

    $VHDsrcStorageAccounts = $sourceVHDstorageObjects| Select-Object -Property srcStorageAccount -Unique
    
    # add the VHD storage accounts to $sourceStorageObjects if they're not there already
    foreach($VHDsrcStorageAccountObj in $VHDsrcStorageAccounts)
    {
        $VHDsrcStorageAccountName = $VHDsrcStorageAccountObj.srcStorageAccount
        if($srcStorageAccountNames.srcStorageAccount -notcontains $VHDsrcStorageAccountName )
        {
            [array]$sourceStorageObjects += $sourceVHDstorageObjects|where{$_.srcStorageAccount -eq $VHDsrcStorageAccountName}
        }
    }

    $srcStorageAccounts = $sourceStorageObjects | Select-Object -Property srcStorageAccount -Unique

    # process each source storage account - creating new destination storage account from old account name
    foreach($srcStorageAccountObj in $srcStorageAccounts)
    {
        $srcStorageAccount = $srcStorageAccountObj.srcStorageAccount
        # create unique storage account name from old account name and guid
        if($srcStorageAccount.Length -gt 16){$first16 = $srcStorageAccount.Substring(0,16)}else{$first16 = $srcStorageAccount}
        [string] $guid = (New-Guid).Guid
        [string] $DeststorageAccountName = "$($first16.ToLower())"+($guid.Substring(0,8))

        # select sku and other attributes
        $skuName = ($sourceStorageObjects | where{$_.srcStorageAccount -eq $srcStorageAccount} | Select-Object -Property srcSkuName -Unique).srcSkuName
        $Encryption = ($sourceStorageObjects | where{$_.srcStorageAccount -eq $srcStorageAccount} | Select-Object -Property SrcStorageEncryption -Unique).SrcStorageEncryption
        $CustomDomain = ($sourceStorageObjects | where{$_.srcStorageAccount -eq $srcStorageAccount} | Select-Object -Property SrcStorageCustomDomain -Unique).SrcStorageCustomDomain
        $kind = ($sourceStorageObjects | where{$_.srcStorageAccount -eq $srcStorageAccount} | Select-Object -Property SrcStorageKind -Unique).SrcStorageKind
        $AccessTier = ($sourceStorageObjects | where{$_.srcStorageAccount -eq $srcStorageAccount} | Select-Object -Property SrcStorageAccessTier -Unique).SrcStorageAccessTier
        
        $storageParams = @{
        "ResourceGroupName" = $resourceGroupName 
        "AccountName" = $DeststorageAccountName 
        "location" = $location
        "SkuName" = $skuName
        }

        # add AccessTier if kind is BlobStorage.
        if($kind -ne 'Storage') 
        {
            $storageParams.Add("Kind", $kind)
            $storageParams.Add("AccessTier", $accessTier)
        }

        # add CustomDomainName if present.
        if($CustomDomain) 
        {
            $storageParams.Add("CustomDomainName", $CustomDomain)
        }

        # add CustomDomainName if present.
        if($Encryption) 
        {
            $storageParams.Add("EnableEncryptionService", $Encryption)
        }
        

        # Create new storage account
        do 
        {
            try
            {
                # create new storage account
                write-verbose "Creating storage account $DeststorageAccountName in resource group $resourceGroupName at location $location" -verbose
                $newStorageAccount = New-AzureRmStorageAccount @storageParams -ea Stop -wa SilentlyContinue 
                write-output "The storage account $DeststorageAccountName was created"
            }
            catch
            {
                $_
                write-warning "Failed to create storage account. Storage account name $DeststorageAccountName may already exists."
                $DeststorageAccountName = read-host   'Enter a different Destination Storage Account Name'
            }
        }
        while(! $newStorageAccount)


        try 
        {
            # get key and storage context of newly created storage account
            $DestStorageAccountKey = (Get-AzureRmStorageAccountKey -ResourceGroupName $resourceGroupName -AccountName $DestStorageAccountName -ea Stop).Value[0] 
            $DestStorageContext = New-AzureStorageContext -StorageAccountName $DestStorageAccountName -StorageAccountKey $DestStorageAccountKey -ea Stop -wa SilentlyContinue
        }
        catch 
        {
            write-warning "Could not retrieve storage account key or storage context for $DestStorageAccountName . Exiting the script."
            break
        }



        # start blob copy for VHDs attached to VMs        
        foreach($obj in $sourceVHDstorageObjects | where{$_.srcStorageAccount -eq $srcStorageAccount})
        { 
            $srcURI = $obj.srcURI

            copy-azureBlob -srcUri $srcURI -srcContext $obj.SrcStorageContext -destContext $DestStorageContext
            #copy-azureBlob -srcUri $srcURI -srcContext $obj.SrcStorageContext -destContext $DestStorageContext -containerName 'vhd-backup'
            
            # add srcURI and destination storage account name to custom PSobject
            $PSobjVHDstorage = New-Object -TypeName PSObject
            $PSobjVHDstorage | Add-Member -MemberType NoteProperty -Name destStorageContext -Value $DestStorageContext  
            $PSobjVHDstorage | Add-Member -MemberType NoteProperty -Name srcURI -Value $srcURI 

            [array]$VHDstorageObjects += $PSobjVHDstorage
        }
    
        
        # start copy for remaining blobs           
        if($srcStorageAccountNames)
        {
            foreach($obj in $sourceStorageObjects | where{$_.srcStorageAccount -eq $srcStorageAccount})
            {
                copy-azureBlob -srcUri $obj.srcURI -srcContext $obj.SrcStorageContext -destContext $DestStorageContext 
            }
        }   


    }


<###############################

 Create new network resources.  
 Vnets, NICs, Loadbalancers, PIPs

################################>

     # create new Network Security Groups
    foreach($srcNSG in $resourceGroupNSGs)
    {
        $nsgName = $srcNSG.name
        [array]$nsgRules = @()
       
        foreach($nsgRule in $srcNSG.SecurityRules)
        {
           
            $nsgRuleParams = @{
                "Name" = $nsgRule.Name  
                "Access" = $nsgRule.Access
                "Protocol" = $nsgRule.Protocol 
                "Direction" = $nsgRule.Direction 
                "Priority" = $nsgRule.Priority 
                "SourceAddressPrefix" = $nsgRule.SourceAddressPrefix 
                "SourcePortRange" =  $nsgRule.SourcePortRange 
                "DestinationAddressPrefix" = $nsgRule.DestinationAddressPrefix 
                "DestinationPortRange" = $nsgRule.DestinationPortRange
            }

            if($nsgRule.Description)
            {
                $nsgRuleParams.Add("Description", $nsgRule.Description)
            }

           $nsgRules += New-AzureRmNetworkSecurityRuleConfig @nsgRuleParams
        }
    

        try
        {
            write-verbose "Creating Network Security Group $nsgName in resource group $resourceGroupName at location $location" -verbose
           $NSG = New-AzureRmNetworkSecurityGroup -Name $nsgName -SecurityRules $nsgRules  -ResourceGroupName $ResourceGroupName -Location $location  -ea Stop -wa SilentlyContinue
            Write-Output "Network Security Group $nsgName was created"
        }
        catch
        {
            $_
            write-warning "Failed to create Network Security Group $nsgName"
        }
    }

    # create new Virtual Network(s)
    foreach($srcNetwork in $resourceGroupVirtualNetworks)
    {
        $destVNname = $srcNetwork.Name
        write-output "Creating virtual network $destVNname in resource group $resourceGroupName at location $location" -verbose
        $destAddressPrefix = $srcNetwork.AddressSpace.AddressPrefixes
        $destDNSserver = $srcNetwork.DhcpOptions.DnsServers
        $destSubnets = $srcNetwork.Subnets
        try
        {
            write-verbose "Creating virtual network $destVNname in resource group $resourceGroupName at location $location" -verbose
            $newVirtualNetwork = New-AzureRmVirtualNetwork -Name $destVNname -ResourceGroupName $resourceGroupName -Location $location -AddressPrefix $destAddressPrefix -DnsServer $destDNSserver -Subnet $destSubnets -Force -ea Stop -wa SilentlyContinue
            Write-Output "Virtual Network $destVNname was created"
        }
        catch
        {
            $_
            write-warning "Failed to create virtual network $destVNname"
        }

        foreach($destSub in $destSubnets) 
         {         
            if($destSub.Subnets.NetworkSecurityGroup)
            {   
                try
                {
                    $NSGsplit = $destSub.Subnets.NetworkSecurityGroup.id.split('/')
                    $srcNSGname = $NSGsplit[$NSGsplit.Length -1]
                    $NSG = Get-AzureRmNetworkSecurityGroup -Name $srcNSGname -ResourceGroupName $ResourceGroupName -ea Stop
                    $subnet = $newVirtualNetwork | Get-AzureRmVirtualNetworkSubnetConfig  -Name $destSub.Name -ea Stop -wa SilentlyContinue
                    Set-AzureRmVirtualNetworkSubnetConfig -VirtualNetwork $newVirtualNetwork -Name $destSub.Name -AddressPrefix $subnet.AddressPrefix -NetworkSecurityGroup $NSG | Set-AzureRmVirtualNetwork -ea Stop | out-null
                }
                catch
                {
                    $_
                    write-warning "Failed to add Network Security Group $srcNSGname to $($destSub.Name)"
                }
             }
          
        }
    }


    # create new Availability sets
    foreach($srcAVset in $resourceGroupAvSets)
    {
        $AVName = $srcAVset.name
        try
        {
        write-verbose "Creating availability set $AVname in resource group $resourceGroupName at location $location" -verbose
        $NewAvailabilitySet = New-AzureRmAvailabilitySet -Name $AVName -ResourceGroupName $resourceGroupName  -Location $location -ea Stop -wa SilentlyContinue
        Write-Output "Availability Set $AVname was created"
        }
        catch
        {
        $_
        write-warning "Failed to create availability set $AVname"
        } 
    }




    # create new PIPs
    foreach($srcPIP in $resourceGroupPIPs)
    {
        $pipName = $srcPIP.name
        $pipDomainNameLabel = $srcPIP.dnssettings.domainNameLabel
        # append 'new' to name so it is unique from existing
        $NewPipDomainNameLabel = $pipDomainNameLabel + 'new'
        $AllocationMethod = $srcPIP.PublicIpAllocationMethod
        try
        {
            write-verbose "Creating public IP $pipName in resource group $resourceGroupName at location $location" -verbose
            $PIP = New-AzureRmPublicIpAddress -Name $pipName -DomainNameLabel $NewPipDomainNameLabel  -ResourceGroupName $ResourceGroupName -Location $location -AllocationMethod $AllocationMethod -ea Stop -wa SilentlyContinue
            Write-Output "Public IP $pipName was created with DomainName Label $NewPipDomainNameLabel"
        }
        catch
        {
            $_
            write-warning "Failed to create Public IP $pipName"
        }
    }


   
    # create new Load Balancer
    foreach($srcLB in $resourceGroupLBs)
    {
        $LBName = $srcLB.name
        $LBFrontendIpConfigurations = $srcLB.FrontendIpConfigurations
        $LBInboundNatRules = $srcLB.InboundNatRules
        $LBBackendAddressPool = $srcLB.BackendAddressPools
        $LBProbe = $srcLB.Probes
        $LoadBalancingRule = $srcLB.LoadBalancingRules
        $LBInboundNatPool = $srcLB.InboundNatPools
        $subnet = $null
        $vnet = $null

        # add IP Configs
        [array]$newLBipConfigs = @()

        foreach($LBipConfig in $LBFrontendIpConfigurations) 
        {
            $newLBipConfig = $null
              
            $LBipConfigName =  $LBipConfig.name
            $lbConfigParams = @{"Name"= $LBipConfigName} 

            # get new vnet and subnet from old vnet and subnet names
            if($LBipConfig.Subnet) 
            {
                $subsplit = $LBipConfig.Subnet.id.split('/')
                $subnetName = $subsplit[$subsplit.Length -1]
                $vnetName = $subsplit[$subsplit.Length -3]
                $subnet = $null
                $vnet = $null
                try
                {
                  $vnet = Get-AzureRmVirtualNetwork -name $vnetName -ResourceGroupName $resourceGroupName -ea Stop -wa SilentlyContinue
                  $subnet = $vnet | Get-AzureRmVirtualNetworkSubnetConfig  -Name $subnetName -ea Stop -wa SilentlyContinue
                }
                catch{}

                $lbConfigParams.Add("SubnetId", $subnet.id)
            }

            # add PublicIpAddress if present.
            if($LBipConfig.PublicIpAddress) 
            {
                $lbPubIPSplit = $LBipConfig.PublicIpAddress.id.split('/')
                $lbPubIPName = $lbPubIPSplit[$lbPubIPSplit.Length -1]
            
                try
                {
                  $lbPubIP = Get-AzureRmPublicIpAddress -Name $lbPubIPName -ResourceGroupName $resourceGroupName -ea Stop -wa SilentlyContinue
                }
                catch{}
                
                if($lbPubIP)
                {
                  $lbConfigParams.Add("PublicIpAddress", $lbPubIP) 
                }
            }
            
            if($LBipConfig.PrivateIpAddress) 
            {
              $lbConfigParams.Add("PrivateIpAddress", $LBipConfig.PrivateIpAddress)  
            }   


            #create  new FrontendIPConfig
            try
              {
                write-verbose "Adding IP config $LBipConfigName to load balancer $lbName" -verbose
                $newLBipConfig = New-AzureRmLoadBalancerFrontendIpConfig @lbConfigParams -ea Stop -wa SilentlyContinue 
                Write-Output "IP config $LBipConfigName for $lbName was added"
              }
              catch
              {
                $_
                write-warning "Failed to add IP config $LBipConfigName to load balancer $lbName"
              } 
                    
             # add other attributes
            if($LBipConfig.PrivateIpAllocationMethod) 
            {
              $newLBipConfig.PrivateIpAllocationMethod = $LBipConfig.PrivateIpAllocationMethod 
            }

             # add InboundNATruleConfigs
            if($newLBipConfig -and $LBipConfig.InboundNatRules)
            {
                foreach($InboundNatRuleID in $LBipConfig.InboundNatRules.ID) 
                {
                    $newNatRuleConfig = $null
                    $InboundNatRule = $LBInboundNatRules | where{$_.ID -eq $InboundNatRuleID}
                    
                    $inboundNatRuleParams = @{
                        "Name" = $InboundNatRule.name
                        "FrontendIpConfiguration" = $newLBipConfig
                        "Protocol" = $InboundNatRule.Protocol
                        "FrontendPort" = $InboundNatRule.FrontEndPort
                        "BackendPort" = $InboundNatRule.BackendPort
                    }

                    if($InboundNatRule.EnableFloatingIP)
                    {
                        $inboundNatRuleParams.Add("EnableFloatingIP", $null)
                    }
                    
                    $newNatRuleConfig = New-AzureRmLoadBalancerInboundNatRuleConfig @inboundNatRuleParams  
                        
                    if($newNatRuleConfig)
                    {
                    [array]$newNatRuleConfigs +=  $newNatRuleConfig
                    }
               }
            }

            if($newLBipConfig)
            {
     
              [array]$newLBipConfigs +=  $newLBipConfig 
            }


        }

        $LBparams = @{
        "Name" = $LBName 
        "ResourceGroupName" = $resourceGroupName
        "Location" = $location 
        }

        if($newLBipConfigs)
        {
         $LBparams.Add("FrontendIpConfiguration", $newLBipConfigs)
        }

        if($newNatRuleConfigs)
        {
         $LBparams.Add("InboundNatRule", $newNatRuleConfigs)
        }
         
        try
        {
            write-verbose "Creating load balancer $LBName in resource group $resourceGroupName at location $location" -verbose
            $NewLB = New-AzureRmLoadBalancer @LBparams -ea Stop -wa SilentlyContinue
            Write-Output "Load balancer $LBName was created"
        }
        catch
        {
            $_
            write-warning "Failed to create load balancer $LBName"
        } 

               
            
        if($LBBackendAddressPool -and $NewLB) 
        {
            $NewLB | Add-AzureRmLoadBalancerBackendAddressPoolConfig -Name $LBBackendAddressPool.Name -ea Stop -wa SilentlyContinue | out-null
        }
        
        if($LBProbe -and $NewLB) 
        {
            # TODO:        
            #   $NewLB | Add-AzureRmLoadBalancerProbeConfig -Name $LBProbe.Name  -RequestPath -Protocol -Port -IntervalInSeconds -ProbeCount | out-null
        }
        
            
        if($LoadBalancingRule -and $NewLB) 
        {
            # TODO:
            #$NewLB | Add-AzureRmLoadBalancerRuleConfig -Name $LoadBalancingRule.Name -ea Stop -wa SilentlyContinue | out-null
        }

        if($LBInboundNatPool -and $NewLB) 
        {
            # TODO:
            # $NewLB |Add-AzureRmLoadBalancerInboundNatPoolConfig -Name $LBInboundNatPool.Name  -ea Stop -wa SilentlyContinue | out-null
        }  
            
        if($NewLB) 
        {    
            try
            {
                $NewLB | Set-AzureRmLoadBalancer -ea Stop -wa SilentlyContinue | out-null
            }
            catch
            {
                $_
                write-warning "Failed to update load balancer $LBName"
                $NewLB
            }
        }
        
    } # end of foreach loadbalancer



    # create new NICs
    foreach($srcNIC in $resourceGroupNICs)
    {
        $NicName = $srcNIC.name
        $oldIPconfigs = $srcNIC.IpConfigurations
        $NicDNS = $srcNIC.DnsSettings.AppliedDnsServers

        # add IP Configs
        [array]$NewIpConfigs = @()

        foreach($ipConfig in $oldIPconfigs) 
        {

            $ipConfigName =  $ipConfig.name

            # get new vnet and subnet from old vnet and subnet names
            if($ipconfig.Subnet)
            {
                $subsplit = $ipconfig.Subnet.id.split('/')
                $subnetName = $subsplit[$subsplit.Length -1]
                $vnetName = $subsplit[$subsplit.Length -3]
                $subnet = $null
                $vnet = $null
                try
                {
                    $vnet = Get-AzureRmVirtualNetwork -name $vnetName -ResourceGroupName $resourceGroupName -ea Stop -wa SilentlyContinue
                    $subnet = $vnet | Get-AzureRmVirtualNetworkSubnetConfig  -Name $subnetName -ea Stop -wa SilentlyContinue
                }
                catch{}
            }

            $ipConfigParams = @{
            "Name" = $ipConfigName
            "PrivateIpAddressVersion" = $ipConfig.PrivateIpAddressVersion
            "PrivateIpAddress" = $ipConfig.PrivateIpAddress
            }

            # add subnet if present.
            if($subnet) 
            {
                $ipConfigParams.Add( "Subnet", $subnet)
            }
            
            # add public IP if present.
            if($ipConfig.PublicIpAddress) 
            {
                $ipipsplit = $ipConfig.PublicIpAddress.id.split('/')
                $ipipName = $ipipsplit[$ipipsplit.Length -1]
                $PublicIP = Get-AzureRmPublicIpAddress -Name $ipipName -ResourceGroupName $ResourceGroupName
                $ipConfigParams.Add("PublicIpAddress", $PublicIP)
            }

            # add LoadBalancerBackendAddressPools if present.
            if($ipConfig.LoadBalancerBackendAddressPools) 
            {
                $lbbesplit = $ipconfig.LoadBalancerBackendAddressPools.id.split('/')
                $lbbeName = $lbbesplit[$lbbesplit.Length -1]
                $lbName = $lbbesplit[$lbbesplit.Length -3]
                try
                {
                $lb = Get-AzureRmLoadBalancer -name $lbName -ResourceGroupName $resourceGroupName -ea Stop -wa SilentlyContinue
                    $lbbe = $lb | Get-AzureRmLoadBalancerBackendAddressPoolConfig -Name $lbbeName -ea Stop -wa SilentlyContinue
                }
                catch{}
                
                if($lbbe){ $ipConfigParams.Add("LoadBalancerBackendAddressPool", $lbbe) }
            }
            
            # add LoadBalancerInboundNatRules if present.
            if($ipConfig.LoadBalancerInboundNatRules) 
            {
                $lbINRsplit = $ipconfig.LoadBalancerInboundNatRules.id.split('/')
                $lbINRName = $lbINRsplit[$lbINRsplit.Length -1]
                $lbName = $lbINRsplit[$lbINRsplit.Length -3]
                try
                {
                    $lb = Get-AzureRmLoadBalancer -name $lbName -ResourceGroupName $resourceGroupName -ea Stop -wa SilentlyContinue
                    $lbINR = $lb | Get-AzureRmLoadBalancerInboundNatRuleConfig -Name $lbINRName -ea Stop -wa SilentlyContinue
                }
                catch{}
            
                if($lbINR){$ipConfigParams.Add("LoadBalancerInboundNatRule", $lbINR)}
            }
            
            # add ApplicationGatewayBackendAddressPools if present.
            # TODO:  need to very this can be added as is
            if($ipConfig.ApplicationGatewayBackendAddressPools) 
            {
                $ipConfigParams.Add("ApplicationGatewayBackendAddressPool", $ipConfig.ApplicationGatewayBackendAddressPools)
            }



            try
            {
                write-verbose "Adding IP config $ipConfigName to network interface $NicName" -verbose
                $NewIpConfig = New-AzureRmNetworkInterfaceIpConfig @ipConfigParams -ea Stop -wa SilentlyContinue 
                [array]$NewIpConfigs +=  $NewIpConfig                
                Write-Output "IP config $ipConfigName for $NicName was added"
            }
            catch
            {
                $_
                write-warning "Failed to add IP config $ipConfigName to network interface $NicName"
            } 

        }

        if(! $NewIpConfigs)
        {
            $NewIpConfigs = New-AzureRmNetworkInterfaceIpConfig -Name 'empty'
        }
        
        $NICparams = @{
        "Name" = $NicName
        "ResourceGroupName" = $resourceGroupName
        "Location" = $location
        "IpConfiguration" = $NewIpConfigs
        }
        
        # add DNS if present.
        if($NicDNS) 
        {
            $NICparams.Add("DnsServer", $NicDNS)
        }

        # add NetworkSecurityGroup if present.
        if($srcNIC.NetworkSecurityGroup) 
        {
            $NSGsplit = $srcNIC.NetworkSecurityGroup.id.split('/')
            $srcNSGname = $NSGsplit[$NSGsplit.Length -1]
            
            try
            { 
                $newNSG = Get-AzureRmNetworkSecurityGroup -Name $srcNSGname -ResourceGroupName $ResourceGroupName
                $NICparams.Add("NetworkSecurityGroup", $newNSG)
            }
            catch
            {
                write-warning "Failed to add Network Security Group $srcNSGname to network interface $NicName"
            }
        }

        # add EnableIPForwarding if present.
        # TODO:  need to verify this switch can be splatted with explicit value of $true
        if($srcNIC.EnableIPForwarding) 
        {
            $NICparams.Add("EnableIPForwarding", $true)
        }

        
        try
        {
            write-verbose "Creating network interface $NicName in resource group $resourceGroupName at location $location" -verbose
            $NewNIC = New-AzureRmNetworkInterface @NICparams -ea Stop -wa SilentlyContinue
            Write-Output "Network interface $NicName was created"
        }
        catch
        {
            $_
            write-warning "Failed to create network interface $NicName"
        } 

    } # end of foreach nic

    $resourceGroupVMs | ConvertTo-Json -depth 10 | Out-File $resourceGroupVMresumePath
    $VHDstorageObjects | ConvertTo-Json | Out-File $VHDstorageObjectsResumePath

    # monitor file copy - do not proceed with VM creation until it is complete.  Allows for user to break out and use -resume switch 

   
    do{

        $VHDstorageObjects | Select-Object -Property destStorageContext -Unique | %{
        
           $containers = Get-AzureStorageContainer -Context $_.destStorageContext 
        
           foreach($container in $containers){
             $rtn = Get-AzureStorageBlob -Container $container.name -Context $_.destStorageContext  | Get-AzureStorageBlobCopyState
             $rtn | select Source, Status, BytesCopied, TotalBytes | fl
           }
        }
        if($rtn.status  -ne 'Success')
        {
          write-warning "VHD blob copy is not complete"
          $rh = read-host "Press <Enter> to refresh copy status or type EXIT and press <Enter> to quit and resume later"
          if(($rh.ToLower()) -eq 'exit')
          {
           write-output "Run script with -resume switch to continue creating VMs after file copy has completed."
           BREAK
          }
        }
    }
    while($rtn.status  -ne 'Success')

    # exit script if user breaks out of above loop   
    if($rtn.status  -ne 'Success'){EXIT}

} 
else # if  resume
{

    # check for valid source resource group
    if(-not ($targetResourceGroup = Get-AzureRmResourceGroup  -ResourceGroupName $NewResourceGroupName)) 
    {
       write-warning "The provided resource group $NewResourceGroupName could not be found. Exiting the script."
       break
    }
    
    $ResourceGroupName = $NewResourceGroupName

    [string] $location = $targetResourceGroup.location

    
    try
    {
        $resourceGroupVMs = (get-content $resourceGroupVMresumePath -ea Stop) -Join "`n"| ConvertFrom-Json 
    } 
    catch
    {
        $_
        write-warning "Failed to load resume file $resourceGroupVMresumePath  Cannot resume. Exiting script."
    }

    try 
    {
        $VHDstorageObjects = (get-content $VHDstorageObjectsResumePath -ea Stop) -Join "`n"| ConvertFrom-Json 
    }
    catch
    {
        $_
        write-warning "Failed to load resume file $VHDstorageObjectsResumePath  Cannot resume. Exiting script."
    }
}


<###############################

 Create new Virtual Machines.  

################################>


# create new Virtual Machine(s)
foreach($srcVM in $resourceGroupVMs)
{
    # get source VM attributes
    $VMName = $srcVM.Name
    $VMSize = $srcVM.HardwareProfile.VMSize
    $OSDiskName = $srcVM.StorageProfile.OsDisk.Name
    $OSType = $srcVM.storageprofile.osdisk.OsType
    $OSDiskCaching = $srcVM.StorageProfile.OsDisk.Caching
    $CreateOption = "Attach"

    if($srcVM.AvailabilitySetReference)
    {
        $avSetRef = ($srcVM.AvailabilitySetReference.id).Split('/')
        $avSetName = $avSetRef[($avSetRef.count -1)]
        $AvailabilitySet = Get-AzureRmAvailabilitySet -ResourceGroupName $ResourceGroupName -Name $avSetName
    }  
    
    # get blob and container names from source URI
    $OSsrcURI = $srcVM.storageprofile.osdisk.vhd.uri
    $OSsplit = $OSsrcURI.Split('/')
    # TODO: assumes one level of container.  need to adjust to allow for something like container/myfolder/vhdfolder
    $OSblobName = $OSsplit[($OSsplit.count -1)]
    $OScontainerName = $OSsplit[3]
    # get the new destination storage account name from our custom object array
    $OSstorageContext = ($VHDstorageObjects| where{$_.srcURI -eq $OSsrcURI} | Select-Object -Property destStorageContext -Unique).destStorageContext
    # refresh the storage context object if -resume
    if($resume)
    {
      $osStorageAccountName = $OSstorageContext.StorageAccountName
      $StorageAccountKey = (Get-AzureRmStorageAccountKey -ResourceGroupName $resourceGroupName -AccountName $osStorageAccountName).Value[0]
      $OSstorageContext = New-AzureStorageContext -StorageAccountName $osStorageAccountName -StorageAccountKey $StorageAccountKey
    }
    
    # set the OSdisk URI
    $OSDiskUri = "$($OSstorageContext.BlobEndPoint)$OScontainerName/$OSblobName"
   
    do{
       $rtn = $null
       write-verbose "Checking VHD blob copy for $OSblobName" -verbose
       $rtn = Get-AzureStorageBlob -Context $OSstorageContext -container $OScontainerName -Blob $OSblobName | Get-AzureStorageBlobCopyState
       $rtn | select Source, Status, BytesCopied, TotalBytes | fl
       if($rtn.status  -ne 'Success'){
        write-warning "VHD blob copy is not complete"
        $rh = read-host "Press <Enter> to refresh or type EXIT and press <Enter> to quit copy status updates and resume later"
        if(($rh.ToLower()) -eq 'exit')
        {
          write-output "Run script with -resume switch to continue creating VMs after file copy has completed."
          BREAK
        }
       }  
    }
   while($rtn.status  -ne 'Success')

    # exit script if user breaks out of above loop   
    if($rtn.status  -ne 'Success'){EXIT}

        
    # get the Network Interface Card we created previously based on the original source name
    $NICRef = ($srcVM.NetworkInterfaceIDs).Split('/')
    $NICName = $NICRef[($NICRef.count -1)]
    $NIC = Get-AzureRmNetworkInterface -Name $NICName -ResourceGroupName $ResourceGroupName 

    
    

    # create VM Config
    if($AvailabilitySet)
    {
        $VirtualMachine = New-AzureRmVMConfig -VMName $VMName -VMSize $VMSize  -AvailabilitySetID $AvailabilitySet.Id  -wa SilentlyContinue
    }
    else
    {
        $VirtualMachine = New-AzureRmVMConfig -VMName $VMName -VMSize $VMSize -wa SilentlyContinue
    }
    
    # Set OS Disk based on OS type
    if($OStype -eq 'Windows' -or $OStype -eq '0'){
       $VirtualMachine = Set-AzureRmVMOSDisk -VM $VirtualMachine -Name $OSDiskName -VhdUri $OSDiskUri -Caching $OSDiskCaching -CreateOption $createOption -Windows
    }
    else
    {
       $VirtualMachine = Set-AzureRmVMOSDisk -VM $VirtualMachine -Name $OSDiskName -VhdUri $OSDiskUri -Caching $OSDiskCaching -CreateOption $createOption -Linux
    }

    # add NIC
    $VirtualMachine = Add-AzureRmVMNetworkInterface -VM $VirtualMachine -Id $NIC.Id

    # add data disk if they were present
    if($srcVM.storageProfile.datadisks)
    {
        foreach($disk in $srcVM.storageProfile.DataDisks) 
        {
            $dataDiskName = $null
            $srcURI = $null
            $blobName = $null
            $dataDiskName = $disk.Name
            $dataDiskLUN = $disk.Lun
            $diskCaching = $disk.Caching
            $DiskSizeGB = $disk.DiskSizeGB
            $srcDiskURI = $disk.vhd.uri
            $split = $srcDiskURI.Split('/')
            # TODO: assumes one level of container.  need to adjust to allow for something like container/myfolder/vhdfolder
            $diskBlobName = $split[($split.count -1)]
            $diskContainerName = $split[3]
            # get the new destination storage account name from our custom object array
            $diskStorageContext = ($VHDstorageObjects| where{$_.srcURI -eq $srcDiskURI} | Select-Object -Property destStorageContext -Unique).destStorageContext
            # refresh the storage context object if -resume
            if($resume)
            {
              $diskStorageAccountName = $diskStorageContext.StorageAccountName
              $StorageAccountKey = (Get-AzureRmStorageAccountKey -ResourceGroupName $resourceGroupName -AccountName $diskStorageAccountName).Value[0]
              $diskStorageContext = New-AzureStorageContext -StorageAccountName $diskStorageAccountName -StorageAccountKey $StorageAccountKey
            }

            $dataDiskUri = "$($diskStorageContext.BlobEndPoint)$diskContainerName/$diskBlobName"
        
            do
            { 
              $drtn = $null
              write-verbose "Checking VHD blob copy for $diskBlobName" -verbose
              $drtn = Get-AzureStorageBlob -Context $diskStorageContext -container $diskContainerName -Blob $diskBlobName | Get-AzureStorageBlobCopyState
              $drtn| select Source, Status, BytesCopied, TotalBytes|fl
              if($rtn.status  -ne 'Success')
              {
               write-warning "VHD blob copy is not complete"
               $rh = read-host "Press <Enter> to refresh or type EXIT and press <Enter> to quit copy status updates and resume later"
               if(($rh.ToLower()) -eq 'exit')
               {
                 write-output "Run script with -resume switch to continue creating VMs after file copy has completed."
                 BREAK
               }
              }
            }
            while($drtn.status  -ne 'Success')
            
            # exit script if user breaks out of above loop   
            if($rtn.status  -ne 'Success'){EXIT}
                
            Add-AzureRmVMDataDisk -VM $VirtualMachine -Name $dataDiskName -DiskSizeInGB $DiskSizeGB -Lun $dataDiskLUN -VhdUri $dataDiskUri -Caching $diskCaching -CreateOption $CreateOption | out-null
        }
    }
     
    # create the VM from the config
    try
    {
        
        write-verbose "Creating Virtual Machine $VMName in resource group $resourceGroupName at location $location" -verbose
       # $VirtualMachine
        New-AzureRmVM -ResourceGroupName $ResourceGroupName -Location $location -VM $VirtualMachine -ea Stop -wa SilentlyContinue | out-null
        write-output "Successfully created Virtual Machine $VMName"
    }
    catch
    {
         $_
         write-warning "Failed to create Virtual Machine $VMName"
    }
}


