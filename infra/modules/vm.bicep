// modules/vm.bicep — small Linux test VM with NO public IP.
// NIC lives in the given subnet and (optionally) joins an Application Security Group.
// Reachable only via Azure Bastion. Auto-shutdown is configured by the orchestrator.

@description('VM name (also the computer name)')
param name string

@description('Region')
param location string = resourceGroup().location

@description('Subnet resource id to place the NIC in')
param subnetId string

@description('Optional Application Security Group id to add the NIC to ("" = none)')
param asgId string = ''

@description('VM size — B2pts_v2 is the cheapest ARM64 burstable (x86 B-sizes are capacity-restricted in eastus). Pairs with an ARM64 image below.')
param vmSize string = 'Standard_B2pts_v2'

@description('Admin username')
param adminUsername string

@description('Admin password (12+ chars, 3 of 4 complexity classes)')
@secure()
param adminPassword string

@description('Resource tags')
param tags object = {}

resource nic 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: 'nic-${name}'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: union(
          {
            subnet: { id: subnetId }
            privateIPAllocationMethod: 'Dynamic'
          },
          empty(asgId) ? {} : { applicationSecurityGroups: [{ id: asgId }] }
        )
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    hardwareProfile: { vmSize: vmSize }
    osProfile: {
      computerName: name
      adminUsername: adminUsername
      adminPassword: adminPassword
      linuxConfiguration: {
        disablePasswordAuthentication: false
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-arm64' // ARM64 image to match the Bxpts_v2 (Ampere) size
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: { storageAccountType: 'Standard_LRS' }
      }
    }
    networkProfile: {
      networkInterfaces: [{ id: nic.id }]
    }
  }
}

output id string = vm.id
output name string = vm.name
output nicId string = nic.id
