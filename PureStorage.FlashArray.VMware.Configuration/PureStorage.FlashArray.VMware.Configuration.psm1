function New-PfaConnection {
  <#
  .SYNOPSIS
    Uses New-Pfaarray to store the connection in a global parameter
  .DESCRIPTION
    Creates a FlashArray connection and stores it in global variable $Global:DefaultFlashArray. If you make more than one connection it will store them all in $Global:AllFlashArrays
  .INPUTS
    An FQDN or IP, credentials, and ignore certificate boolean
  .OUTPUTS
    Returns the FlashArray connection.
  .NOTES
    Version:        1.0
    Author:         Cody Hosterman https://codyhosterman.com
    Creation Date:  05/23/2019
    Purpose/Change: Updated for new connection mgmt

  *******Disclaimer:******************************************************
  This scripts are offered "as is" with no warranty.  While this 
  scripts is tested and working in my environment, it is recommended that you test 
  this script in a test lab before using in a production environment. Everyone can 
  use the scripts/commands provided here without any written permission but I
  will not be liable for any damage or loss to the system.
  ************************************************************************
  #>

  [CmdletBinding()]
  Param(

      [Parameter(Position=0,mandatory=$true)]
      [string]$endpoint,

      [Parameter(Position=1,ValueFromPipeline=$True,mandatory=$true)]
      [System.Management.Automation.PSCredential]$credentials,

      [Parameter(Position=2)]
      [switch]$defaultArray,

      [Parameter(Position=3)]
      [switch]$nonDefaultArray,

      [Parameter(Position=4)]
      [switch]$ignoreCertificateError
  )
  Begin {
      if (($true -eq $defaultArray) -and ($true -eq $nonDefaultArray))
      {
          throw "You can only specify defaultArray or nonDefaultArray, not both."
      }
      if (($false -eq $defaultArray) -and ($false -eq $nonDefaultArray))
      {
          throw "Please specify this to be either the new default array or a non-default array"
      }
      $ErrorActionPreference = "stop"
  }
  Process {
      if ($null -eq $Global:AllFlashArrays)
      {
          $Global:AllFlashArrays = @()
      }
      $flasharray = New-PfaArray -EndPoint $endpoint -Credentials $credentials -IgnoreCertificateError:$ignoreCertificateError
      $Global:AllFlashArrays += $flasharray
      if ($defaultArray -eq $true)
      {
          $Global:DefaultFlashArray = $flasharray
      }
  }
  End {
      return $flasharray
  } 
}
function Get-PfaDatastore {
  <#
  .SYNOPSIS
    Retrieves all Pure Storage FlashArray datastores
  .DESCRIPTION
    Will return all FlashArray-based datastores, either VMFS or VVols, and if specified just for a particular FlashArray connection.
  .INPUTS
    A FlashArray connection, a cluster or VMhost, and filter of VVol or VMFS. All optional.
  .OUTPUTS
    Returns the relevant datastores.
  .NOTES
    Version:        1.0
    Author:         Cody Hosterman https://codyhosterman.com
    Creation Date:  06/04/2019
    Purpose/Change: First release

  *******Disclaimer:******************************************************
  This scripts are offered "as is" with no warranty.  While this 
  scripts is tested and working in my environment, it is recommended that you test 
  this script in a test lab before using in a production environment. Everyone can 
  use the scripts/commands provided here without any written permission but I
  will not be liable for any damage or loss to the system.
  ************************************************************************
  #>

  [CmdletBinding()]
  Param(

      [Parameter(Position=0,ValueFromPipeline=$True)]
      [PurePowerShell.PureArray]$flasharray,
    
      [Parameter(Position=1)]
      [switch]$vvol,

      [Parameter(Position=2)]
      [switch]$vmfs,

      [Parameter(Position=3,ValueFromPipeline=$True)]
      [VMware.VimAutomation.ViCore.Types.V1.Inventory.Cluster]$cluster,
      
      [Parameter(Position=4,ValueFromPipeline=$True)]
      [VMware.VimAutomation.ViCore.Types.V1.Inventory.VMHost]$esxi
  )
  if (($null -ne $esxi) -and ($null -ne $cluster))
  {
      throw "Please only pass in an ESXi host or a cluster, or neither"
  }
  if ($null -ne $esxi)
  {
      $datastores = $esxi | Get-datastore
  }
  elseif ($null -ne $cluster) 
  {
      $datastores = $cluster | Get-datastore
  }
  else {
      $datastores = Get-datastore
  }
  if (($true -eq $vvol) -or (($false -eq $vvol) -and ($false -eq $vmfs)))
  {
    $vvolDatastores = $datastores  |where-object {$_.Type -eq "VVOL"} |Where-Object {$_.ExtensionData.Info.VvolDS.StorageArray[0].VendorId -eq "PURE"} 
    if ($null -ne $flasharray)
    {
      $arrayID = (Get-PfaArrayAttributes -Array $flasharray).id
      $vvolDatastores = $vvolDatastores |Where-Object {$_.ExtensionData.info.vvolDS.storageArray[0].uuid.substring(16) -eq $arrayID}
    }
  }
  if (($true -eq $vmfs) -or (($false -eq $vmfs) -and ($false -eq $vvol)))
  {
      $vmfsDatastores = $datastores  |where-object {$_.Type -eq "VMFS"} |Where-Object {$_.ExtensionData.Info.Vmfs.Extent.DiskName -like 'naa.624a9370*'} 
      if ($null -ne $flasharray)
      {
          $faVMFSdatastores = @()
          foreach ($vmfsDatastore in $vmfsDatastores)
          {
              try 
              {
                  Get-PfaConnectionOfDatastore -datastore $vmfsDatastore -flasharrays $flasharray |Out-Null
                  $faVMFSdatastores += $vmfsDatastore
              }
              catch 
              {
                  continue
              }
          }
          $vmfsDatastores = $faVMFSdatastores
      }
  }
  $allDatastores = @()
  if ($null -ne $vmfsDatastores)
  {
      $allDatastores += $vmfsDatastores
  }
  if ($null -ne $vvolDatastores)
  {
      $allDatastores += $vvolDatastores
  }
  return $allDatastores
}
function Get-PfaConnectionOfDatastore {
<#
.SYNOPSIS
  Takes in a VVol or VMFS datastore, one or more FlashArray connections and returns the correct connection.
.DESCRIPTION
  Will iterate through any connections stored in $Global:AllFlashArrays or whatever is passed in directly.
.INPUTS
  A datastore and one or more FlashArray connections
.OUTPUTS
  Returns the correct FlashArray connection.
.NOTES
  Version:        1.0
  Author:         Cody Hosterman https://codyhosterman.com
  Creation Date:  05/26/2019
  Purpose/Change: Updated for new connection mgmt

*******Disclaimer:******************************************************
This scripts are offered "as is" with no warranty.  While this 
scripts is tested and working in my environment, it is recommended that you test 
this script in a test lab before using in a production environment. Everyone can 
use the scripts/commands provided here without any written permission but I
will not be liable for any damage or loss to the system.
************************************************************************
#>

[CmdletBinding()]
Param(

  [Parameter(Position=0,ValueFromPipeline=$True)]
  [PurePowerShell.PureArray[]]$flasharrays,

  [Parameter(Position=1,mandatory=$true,ValueFromPipeline=$True)]
  [VMware.VimAutomation.ViCore.Types.V1.DatastoreManagement.Datastore]$datastore
)
if ($null -eq $flasharrays)
{
    $flasharrays = getAllFlashArrays 
}
if ($datastore.Type -eq 'VMFS')
{
    $lun = $datastore.ExtensionData.Info.Vmfs.Extent.DiskName |select-object -unique
    if ($lun -like 'naa.624a9370*')
    { 
        $volserial = ($lun.ToUpper()).substring(12)
        foreach ($flasharray in $flasharrays)
        { 
            $pureVolumes = Get-PfaVolumes -Array  $flasharray
            $purevol = $purevolumes | where-object { $_.serial -eq $volserial }
            if ($null -ne $purevol.name)
            {
                return $flasharray
            }
        }
    }
    else 
    {
        throw "This VMFS is not hosted on FlashArray storage."
    }
}
elseif ($datastore.Type -eq 'VVOL') 
{
    $datastoreArraySerial = $datastore.ExtensionData.Info.VvolDS.StorageArray[0].uuid.Substring(16)
    foreach ($flasharray in $flasharrays)
    {
        $arraySerial = (Get-PfaArrayAttributes -array $flasharray).id
        if ($arraySerial -eq $datastoreArraySerial)
        {
            $Global:CurrentFlashArray = $flasharray
            return $flasharray
        }
    }
}
else 
{
    throw "This is not a VMFS or VVol datastore."
}
$Global:CurrentFlashArray = $null
throw "The datastore was not found on any of the FlashArray connections."
}
function Get-PfaConnectionFromArrayId {
  <#
  .SYNOPSIS
    Retrieves the FlashArray connection from the specified array ID.
  .DESCRIPTION
    Retrieves the FlashArray connection from the specified array ID.
  .INPUTS
    FlashArray array ID/serial
  .OUTPUTS
    FlashArray connection.
  .NOTES
    Version:        1.0
    Author:         Cody Hosterman https://codyhosterman.com
    Creation Date:  06/10/2019
    Purpose/Change: First release

  *******Disclaimer:******************************************************
  This scripts are offered "as is" with no warranty.  While this 
  scripts is tested and working in my environment, it is recommended that you test 
  this script in a test lab before using in a production environment. Everyone can 
  use the scripts/commands provided here without any written permission but I
  will not be liable for any damage or loss to the system.
  ************************************************************************
  #>

  [CmdletBinding()]
  Param(
      [Parameter(Position=0,ValueFromPipeline=$True)]
      [PurePowerShell.PureArray[]]$flasharrays,

      [Parameter(Position=1,mandatory=$true)]
      [string]$arrayId
  )
  if ($null -eq $flasharrays)
  {
      $flasharrays = getAllFlashArrays 
  }
  foreach ($flasharray in $flasharrays)
  {
      $returnedID = (Get-PfaArrayAttributes -Array $flasharray).id
      if ($returnedID.ToLower() -eq $arrayId.ToLower())
      {
          return $flasharray
      }
  }
  throw "FlashArray connection not found for serial $($arrayId)"
}
function New-PfaRestSession {
     <#
    .SYNOPSIS
      Connects to FlashArray and creates a REST connection.
    .DESCRIPTION
      For operations that are in the FlashArray REST, but not in the Pure Storage PowerShell SDK yet, this provides a connection for invoke-restmethod to use.
    .INPUTS
      FlashArray connection or FlashArray IP/FQDN and credentials
    .OUTPUTS
      Returns REST session
    .NOTES
      Version:        2.0
      Author:         Cody Hosterman https://codyhosterman.com
      Creation Date:  05/26/2019
      Purpose/Change: Updated for new connection mgmt
  
    *******Disclaimer:******************************************************
    This scripts are offered "as is" with no warranty.  While this 
    scripts is tested and working in my environment, it is recommended that you test 
    this script in a test lab before using in a production environment. Everyone can 
    use the scripts/commands provided here without any written permission but I
    will not be liable for any damage or loss to the system.
    ************************************************************************
    #>
    [CmdletBinding()]
    Param(
        [Parameter(Position=0,ValueFromPipeline=$True)]
        [PurePowerShell.PureArray]$flasharray
    )
    #Connect to FlashArray
    if ($null -eq $flasharray)
    {
        $flasharray = checkDefaultFlashArray
    }
add-type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(
        ServicePoint srvPoint, X509Certificate certificate,
        WebRequest request, int certificateProblem) {
        return true;
    }
}
"@
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
  #Create FA REST session
    $SessionAction = @{
        api_token = $flasharray.ApiToken
    }
    Invoke-RestMethod -Method Post -Uri "https://$($flasharray.Endpoint)/api/$($flasharray.apiversion)/auth/session" -Body $SessionAction -SessionVariable Session -ErrorAction Stop |Out-Null
    $global:faRestSession = $Session
    return $global:faRestSession
}
function Remove-PfaRestSession {
    <#
    .SYNOPSIS
      Disconnects a FlashArray REST session
    .DESCRIPTION
      Takes in a FlashArray Connection or session and disconnects on the FlashArray.
    .INPUTS
      FlashArray connection or session
    .OUTPUTS
      Returns success or failure.
    .NOTES
      Version:        2.0
      Author:         Cody Hosterman https://codyhosterman.com
      Creation Date:  05/26/2019
      Purpose/Change: Updated for new connection mgmt
  
    *******Disclaimer:******************************************************
    This scripts are offered "as is" with no warranty.  While this 
    scripts is tested and working in my environment, it is recommended that you test 
    this script in a test lab before using in a production environment. Everyone can 
    use the scripts/commands provided here without any written permission but I
    will not be liable for any damage or loss to the system.
    ************************************************************************
    #>

    [CmdletBinding()]
    Param(
            [Parameter(Position=0,ValueFromPipeline=$True,mandatory=$true)]
            [Microsoft.PowerShell.Commands.WebRequestSession]$faSession,

            [Parameter(Position=1,ValueFromPipeline=$True)]
            [PurePowerShell.PureArray]$flasharray
    )
      if ($null -eq $flasharray)
      {
          $flasharray = checkDefaultFlashArray
      }
      $purevip = $flasharray.endpoint
      $apiVersion = $flasharray.ApiVersion
      #Delete FA session
      Invoke-RestMethod -Method Delete -Uri "https://${purevip}/api/${apiVersion}/auth/session"  -WebSession $faSession -ErrorAction Stop |Out-Null
}
function New-PfaHostFromVmHost {
    <#
    .SYNOPSIS
      Create a FlashArray host from an ESXi vmhost object
    .DESCRIPTION
      Takes in a vCenter ESXi host and creates a FlashArray host
    .INPUTS
      FlashArray connection, a vCenter ESXi vmHost, and iSCSI/FC option
    .OUTPUTS
      Returns new FlashArray host object.
    .NOTES
      Version:        2.0
      Author:         Cody Hosterman https://codyhosterman.com
      Creation Date:  05/26/2019
      Purpose/Change: Updated for new connection mgmt
  
    *******Disclaimer:******************************************************
    This scripts are offered "as is" with no warranty.  While this 
    scripts is tested and working in my environment, it is recommended that you test 
    this script in a test lab before using in a production environment. Everyone can 
    use the scripts/commands provided here without any written permission but I
    will not be liable for any damage or loss to the system.
    ************************************************************************
    #>

    [CmdletBinding()]
    Param(
            [Parameter(Position=0,mandatory=$true)]
            [VMware.VimAutomation.ViCore.Types.V1.Inventory.VMHost]$esxi,

            [Parameter(Position=1)]
            [string]$protocolType,

            [Parameter(Position=2,ValueFromPipeline=$True)]
            [PurePowerShell.PureArray[]]$flasharray,

            [Parameter(Position=3)]
            [switch]$iscsi,

            [Parameter(Position=4)]
            [switch]$fc
    )
    Begin {
      if (($protocolType -eq "FC") -and ($protocolType -eq "iSCSI"))
      {
          Write-Warning -Message "The protocolType parameter is being deprecated, please use the -fc or -iscsi switch parameters instead."
      }
      if (($protocolType -ne "FC") -and ($protocolType -ne "iSCSI") -and ($iscsi -ne $true) -and ($fc -ne $true))
      {
          throw 'No valid protocol entered. Please add the -fc or -iscsi switch parameter"'
      }
      if (($iscsi -eq $true) -and ($protocolType -eq $true))
      {
          throw "You cannot use both the -fc and -iscsi switch"
      }
      if (($iscsi -eq $true) -and ($protocolType -eq "FC"))
      {
          throw "You cannot use the iSCSI switch parameter and specify FC in the protocolType option. The protocolType parameter is being deprecated."
      }
      if (($fc -eq $true) -and ($protocolType -eq "iSCSI"))
      {
          throw "You cannot use the FC switch parameter and specify iSCSI in the protocolType option. The protocolType parameter is being deprecated."
      }
      if ($protocolType -eq "FC")
      {
        $fc = $true
      }
      if ($protocolType -eq "iSCSI")
      {
        $iscsi = $true
      }
      $vmHosts = @()
    } 
    Process 
    {
        if ($null -eq $flasharray)
        {
          $flasharray = checkDefaultFlashArray
        }
        foreach ($fa in $flasharray)
        {
            try {
              $newFaHost = $null
              $newFaHost = Get-PfaHostFromVmHost -flasharray $fa -esxi $esxi -ErrorAction Stop
              $vmHosts += $newFaHost
            }
            catch {}
            if ($null -eq $newFaHost)
            {
                if ($iscsi -eq $true)
                {
                    set-vmHostPfaiSCSI -esxi $esxi -flasharray $fa  -ErrorAction Stop|Out-Null
                    $iscsiadapter = $esxi | Get-VMHostHBA -Type iscsi | Where-Object {$_.Model -eq "iSCSI Software Adapter"}
                    if ($null -eq $iscsiadapter)
                    {
                        throw "No Software iSCSI adapter found on host $($esxi.NetworkInfo.HostName)."
                    }
                    else
                    {
                        $iqn = $iscsiadapter.ExtensionData.IScsiName
                    }
                    try
                    {
                        $newFaHost = New-PfaHost -Array $fa -Name $esxi.NetworkInfo.HostName -IqnList $iqn -ErrorAction stop
                        $majorVersion = ((Get-PfaArrayAttributes -Array $fa).version[0])
                        if ($majorVersion -ge 5)
                        {
                          Set-PfaPersonality -Array $fa -Name $newFaHost.name -Personality "esxi" |Out-Null
                        }
                        $vmHosts += $newFaHost
                    }
                    catch
                    {
                        Write-Error $Global:Error[0]
                        return $null
                    }
                }
                if ($fc -eq $true)
                {
                    $wwns = $esxi | Get-VMHostHBA -Type FibreChannel | Select-Object VMHost,Device,@{N="WWN";E={"{0:X}" -f $_.PortWorldWideName}} | Format-table -Property WWN -HideTableHeaders |out-string
                    $wwns = (($wwns.Replace("`n","")).Replace("`r","")).Replace(" ","")
                    $wwns = &{for ($i = 0;$i -lt $wwns.length;$i += 16)
                    {
                            $wwns.substring($i,16)
                    }}
                    try
                    {
                        $newFaHost = New-PfaHost -Array $fa -Name $esxi.NetworkInfo.HostName -WwnList $wwns -ErrorAction stop
                        $majorVersion = ((Get-PfaArrayAttributes -Array $fa).version[0])
                        if ($majorVersion -ge 5)
                        {
                          Set-PfaPersonality -Array $fa -Name $newFaHost.name -Personality "esxi" |Out-Null
                        }
                        $vmHosts += $newFaHost
                        $Global:CurrentFlashArray = $fa
                    }
                    catch
                    {
                        Write-Error $Global:Error[0]
                    }
                }
            }
        }
    }
    End {
      return $vmHosts
    }  
}
function Get-PfaHostFromVmHost {
    <#
    .SYNOPSIS
      Gets a FlashArray host object from a ESXi vmhost object
    .DESCRIPTION
      Takes in a vmhost and returns a matching FA host if found
    .INPUTS
      FlashArray connection and a vCenter ESXi host
    .OUTPUTS
      Returns FA host if matching one is found.
    .NOTES
      Version:        2.0
      Author:         Cody Hosterman https://codyhosterman.com
      Creation Date:  05/26/2019
      Purpose/Change: Updated for new connection mgmt
  
    *******Disclaimer:******************************************************
    This scripts are offered "as is" with no warranty.  While this 
    scripts is tested and working in my environment, it is recommended that you test 
    this script in a test lab before using in a production environment. Everyone can 
    use the scripts/commands provided here without any written permission but I
    will not be liable for any damage or loss to the system.
    ************************************************************************
    #>

    [CmdletBinding()]
    Param(
        [Parameter(Position=0,mandatory=$true,ValueFromPipeline=$True)]
        [VMware.VimAutomation.ViCore.Types.V1.Inventory.VMHost]$esxi,

        [Parameter(Position=1,ValueFromPipeline=$True)]
        [PurePowerShell.PureArray]$flasharray
    )
    if ($null -eq $flasharray)
    {
      $flasharray = checkDefaultFlashArray
    }
    $iscsiadapter = $esxi | Get-VMHostHBA -Type iscsi | Where-Object {$_.Model -eq "iSCSI Software Adapter"}
    $wwns = $esxi | Get-VMHostHBA -Type FibreChannel | Select-Object VMHost,Device,@{N="WWN";E={"{0:X}" -f $_.PortWorldWideName}} | Format-table -Property WWN -HideTableHeaders |out-string
    $wwns = (($wwns.Replace("`n","")).Replace("`r","")).Replace(" ","")
    $wwns = &{for ($i = 0;$i -lt $wwns.length;$i += 16)
    {
            $wwns.substring($i,16)
    }}
    $fahosts = Get-PFAHosts -array $flasharray -ErrorAction Stop
    if ($null -ne $iscsiadapter)
    {
        $iqn = $iscsiadapter.ExtensionData.IScsiName
        foreach ($fahost in $fahosts)
        {
            if ($fahost.iqn.count -ge 1)
            {
                foreach ($fahostiqn in $fahost.iqn)
                {
                    if ($iqn.ToLower() -eq $fahostiqn.ToLower())
                    {
                        $faHostMatch = $fahost
                    }
                }
            }
        }   
    }
    if (($null -ne $wwns) -and ($null -eq $faHostMatch))
    {
        foreach ($wwn in $wwns)
        {
            foreach ($fahost in $fahosts)
            {
                if ($fahost.wwn.count -ge 1)
                {
                    foreach($fahostwwn in $fahost.wwn)
                    {
                        if ($wwn.ToLower() -eq $fahostwwn.ToLower())
                        {
                          $faHostMatch = $fahost
                        }
                    }
                }
            }
        }
    }
    if ($null -ne $faHostMatch)
    { 
      $Global:CurrentFlashArray = $flasharray
      return $faHostMatch
    }
    else 
    {
        throw "No matching host could be found on the FlashArray $($flasharray.EndPoint)"
    }
}
function Get-PfaHostGroupfromVcCluster {
    <#
    .SYNOPSIS
      Retrieves a FA host group from an ESXi cluster
    .DESCRIPTION
      Takes in a vCenter Cluster and retrieves corresonding host group
    .INPUTS
      FlashArray connection and a vCenter cluster
    .OUTPUTS
      Returns success or failure.
    .NOTES
      Version:        2.0
      Author:         Cody Hosterman https://codyhosterman.com
      Creation Date:  05/26/2019
      Purpose/Change: Updated for new connection mgmt
  
    *******Disclaimer:******************************************************
    This scripts are offered "as is" with no warranty.  While this 
    scripts is tested and working in my environment, it is recommended that you test 
    this script in a test lab before using in a production environment. Everyone can 
    use the scripts/commands provided here without any written permission but I
    will not be liable for any damage or loss to the system.
    ************************************************************************
    #>

    [CmdletBinding()]
    Param(
        [Parameter(Position=0,mandatory=$true,ValueFromPipeline=$True)]
        [VMware.VimAutomation.ViCore.Types.V1.Inventory.Cluster]$cluster,

        [Parameter(Position=1,ValueFromPipeline=$True)]
        [PurePowerShell.PureArray]$flasharray
    )
    if ($null -eq $flasharray)
    {
      $flasharray = checkDefaultFlashArray
    }
    $esxiHosts = $cluster |Get-VMHost
    $faHostGroups = @()
    $faHostGroupNames = @()
    foreach ($esxiHost in $esxiHosts)
    {
        try {
            $faHost = $esxiHost | Get-PfaHostFromVmHost -flasharray $flasharray
            if ($null -ne $faHost.hgroup)
            {
                if ($faHostGroupNames.contains($faHost.hgroup))
                {
                    continue
                }
                else {
                    $faHostGroupNames += $faHost.hgroup
                    $faHostGroup = Get-PfaHostGroup -Array $flasharray -Name $faHost.hgroup
                    $faHostGroups += $faHostGroup
                }
            }
        }
        catch{
            continue
        }
    }
    if ($null -eq $faHostGroup)
    {
        throw "No host group found for this cluster on $($flasharray.EndPoint). You can create a host group with New-PfahostgroupfromvcCluster"
    }
    if ($faHostGroups.count -gt 1)
    {
        Write-Warning -Message "This cluster spans more than one host group. The recommendation is to have only one host group per cluster"
    }
    $Global:CurrentFlashArray = $flasharray
    return $faHostGroups
}
function New-PfaHostGroupfromVcCluster {
    <#
    .SYNOPSIS
      Create a host group from an ESXi cluster
    .DESCRIPTION
      Takes in a vCenter Cluster and creates hosts (if needed) and host group
    .INPUTS
      FlashArray connection, a vCenter cluster, and iSCSI/FC option
    .OUTPUTS
      Returns success or failure.
    .NOTES
      Version:        2.0
      Author:         Cody Hosterman https://codyhosterman.com
      Creation Date:  05/26/2019
      Purpose/Change: Updated for new connection mgmt
  
    *******Disclaimer:******************************************************
    This scripts are offered "as is" with no warranty.  While this 
    scripts is tested and working in my environment, it is recommended that you test 
    this script in a test lab before using in a production environment. Everyone can 
    use the scripts/commands provided here without any written permission but I
    will not be liable for any damage or loss to the system.
    ************************************************************************
    #>

    [CmdletBinding()]
    Param(
        [Parameter(Position=0,mandatory=$true)]
        [VMware.VimAutomation.ViCore.Types.V1.Inventory.Cluster]$cluster,
        
        [Parameter(Position=1)]
        [string]$protocolType,

        [Parameter(Position=2,ValueFromPipeline=$True)]
        [PurePowerShell.PureArray[]]$flasharray,

        [Parameter(Position=3)]
        [switch]$iscsi,

        [Parameter(Position=4)]
        [switch]$fc
    )
    Begin {
      if (($protocolType -eq "FC") -and ($protocolType -eq "iSCSI"))
      {
          Write-Warning -Message "The protocolType parameter is being deprecated, please use the -fc or -iscsi switch parameters instead."
      }
      if (($protocolType -ne "FC") -and ($protocolType -ne "iSCSI") -and ($iscsi -ne $true) -and ($protocolType -ne $true))
      {
          throw 'No valid protocol entered. Please add the -fc or -iscsi switch parameter"'
      }
      if (($iscsi -eq $true) -and ($protocolType -eq $true))
      {
          throw "You cannot use both the -fc and -iscsi switch"
      }
      if (($iscsi -eq $true) -and ($protocolType -eq "FC"))
      {
          throw "You cannot use the iSCSI switch parameter and specify FC in the protocolType option. The protocolType parameter is being deprecated."
      }
      if (($fc -eq $true) -and ($protocolType -eq "iSCSI"))
      {
          throw "You cannot use the FC switch parameter and specify iSCSI in the protocolType option. The protocolType parameter is being deprecated."
      }
      if ($protocolType -eq "FC")
      {
        $fc = $true
      }
      if ($protocolType -eq "iSCSI")
      {
        $iscsi = $true
      }
      $pfaHostGroups = @()
    } 
    Process 
    {
        if ($null -eq $flasharray)
        {
          $flasharray = checkDefaultFlashArray
        }
        foreach ($fa in $flasharray)
        {

            $hostGroup =  Get-PfaHostGroupfromVcCluster -flasharray $fa -ErrorAction SilentlyContinue -cluster $cluster
            if ($hostGroup.count -gt 1)
            {
                throw "The cluster already is configured on the FlashArray and spans more than one host group. This cmdlet does not support a multi-hostgroup configuration."
            }
            if ($null -ne $hostGroup)
            {
                $clustername = $hostGroup.name
            }
            $esxiHosts = $cluster |Get-VMHost
            $faHosts = @()
            foreach ($esxiHost in $esxiHosts)
            {
                $faHost = $null
                try {
                  $faHost = Get-PfaHostFromVmHost -flasharray $fa -esxi $esxiHost
                  if ($null -ne $faHost.hgroup)
                  {
                      if ($null -ne $hostGroup)
                      {
                          if ($hostGroup.name -ne $faHost.hgroup)
                          {
                            throw "The host $($faHost.name) already exists and is already in the host group $($faHost.hgroup). Ending workflow."
                          }
                      }
                  }
                }
                catch {}
                if ($null -eq $faHost)
                {
                    try {
                        $faHost = New-PfaHostFromVmHost -flasharray $fa -iscsi:$iscsi -fc:$fc -ErrorAction Stop -esxi $esxiHost
                        $faHosts += $faHost
                    }
                    catch {
                        Write-Error $Global:Error[0]
                        throw "Could not create host. Cannot create host group." 
                    }
                }
                else {
                    $faHosts += $faHost
                }
            }
            #FlashArray only supports Alphanumeric or the dash - character in host group names. Checking for VMware cluster name compliance and removing invalid characters.
            if ($null -eq $hostGroup)
            {
                if ($cluster.Name -match "^[a-zA-Z0-9\-]+$")
                {
                    $clustername = $cluster.Name
                }
                else
                {
                    $clustername = $cluster.Name -replace "[^\w\-]", ""
                    $clustername = $clustername -replace "[_]", ""
                    $clustername = $clustername -replace " ", ""
                }
                $hg = Get-PfaHostGroup -Array $fa -Name $clustername -ErrorAction SilentlyContinue
                if ($null -ne $hg)
                {
                    if ($hg.hosts.count -ne 0)
                    {
                        #if host group name is already in use and has only unexpected hosts i will create a new one with a random number at the end
                        $nameRandom = Get-random -Minimum 1000 -Maximum 9999
                        $hostGroup = New-PfaHostGroup -Array $fa -Name "$($clustername)-$($nameRandom)" -ErrorAction stop
                        $clustername = "$($clustername)-$($nameRandom)"
                    }
                }
                else {
                    #if there is no host group, it will be created
                    $hostGroup = New-PfaHostGroup -Array $fa -Name $clustername -ErrorAction stop
                }
            }
            $faHostNames = @()
            foreach ($faHost in $faHosts)
            {
                if ($null -eq $faHost.hgroup)
                {
                    $faHostNames += $faHost.name
                }
            }
            #any hosts that are not already in the host group will be added
            Add-PfaHosts -Array $fa -Name $clustername -HostsToAdd $faHostNames -ErrorAction Stop |Out-Null
            $Global:CurrentFlashArray = $fa
            $fahostGroup = Get-PfaHostGroup -Array $fa -Name $clustername
            $pfaHostGroups += $fahostGroup
        }
    }
    End 
    {
      return $pfaHostGroups
    }   
}
function Set-VmHostPfaiSCSI{
    <#
    .SYNOPSIS
      Configure FlashArray iSCSI target information on ESXi host
    .DESCRIPTION
      Takes in an ESXi host and configures FlashArray iSCSI target info
    .INPUTS
      FlashArray connection and an ESXi host
    .OUTPUTS
      Returns ESXi iSCSI targets.
    .NOTES
      Version:        2.0
      Author:         Cody Hosterman https://codyhosterman.com
      Creation Date:  05/26/2019
      Purpose/Change: Updated for new connection mgmt
  
    *******Disclaimer:******************************************************
    This scripts are offered "as is" with no warranty.  While this 
    scripts is tested and working in my environment, it is recommended that you test 
    this script in a test lab before using in a production environment. Everyone can 
    use the scripts/commands provided here without any written permission but I
    will not be liable for any damage or loss to the system.
    ************************************************************************
    #>

    [CmdletBinding()]
    Param(
        [Parameter(Position=0,mandatory=$true)]
        [VMware.VimAutomation.ViCore.Types.V1.Inventory.VMHost]$esxi,

        [Parameter(Position=1,ValueFromPipeline=$True)]
        [PurePowerShell.PureArray[]]$flasharray
    )
    Begin {
      $allESXitargets = @()
    }
    Process {
        if ($null -eq $flasharray)
        {
          $flasharray = checkDefaultFlashArray
        }
        foreach ($fa in $flasharray)
        {
            if ($esxi.ExtensionData.Runtime.ConnectionState -ne "connected")
            {
                Write-Warning "Host $($esxi.NetworkInfo.HostName) is not in a connected state and cannot be configured."
                return
            }
            $ESXitargets = @()
            $faiSCSItargets = Get-PfaNetworkInterfaces -Array $fa |Where-Object {$_.services -eq "iscsi"} |Where-Object {$_.enabled -eq $true} | Where-Object {$null -ne $_.address}
            if ($null -eq $faiSCSItargets)
            {
                throw "The target FlashArray does not currently have any iSCSI targets configured."
            }
            $iscsi = $esxi |Get-VMHostStorage
            if ($iscsi.SoftwareIScsiEnabled -ne $true)
            {
                $esxi | Get-vmhoststorage |Set-VMHostStorage -SoftwareIScsiEnabled $True |out-null
            }
            foreach ($faiSCSItarget in $faiSCSItargets)
            {
                $iscsiadapter = $esxi | Get-VMHostHba -Type iScsi | Where-Object {$_.Model -eq "iSCSI Software Adapter"}
                if (!(Get-IScsiHbaTarget -IScsiHba $iscsiadapter -Type Send -ErrorAction stop | Where-Object {$_.Address -cmatch $faiSCSItarget.address}))
                {
                    New-IScsiHbaTarget -IScsiHba $iscsiadapter -Address $faiSCSItarget.address -ErrorAction stop 
                }
                $esxcli = $esxi |Get-esxcli -v2 
                $iscsiargs = $esxcli.iscsi.adapter.discovery.sendtarget.param.get.CreateArgs()
                $iscsiargs.adapter = $iscsiadapter.Device
                $iscsiargs.address = $faiSCSItarget.address
                $delayedAck = $esxcli.iscsi.adapter.discovery.sendtarget.param.get.invoke($iscsiargs) |where-object {$_.name -eq "DelayedAck"}
                $loginTimeout = $esxcli.iscsi.adapter.discovery.sendtarget.param.get.invoke($iscsiargs) |where-object {$_.name -eq "LoginTimeout"}
                if ($delayedAck.Current -eq "true")
                {
                    $iscsiargs = $esxcli.iscsi.adapter.discovery.sendtarget.param.set.CreateArgs()
                    $iscsiargs.adapter = $iscsiadapter.Device
                    $iscsiargs.address = $faiSCSItarget.address
                    $iscsiargs.value = "false"
                    $iscsiargs.key = "DelayedAck"
                    $esxcli.iscsi.adapter.discovery.sendtarget.param.set.invoke($iscsiargs) |out-null
                }
                if ($loginTimeout.Current -ne "30")
                {
                    $iscsiargs = $esxcli.iscsi.adapter.discovery.sendtarget.param.set.CreateArgs()
                    $iscsiargs.adapter = $iscsiadapter.Device
                    $iscsiargs.address = $faiSCSItarget.address
                    $iscsiargs.value = "30"
                    $iscsiargs.key = "LoginTimeout"
                    $esxcli.iscsi.adapter.discovery.sendtarget.param.set.invoke($iscsiargs) |out-null
                }
                $ESXitargets += Get-IScsiHbaTarget -IScsiHba $iscsiadapter -Type Send -ErrorAction stop | Where-Object {$_.Address -cmatch $faiSCSItarget.address}
            }
            $allESXitargets += $ESXitargets
            $Global:CurrentFlashArray = $fa
          }
    }
    End {
      return $allESXitargets
    }  
}
function Set-ClusterPfaiSCSI {
    <#
    .SYNOPSIS
      Configure an ESXi cluster with FlashArray iSCSI information
    .DESCRIPTION
      Takes in a vCenter Cluster and configures iSCSI on each host.
    .INPUTS
      FlashArray connection and a vCenter cluster.
    .OUTPUTS
      Returns iSCSI targets.
    .NOTES
      Version:        2.0
      Author:         Cody Hosterman https://codyhosterman.com
      Creation Date:  05/26/2019
      Purpose/Change: Updated for new connection mgmt
  
    *******Disclaimer:******************************************************
    This scripts are offered "as is" with no warranty.  While this 
    scripts is tested and working in my environment, it is recommended that you test 
    this script in a test lab before using in a production environment. Everyone can 
    use the scripts/commands provided here without any written permission but I
    will not be liable for any damage or loss to the system.
    ************************************************************************
    #>

    [CmdletBinding()]
    Param(
        [Parameter(Position=0,mandatory=$true)]
        [VMware.VimAutomation.ViCore.Types.V1.Inventory.Cluster]$cluster,

        [Parameter(Position=1,ValueFromPipeline=$True)]
        [PurePowerShell.PureArray[]]$flasharray
    )
    Begin {
      $allEsxiiSCSItargets = @()
    }
    Process 
    {
        if ($null -eq $flasharray)
        {
          $flasharray = checkDefaultFlashArray
        }
        foreach ($fa in $flasharray)
        {
            $esxihosts = $cluster |Get-VMHost
            $esxiiSCSItargets = @()
            $hostCount = 0
            foreach ($esxihost in $esxihosts)
            {
                if ($hostCount -eq 0)
                {
                    Write-Progress -Activity "Configuring iSCSI" -status "Host: $esxihost" -percentComplete 0
                }
                else {
                    Write-Progress -Activity "Configuring iSCSI" -status "Host: $esxihost" -percentComplete (($hostCount / $esxihosts.count) *100)
                }
                $esxiiSCSItargets +=  Set-vmHostPfaiSCSI -flasharray $fa -esxi $esxihost 
                $hostCount++
            }
            $allEsxiiSCSItargets += $esxiiSCSItargets
            $Global:CurrentFlashArray = $fa
        }
    }
    End 
    { 
      return $allEsxiiSCSItargets
    }
}
function Initialize-PfaVcfWorkloadDomain {
  <#
  .SYNOPSIS
    Configures a workload domain for Pure Storage
  .DESCRIPTION
    Connects to each ESXi host, configures initiators on the FlashArray and provisions a VMFS. If something fails it will cleanup any changes.
  .INPUTS
    FQDNs or IPs of each host, valid credentials, a FlashArray connection, a datastore name and size.
  .OUTPUTS
    Returns host group.
  .NOTES
    Version:        1.0
    Author:         Cody Hosterman https://codyhosterman.com
    Creation Date:  11/12/2019
    Purpose/Change: New cmdlet
  .EXAMPLE
    PS C:\ $faCreds = get-credential
    PS C:\ New-PfaConnection -endpoint flasharray-m20-2 -credentials $faCreds -ignoreCertificateError -defaultArray
    PS C:\ $creds = get-credential
    PS C:\ Initialize-PfaVcfWorkloadDomain -esxiHosts "esxi-02.purecloud.com","esxi-04.purecloud.com" -credentials $creds -datastoreName "vcftest" -sizeInTB 16 -fc
    
    Creates a host group and hosts and provisions a 16 TB VMFS to the hosts over FC
  .EXAMPLE
    PS C:\ $faCreds = get-credential
    PS C:\ New-PfaConnection -endpoint flasharray-m20-2 -credentials $faCreds -ignoreCertificateError -defaultArray
    PS C:\ $creds = get-credential
    PS C:\ $allHosts = @()
    PS C:\ Import-Csv C:\hostList.csv | ForEach-Object {$allHosts += $_.hostnames} 
    PS C:\ Initialize-PfaVcfWorkloadDomain -esxiHosts $allHosts -credentials $creds -datastoreName "vcftest" -sizeInTB 16 -fc
    
    Creates a host group and hosts and provisions a 16 TB VMFS to the hosts over FC. This takes in a csv file of ESXi host FQDNs with one csv header called hostnames
  
  *******Disclaimer:******************************************************
  This scripts are offered "as is" with no warranty.  While this 
  scripts is tested and working in my environment, it is recommended that you test 
  this script in a test lab before using in a production environment. Everyone can 
  use the scripts/commands provided here without any written permission but I
  will not be liable for any damage or loss to the system.
  ************************************************************************
  #>

  [CmdletBinding()]
  Param(

      [Parameter(Position=0,mandatory=$true)]
      [string[]]$esxiHosts,

      [Parameter(Position=1,ValueFromPipeline=$True,mandatory=$true)]
      [System.Management.Automation.PSCredential]$credentials,

      [Parameter(Position=1,ValueFromPipeline=$True)]
      [PurePowerShell.PureArray]$flasharray,

      [Parameter(Position=2,mandatory=$true)]
      [string]$datastoreName,

      [Parameter(Position=3)]
      [int]$sizeInGB,

      [Parameter(Position=4)]
      [int]$sizeInTB,

      [Parameter(Position=5)]
      [switch]$fc
    
  )
  if ($fc -ne $true)
  {
    throw "Please indicate protocol type. Currently only -fc is a supported option."
  }
  $ErrorActionPreference = "stop"
  if (($sizeInGB -eq 0) -and ($sizeInTB -eq 0))
  {
      throw "Please enter a size in GB or TB"
  }
  elseif (($sizeInGB -ne 0) -and ($sizeInTB -ne 0)) {
      throw "Please only enter a size in TB or GB, not both."
  }
  elseif ($sizeInGB -ne 0) {
      $volSize = $sizeInGB * 1024 *1024 *1024   
  }
  else {
      $volSize = $sizeInTB * 1024 *1024 *1024 * 1024
  }
  if ($null -eq $flasharray)
  {
    $flasharray = checkDefaultFlashArray
  }
  $esxiConnections = @()
  for ($i =0;$i -lt $esxiHosts.count;$i++)
  {
    try {
         $esxiConnections += connect-viserver -Server $esxiHosts[$i] -Credential ($Credentials) -ErrorAction Stop
    }
    catch
    {
      $scriptCleanupStep = 0
      cleanup-pfaVcf
    }
  }
  $faHosts = @()
  for ($i =0;$i -lt $esxiConnections.count;$i++)
  {
    $foundHost = $null
    try {
        $foundHost = Get-PfaHostFromVmHost -esxi (get-vmhost $esxiConnections[$i].name) 
        if ($null -ne $foundHost)
        {
          if ($faHosts.count -ge 1)
          {
            $scriptCleanupStep = 1
          }
          else
          {
            $scriptCleanupStep = 6
          }
          $esxiName =$esxiConnections[$i].name
          cleanup-pfaVcf
          $newError =   ("The host " + $esxiName + " already exists on the FlashArray. Ensure you entered the right host and/or array")
          throw ""
        }
    }
    catch {
      if ($null -ne $newError)
      {
        throw $newError
      }
    }
    try{
      $faHosts += (New-PfaHostFromVmHost -esxi (get-vmhost $esxiConnections[$i].name) -FC:$fc -ErrorAction Stop).name
    }
    catch
    { 
        $scriptCleanupStep = 1
        cleanup-pfaVcf
        throw $_.Exception
    }      
  }
  $groupName = ("vCF-WorkloadDomain-" + (get-random -Maximum 9999 -Minimum 1000))
  try{
    $hostGroup = New-PfaHostGroup -Array $flasharray -Hosts $fahosts -Name $groupName -ErrorAction Stop
  }
  catch
  {
     $scriptCleanupStep = 2
     cleanup-pfaVcf
     throw $_.Exception
  }
  try
  {
      $newVol = New-PfaVolume -Array $flasharray -Size $volSize -VolumeName $datastoreName -ErrorAction Stop
  }
  catch
  {
      $scriptCleanupStep = 3
      cleanup-pfaVcf
      throw $_.Exception
  }
  $Global:CurrentFlashArray = $flasharray
  try
  {
      New-PfaHostGroupVolumeConnection -Array $flasharray -VolumeName $newVol.name -HostGroupName $groupName -ErrorAction Stop|Out-Null
  }
  catch
  {
      $scriptCleanupStep = 4
      cleanup-pfaVcf
      throw $_.Exception
  }
  $newNAA =  "naa.624a9370" + $newVol.serial.toLower()
  $esxi = $esxiConnections |Select-Object -Last 1
  get-vmhost $esxi.name |Get-VMHostStorage -RescanAllHba  |Out-Null
  try 
  {
      $newVMFS = get-vmhost $esxi.name |new-datastore -name $datastoreName -vmfs -Path $newNAA -FileSystemVersion 6 -ErrorAction Stop
  }
  catch 
  {
      $scriptCleanupStep = 5
      cleanup-pfaVcf
      throw $_.Exception
  }
  foreach ($esxiConnection in $esxiConnections)
  {
     get-vmhost $esxiConnection.name | Get-VMHostStorage -RescanAllHba  |Out-Null
  } 
  $scriptCleanupStep = 7
  cleanup-pfaVcf
  return $hostGroup
}


