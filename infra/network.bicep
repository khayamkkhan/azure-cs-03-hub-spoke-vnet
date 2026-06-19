// =============================================================================
// network.bicep — Hub-and-spoke topology for Project 03
// Deploys: 3 VNets (hub + 2 spokes), NSGs + ASGs, hub<->spoke peering,
//          Azure Bastion, 3 test VMs (no public IP), Storage + Private Endpoint.
// Scope:   resource group  (deploy into rg-network-lab)
// Region:  eastus (must match the log-portfolio-baseline Log Analytics workspace)
// =============================================================================
targetScope = 'resourceGroup'

@description('Azure region — keep aligned with the baseline Log Analytics workspace')
param location string = resourceGroup().location

@description('Admin username for the test VMs')
param adminUsername string = 'azureuser'

@description('Admin password for the test VMs (12+ chars, 3 of 4 complexity classes)')
@secure()
param adminPassword string

@description('Windows timezone id for VM auto-shutdown (PHT = UTC+8)')
param shutdownTimeZone string = 'Singapore Standard Time'

@description('Daily auto-shutdown time, HHmm 24h')
param shutdownTime string = '1900'

@description('Deploy the 3 segmentation-test VMs. Default false — VMs need core quota a new PAYG sub lacks. Deploy the network first, request quota, then set true to add them.')
param deployTestVms bool = false

@description('Common resource tags — keys required by the baseline tag policy (owner/environment/project)')
param tags object = {
  owner: 'khayam'
  environment: 'lab'
  project: 'hub-spoke'
}

// ---------- Address space ----------
var bastionSubnetPrefix = '10.0.1.0/26'

var vnetHubName = 'vnet-hub'
var vnetWorkloadName = 'vnet-spoke-workload'
var vnetMgmtName = 'vnet-spoke-mgmt'

// ==================== Application Security Groups ====================
resource asgWeb 'Microsoft.Network/applicationSecurityGroups@2023-11-01' = {
  name: 'asg-web'
  location: location
  tags: tags
}

resource asgData 'Microsoft.Network/applicationSecurityGroups@2023-11-01' = {
  name: 'asg-data'
  location: location
  tags: tags
}

// ==================== Network Security Groups ====================
var denyAllInbound = {
  name: 'deny-all-inbound'
  properties: {
    priority: 4096
    direction: 'Inbound'
    access: 'Deny'
    protocol: '*'
    sourceAddressPrefix: '*'
    sourcePortRange: '*'
    destinationAddressPrefix: '*'
    destinationPortRange: '*'
  }
}

// Allow Bastion to reach VMs over SSH (Bastion initiates from AzureBastionSubnet).
var allowBastionSsh = {
  name: 'allow-bastion-ssh'
  properties: {
    priority: 110
    direction: 'Inbound'
    access: 'Allow'
    protocol: 'Tcp'
    sourceAddressPrefix: bastionSubnetPrefix
    sourcePortRange: '*'
    destinationAddressPrefix: '*'
    destinationPortRange: '22'
  }
}

resource nsgWeb 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: 'nsg-web'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'allow-https-inbound'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationApplicationSecurityGroups: [{ id: asgWeb.id }]
          destinationPortRange: '443'
        }
      }
      allowBastionSsh
      denyAllInbound
    ]
  }
}

resource nsgData 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: 'nsg-data'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'allow-sql-from-web'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceApplicationSecurityGroups: [{ id: asgWeb.id }]
          sourcePortRange: '*'
          destinationApplicationSecurityGroups: [{ id: asgData.id }]
          destinationPortRange: '1433'
        }
      }
      allowBastionSsh
      denyAllInbound
    ]
  }
}

resource nsgJumpbox 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: 'nsg-jumpbox'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'allow-bastion-ssh'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: bastionSubnetPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '22'
        }
      }
      denyAllInbound
    ]
  }
}

