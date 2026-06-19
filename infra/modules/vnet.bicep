// modules/vnet.bicep — reusable virtual network with subnets.
// Each subnet may optionally attach an NSG, a service delegation, and toggle
// private-endpoint network policies.

@description('VNet name')
param name string

@description('Region')
param location string = resourceGroup().location

@description('Single address prefix for the VNet, e.g. 10.0.0.0/16')
param addressPrefix string

@description('''Subnets to create. Each item:
  { name: string, prefix: string, nsgId?: string, delegation?: string, peNetworkPolicies?: string }''')
param subnets array

@description('Resource tags')
param tags object = {}

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [addressPrefix]
    }
    subnets: [
      for s in subnets: {
        name: s.name
        properties: union(
          {
            addressPrefix: s.prefix
          },
          (s.?nsgId != null && !empty(s.?nsgId ?? '')) ? { networkSecurityGroup: { id: s.nsgId } } : {},
          (s.?delegation != null && !empty(s.?delegation ?? '')) ? {
            delegations: [
              {
                name: 'delegation'
                properties: { serviceName: s.delegation }
              }
            ]
          } : {},
          (s.?peNetworkPolicies != null) ? { privateEndpointNetworkPolicies: s.peNetworkPolicies } : {}
        )
      }
    ]
  }
}

output id string = vnet.id
output name string = vnet.name
// name -> subnet resourceId map. resourceId() is deterministic (computable at deployment
// start), so we avoid reading runtime properties off the VNet. Consumers that reference
// this output still get an implicit dependency on this module finishing first.
output subnetIds object = toObject(
  subnets,
  s => s.name,
  s => resourceId('Microsoft.Network/virtualNetworks/subnets', name, s.name)
)