#aliases to not break compatibility with original cmdlet names
New-Alias -Name New-pureflasharrayRestSession -Value New-PfaRestSession
New-Alias -Name remove-pureflasharrayRestSession -Value remove-PfaRestSession
New-Alias -Name New-faHostFromVmHost -Value New-PfaHostFromVmHost
New-Alias -Name Get-faHostFromVmHost -Value Get-PfaHostFromVmHost
New-Alias -Name Get-faHostGroupfromVcCluster -Value Get-PfaHostGroupfromVcCluster 
New-Alias -Name New-faHostGroupfromVcCluster -Value New-PfaHostGroupfromVcCluster
New-Alias -Name Set-vmHostPureFaiSCSI -Value Set-vmHostPfaiSCSI
New-Alias -Name Set-clusterPureFAiSCSI -Value Set-clusterPfaiSCSI


#### helper functions
function cleanup-pfaVcf{
  if ($scriptCleanupStep -lt 6)
  {
    if ($scriptCleanupStep -eq 5)
    {
        Remove-PfaHostGroupVolumeConnection -Array $flasharray -VolumeName $datastoreName -HostGroupName $groupName |Out-Null
    }
    if ($scriptCleanupStep -ge 4)
    {
      Remove-PfaVolumeOrSnapshot -Array $flasharray -Name $datastoreName |Out-Null
      Remove-PfaVolumeOrSnapshot -Array $flasharray -Name $datastoreName -Eradicate |Out-Null
    }
    if ($scriptCleanupStep -ge 1)
    {
      foreach ($faHost in $faHosts)
      {
        Remove-PfaHost -Array $flasharray -Name $faHost |out-null
      }
    }
    if ($scriptCleanupStep -ge 3)
    {
      remove-PfaHostGroup -Array $flasharray -Name $groupName |out-null
    }
  }
  if ($scriptCleanupStep -ge 0)
  {
    if ($esxiConnections.count -eq 0)
    {
      return
    }
    else
    {
        foreach ($esxiConnection in $esxiConnections)
        {
          $esxiConnection | disconnect-viserver -confirm:$false |out-null
        }
    }
  }
  return
}
function checkDefaultFlashArray{
    if ($null -eq $Global:DefaultFlashArray)
    {
        throw "You must pass in a FlashArray connection or create a default FlashArray connection with New-Pfaconnection"
    }
    else 
    {
        return $Global:DefaultFlashArray
    }
}
function getAllFlashArrays {
  if ($null -ne $Global:AllFlashArrays)
  {
      return $Global:AllFlashArrays
  }
  else
  {
      throw "Please either pass in one or more FlashArray connections or create connections via the New-PfaConnection cmdlet."
  }
}
Function Get-SSLThumbprint {
  param(
  [Parameter(
      Position=0,
      Mandatory=$true,
      ValueFromPipeline=$true,
      ValueFromPipelineByPropertyName=$true)
  ]
  [Alias('FullName')]
  [String]$URL
  )

add-type @"
      using System.Net;
      using System.Security.Cryptography.X509Certificates;
          public class IDontCarePolicy : ICertificatePolicy {
          public IDontCarePolicy() {}
          public bool CheckValidationResult(
              ServicePoint sPoint, X509Certificate cert,
              WebRequest wRequest, int certProb) {
              return true;
          }
      }
"@
  [System.Net.ServicePointManager]::CertificatePolicy = New-object IDontCarePolicy

  # Need to connect using simple GET operation for this to work
  Invoke-RestMethod -Uri $URL -Method Get | Out-Null

  $ENDPOINT_REQUEST = [System.Net.Webrequest]::Create("$URL")
  $SSL_THUMBPRINT = $ENDPOINT_REQUEST.ServicePoint.Certificate.GetCertHashString()

  return $SSL_THUMBPRINT -replace '(..(?!$))','$1:'
}