// ==================== Virtual Networks ====================
module vnetHub 'modules/vnet.bicep' = {
  name: 'deploy-vnet-hub'
  params: {
    name: vnetHubName
    location: location
    addressPrefix: '10.0.0.0/16'
    tags: tags
    subnets: [
      { name: 'AzureBastionSubnet', prefix: bastionSubnetPrefix } // NO NSG on Bastion subnet
      { name: 'snet-shared', prefix: '10.0.2.0/24' }
    ]
  }
}

module vnetWorkload 'modules/vnet.bicep' = {
  name: 'deploy-vnet-workload'
  params: {
    name: vnetWorkloadName
    location: location
    addressPrefix: '10.1.0.0/16'
    tags: tags
    subnets: [
      { name: 'snet-web', prefix: '10.1.1.0/24', nsgId: nsgWeb.id }
      { name: 'snet-data', prefix: '10.1.2.0/24', nsgId: nsgData.id, peNetworkPolicies: 'Disabled' }
      { name: 'snet-appsvc', prefix: '10.1.3.0/24', delegation: 'Microsoft.Web/serverFarms' }
    ]
  }
}

module vnetMgmt 'modules/vnet.bicep' = {
  name: 'deploy-vnet-mgmt'
  params: {
    name: vnetMgmtName
    location: location
    addressPrefix: '10.2.0.0/16'
    tags: tags
    subnets: [
      { name: 'snet-jumpbox', prefix: '10.2.1.0/24', nsgId: nsgJumpbox.id }
    ]
  }
}

// ---------- subnet id lookups ----------
var bastionSubnetId = vnetHub.outputs.subnetIds.AzureBastionSubnet
var webSubnetId = vnetWorkload.outputs.subnetIds['snet-web']
var dataSubnetId = vnetWorkload.outputs.subnetIds['snet-data']
var appsvcSubnetId = vnetWorkload.outputs.subnetIds['snet-appsvc']
var jumpSubnetId = vnetMgmt.outputs.subnetIds['snet-jumpbox']

// ==================== VNet Peering (hub <-> each spoke, NO spoke<->spoke) ====================
resource peerHubToWorkload 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-11-01' = {
  name: '${vnetHubName}/peer-hub-to-workload'
  dependsOn: [vnetHub] // remote (vnetWorkload) is already implicit via remoteVirtualNetwork
  properties: {
    remoteVirtualNetwork: { id: vnetWorkload.outputs.id }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: true
    useRemoteGateways: false
  }
}

resource peerWorkloadToHub 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-11-01' = {
  name: '${vnetWorkloadName}/peer-workload-to-hub'
  dependsOn: [vnetWorkload] // remote (vnetHub) is already implicit via remoteVirtualNetwork
  properties: {
    remoteVirtualNetwork: { id: vnetHub.outputs.id }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: false
    useRemoteGateways: false // no hub gateway yet; flip to true when a VPN/ER gateway is added
  }
}

resource peerHubToMgmt 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-11-01' = {
  name: '${vnetHubName}/peer-hub-to-mgmt'
  dependsOn: [vnetHub, peerHubToWorkload] // parent + serialize hub peerings; remote (vnetMgmt) is implicit
  properties: {
    remoteVirtualNetwork: { id: vnetMgmt.outputs.id }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: true
    useRemoteGateways: false
  }
}

resource peerMgmtToHub 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-11-01' = {
  name: '${vnetMgmtName}/peer-mgmt-to-hub'
  dependsOn: [vnetMgmt] // remote (vnetHub) is already implicit via remoteVirtualNetwork
  properties: {
    remoteVirtualNetwork: { id: vnetHub.outputs.id }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: false
    useRemoteGateways: false
  }
}

// ==================== Azure Bastion (hub) ====================
resource bastionPip 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: 'pip-bastion'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource bastion 'Microsoft.Network/bastionHosts@2023-11-01' = {
  name: 'bastion-hub'
  location: location
  tags: tags
  sku: { name: 'Standard' } // Standard required for native client + file transfer
  properties: {
    ipConfigurations: [
      {
        name: 'bastionIpConfig'
        properties: {
          subnet: { id: bastionSubnetId }
          publicIPAddress: { id: bastionPip.id }
        }
      }
    ]
  }
}

