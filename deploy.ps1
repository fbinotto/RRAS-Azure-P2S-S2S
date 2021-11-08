
[CmdletBinding()]
param (
    [Parameter(Mandatory=$true)]
    [String]
    $subName,
    [Parameter(Mandatory=$true)]
    [String]
    $tenantId
)

# Install required modules
Install-PackageProvider -Name NuGet -Force
Install-Module Az.Resources,Az.Compute,Az.Network -Force -Confirm:$false

# Set variables
$subName                = ''
$tenantId               = ''
$rgName                 = 'Connectivity'
$location               = 'AustraliaEast'
$vnetName               = 'Global-Connect'
$subnetName             = 'IaaS'
$subnetPrefix           = '172.16.0.0/24'
$gatewaySubnetPrefix    = '172.16.255.0/27'
$myPIP                  = (Invoke-WebRequest myexternalip.com/raw).content
$vnetAddressRange       = '172.16.0.0/16'
$vpnAddressPool         = '172.17.0.0/24'
$sharedKey              = 'mySuperS3cr3t123'
$vmPassword             = 'myC0mplexP@ssword'
$localASN               = 64512
$remoteASN              = 65515

# Connect to Azure subscription
Connect-AzAccount -Subscription $subName

# Create Resource Group
$rg = @{
    Name = $rgName
    Location = $location
}
New-AzResourceGroup @rg

# Define subnets
$subnet1 = New-AzVirtualNetworkSubnetConfig -Name 'GatewaySubnet' `
-AddressPrefix $gatewaySubnetPrefix
$subnet2 = New-AzVirtualNetworkSubnetConfig -Name $subnetName `
-AddressPrefix $subnetPrefix

# Create Virtual Network
$vnet = New-AzVirtualNetwork -Name $vnetName -ResourceGroupName $rgName `
-Location $location -AddressPrefix $vnetAddressRange -Subnet $subnet1, $subnet2

# Create Local Network Gateway
$localIP = (Get-NetIPAddress | Where-Object {$_.InterfaceAlias -eq 'Ethernet' `
-and $_.AddressFamily -eq 'ipv4'}).IpAddress
$localGW = New-AzLocalNetworkGateway -Name HomeLab -ResourceGroupName $rgName `
-Location $location -GatewayIpAddress $myPIP -Asn $localASN `
-BgpPeeringAddress $localIP

# Create Virtual Network Gateway
$gwpip = New-AzPublicIpAddress -Name "$vnetName-GWIP" -ResourceGroupName $rgName `
-Location $location -AllocationMethod Dynamic
$vnet = Get-AzVirtualNetwork -Name $vnetName -ResourceGroupName $rgName
$subnet = Get-AzVirtualNetworkSubnetConfig -Name 'GatewaySubnet' -VirtualNetwork $vnet
$gwipconfig = New-AzVirtualNetworkGatewayIpConfig -Name gwipconfig1 -SubnetId $subnet.Id `
-PublicIpAddressId $gwpip.Id
$vnetGW = New-AzVirtualNetworkGateway -Name "$vnetName-GW" -ResourceGroupName $rgName `
-Location $location -IpConfigurations $gwipconfig -GatewayType Vpn -EnableBGP $true `
-VpnType RouteBased -GatewaySku VpnGw1 -Asn $remoteASN `
-VpnClientProtocol OpenVPN -VpnClientAddressPool $vpnAddressPool `
-AadTenantUri "https://login.microsoftonline.com/$tenantId" `
-AadIssuerUri "https://sts.windows.net/$tenantId/" `
-AadAudienceId '41b23e61-6c1e-4545-b367-cd054e0ed4b4'

# Create Virtual Network Gateway Connection
New-AzVirtualNetworkGatewayConnection -Name "$($vnetGW.Name)-$($localGW.Name)" `
-ResourceGroupName $rgName -Location $location -VirtualNetworkGateway1 $vnetGW `
-LocalNetworkGateway2 $localGW -ConnectionType IPsec -RoutingWeight 10 `
-SharedKey $sharedKey -EnableBgp $true

# Install the required Windows Features and Install Remote Access
Install-WindowsFeature -Name RemoteAccess, Routing, RSAT, RSAT-Role-Tools, `
RSAT-RemoteAccess, RSAT-RemoteAccess-PowerShell
Install-RemoteAccess -VpnType VpnS2S
Start-Sleep 3

# Create S2S Connection
$gwpip = Get-AzPublicIpAddress -Name "$vnetName-GWIP" -ResourceGroupName $rgName
Add-VpnS2SInterface -Name 'Azure' $gwpip.IpAddress -Protocol IKEv2 `
-AuthenticationMethod PSKOnly -SharedSecret $sharedKey `
-IPv4Subnet @("$($vnetAddressRange):100" ,"$($vpnAddressPool):100")

# Create BGP Router and Peer
Add-BgpRouter -BgpIdentifier $localIP -LocalASN $localASN
Add-BgpPeer -Name AzureS2S -LocalIPAddress $localIP `
-PeerIPAddress $($vnetGW.BgpSettings.BgpPeeringAddress) `
-LocalASN $localASN -PeerASN $remoteASN -PeeringMode Automatic

# Add custom route
Add-BgpCustomRoute -Interface "Ethernet 2" -Network 10.0.2.0/24

Connect-VpnS2SInterface -Name 'Azure'

# Downloads VPN Client Config
$vpnClient = New-AzVpnClientConfiguration -ResourceGroupName Connectivity `
-ResourceName $vnetGW.Name
Invoke-WebRequest -Uri $vpnClient.VpnProfileSASUrl -OutFile .\vpnclientconfig.zip

# Deploy Azure VM
$vmAdminUser = "LocalAdminUser"
$vmSecurePassword = ConvertTo-SecureString $vmPassword -AsPlainText -Force
$nic = New-AzNetworkInterface -Name 'VM01-nic' -ResourceGroupName $rgName `
-Location $location -SubnetId $vnet.Subnets[1].Id
$credential = New-Object System.Management.Automation.PSCredential `
($vmAdminUser, $vmSecurePassword)
$vm = New-AzVMConfig -VMName 'VM01' -VMSize 'Standard_DS1_v2'
$vm = Set-AzVMOperatingSystem -VM $vm -Windows -ComputerName 'VM01' `
-Credential $credential -ProvisionVMAgent -EnableAutoUpdate
$vm = Add-AzVMNetworkInterface -VM $vm -Id $nic.Id
$vm = Set-AzVMSourceImage -VM $vm -PublisherName 'MicrosoftWindowsServer' `
-Offer 'WindowsServer' -Skus '2016-Datacenter' -Version latest

New-AzVM -ResourceGroupName $rgName -Location $location -VM $vm -Verbose
