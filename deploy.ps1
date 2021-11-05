[CmdletBinding()]
param (
    [Parameter(Mandatory=$true)]
    [String]
    $subName
)

Install-PackageProvider -Name NuGet -Force
Install-Module Az -Force -Confirm:$false

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
$localASN               = 64512
$remoteASN              = 65515

Connect-AzAccount -Subscription $subName

$rg = @{
    Name = $rgName
    Location = $location
}
New-AzResourceGroup @rg

$subnet1 = New-AzVirtualNetworkSubnetConfig -Name 'GatewaySubnet' -AddressPrefix $gatewaySubnetPrefix
$subnet2 = New-AzVirtualNetworkSubnetConfig -Name $subnetName -AddressPrefix $subnetPrefix

New-AzVirtualNetwork -Name $vnetName -ResourceGroupName $rgName `
-Location $location -AddressPrefix $vnetAddressRange -Subnet $subnet1, $subnet2

$localGW = New-AzLocalNetworkGateway -Name HomeLab -ResourceGroupName $rgName `
-Location $location -GatewayIpAddress $myPIP -Asn $localASN `
-BgpPeeringAddress $localBGP

$gwpip = New-AzPublicIpAddress -Name "$vnetName-GWIP" -ResourceGroupName $rgName -Location $location -AllocationMethod Dynamic

$vnet = Get-AzVirtualNetwork -Name $vnetName -ResourceGroupName $rgName
$subnet = Get-AzVirtualNetworkSubnetConfig -Name 'GatewaySubnet' -VirtualNetwork $vnet
$gwipconfig = New-AzVirtualNetworkGatewayIpConfig -Name gwipconfig1 -SubnetId $subnet.Id -PublicIpAddressId $gwpip.Id

$vnetGW = New-AzVirtualNetworkGateway -Name "$vnetName-GW" -ResourceGroupName $rgName `
-Location $location -IpConfigurations $gwipconfig -GatewayType Vpn -EnableBGP $true `
-VpnType RouteBased -GatewaySku VpnGw1 -Asn $remoteASN `
-VpnClientProtocol OpenVPN -VpnClientAddressPool $vpnAddressPool `
-AadTenantUri 'https://login.microsoftonline.com/97e11e23-d713-40e6-b2af-33da449e1eab' `
-AadIssuerUri 'https://sts.windows.net/97e11e23-d713-40e6-b2af-33da449e1eab/' `
-AadAudienceId '41b23e61-6c1e-4545-b367-cd054e0ed4b4'

New-AzVirtualNetworkGatewayConnection -Name "$($vnetGW.Name)-$($localGW.Name)" -ResourceGroupName $rgName `
-Location $location -VirtualNetworkGateway1 $vnetGW -LocalNetworkGateway2 $localGW `
-ConnectionType IPsec -RoutingWeight 10 -SharedKey $sharedKey -EnableBgp $true

$cred = (Get-Credential)

$vm1 = @{
    ResourceGroupName       = $rgName
    Location                = $location
    Name                    = 'VM01'
    VirtualNetworkName      = $vnetName
    SubnetName              = $subnetName
    PublicIpAddressName     = 'VM01-pip'
    OpenPorts               = 3389
    Credential              = $cred
    Size                    = 'Standard_DS1_v2'     
}
New-AzVM @vm1 -AsJob

$gwpip = Get-AzPublicIpAddress -Name "$vnetName-GWIP" -ResourceGroupName $rgName

Install-WindowsFeature -Name RemoteAccess, Routing, RSAT, RSAT-Role-Tools, RSAT-RemoteAccess, RSAT-RemoteAccess-PowerShell
Install-RemoteAccess -VpnType VpnS2S
Start-Sleep 3
Add-VpnS2SInterface -Name 'Azure' $gwpip.IpAddress -Protocol IKEv2 -AuthenticationMethod PSKOnly -SharedSecret $sharedKey -IPv4Subnet @("$($vnetAddressRange):100" ,"$($vpnAddressPool):100")

$localIP = (Get-NetIPAddress | Where-Object {$_.InterfaceAlias -eq 'Ethernet' -and $_.AddressFamily -eq 'ipv4'}).IpAddress
Add-BgpRouter -BgpIdentifier $localIP -LocalASN $localASN
Add-BgpPeer -Name AzureS2S -LocalIPAddress $localIP -PeerIPAddress $($vnetGW.BgpSettings.BgpPeeringAddress) -LocalASN $localASN -PeerASN $remoteASN -PeeringMode Automatic

Connect-VpnS2SInterface -Name 'Azure'

$vpnClient = New-AzVpnClientConfiguration -ResourceGroupName Connectivity -ResourceName $vnetGW.Name
Invoke-WebRequest -Uri $vpnClient.VpnProfileSASUrl -OutFile .\vpnclientconfig.zip