// ==================== Test VMs (no public IPs — Bastion only) ====================
module vmWeb 'modules/vm.bicep' = if (deployTestVms) {
  name: 'deploy-vm-web-01'
  params: {
    name: 'vm-web-01'
    location: location
    subnetId: webSubnetId
    asgId: asgWeb.id
    adminUsername: adminUsername
    adminPassword: adminPassword
    tags: tags
  }
}

module vmData 'modules/vm.bicep' = if (deployTestVms) {
  name: 'deploy-vm-data-01'
  params: {
    name: 'vm-data-01'
    location: location
    subnetId: dataSubnetId
    asgId: asgData.id
    adminUsername: adminUsername
    adminPassword: adminPassword
    tags: tags
  }
}

module vmJump 'modules/vm.bicep' = if (deployTestVms) {
  name: 'deploy-vm-jump-01'
  params: {
    name: 'vm-jump-01'
    location: location
    subnetId: jumpSubnetId
    asgId: '' // jumpbox has no ASG
    adminUsername: adminUsername
    adminPassword: adminPassword
    tags: tags
  }
}

// ---------- auto-shutdown schedules (cost control) ----------
resource shutdownWeb 'Microsoft.DevTestLab/schedules@2018-09-15' = if (deployTestVms) {
  name: 'shutdown-computevm-vm-web-01'
  location: location
  tags: tags
  properties: {
    status: 'Enabled'
    taskType: 'ComputeVmShutdownTask'
    dailyRecurrence: { time: shutdownTime }
    timeZoneId: shutdownTimeZone
    targetResourceId: vmWeb!.outputs.id // ! : same deployTestVms condition as the schedule, so never null here
  }
}

resource shutdownData 'Microsoft.DevTestLab/schedules@2018-09-15' = if (deployTestVms) {
  name: 'shutdown-computevm-vm-data-01'
  location: location
  tags: tags
  properties: {
    status: 'Enabled'
    taskType: 'ComputeVmShutdownTask'
    dailyRecurrence: { time: shutdownTime }
    timeZoneId: shutdownTimeZone
    targetResourceId: vmData!.outputs.id
  }
}

resource shutdownJump 'Microsoft.DevTestLab/schedules@2018-09-15' = if (deployTestVms) {
  name: 'shutdown-computevm-vm-jump-01'
  location: location
  tags: tags
  properties: {
    status: 'Enabled'
    taskType: 'ComputeVmShutdownTask'
    dailyRecurrence: { time: shutdownTime }
    timeZoneId: shutdownTimeZone
    targetResourceId: vmJump!.outputs.id
  }
}

// ==================== Storage account + Private Endpoint ====================
var storageName = toLower('stcs03${uniqueString(resourceGroup().id)}')

resource storage 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageName
  location: location
  tags: tags
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    publicNetworkAccess: 'Disabled' // reachable only via the Private Endpoint
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
  }
}

resource blobPrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.blob.${environment().suffixes.storage}' // privatelink.blob.core.windows.net
  location: 'global'
  tags: tags
}

resource blobDnsLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: blobPrivateDnsZone
  name: 'link-workload'
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: vnetWorkload.outputs.id }
  }
}

resource storagePe 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name: 'pe-storage-blob'
  location: location
  tags: tags
  properties: {
    subnet: { id: dataSubnetId }
    privateLinkServiceConnections: [
      {
        name: 'plsc-storage-blob'
        properties: {
          privateLinkServiceId: storage.id
          groupIds: ['blob']
        }
      }
    ]
  }
}

resource storagePeDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = {
  parent: storagePe
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'blob'
        properties: { privateDnsZoneId: blobPrivateDnsZone.id }
      }
    ]
  }
}

// ==================== Outputs (consumed by workload.bicep / tests) ====================
output hubVnetId string = vnetHub.outputs.id
output workloadVnetId string = vnetWorkload.outputs.id
output mgmtVnetId string = vnetMgmt.outputs.id
output appsvcSubnetId string = appsvcSubnetId // App Service VNet Integration target
output dataSubnetId string = dataSubnetId // SQL/Storage Private Endpoints
output bastionName string = bastion.name
output storageAccountName string = storage.name
