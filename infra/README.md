# Infrastructure — Project 03 Hub-and-Spoke VNet

All resources are deployed via **Bicep**. Two separate deployments map to two resource groups with different lifecycles:

| File | Resource group | Lifecycle |
|------|----------------|-----------|
| `network.bicep` | `rg-network-lab` | **Rebuildable** — tear down after each session, redeploy in ~8 min |
| `workload.bicep` *(Phase B — next)* | `rg-contoso-webapp` | **Persistent** — stays live through Project 07 |

## Layout
```
infra/
├── network.bicep            # orchestrator: VNets, NSGs+ASGs, peering, Bastion, VMs, Storage PE
├── network.bicepparam       # params (adminPassword supplied at deploy time)
├── workload.bicep           # (Phase B) App Service, SQL, Key Vault, App Insights
└── modules/
    ├── vnet.bicep           # reusable VNet + subnets (optional NSG / delegation / PE policies)
    └── vm.bicep             # reusable Linux test VM, no public IP
```

## Prerequisites
- Azure CLI + Bicep (`az bicep install`)
- Logged in to the portfolio subscription (`az login`)
- Project 01 baseline already deployed (`rg-portfolio-baseline`, `log-portfolio-baseline` in **eastus**)

## Deploy the network

```bash
# 1. Create the (rebuildable) network resource group
az group create --name rg-network-lab --location eastus

# 2. Lint / build — catches syntax + type errors before touching Azure
az bicep build --file network.bicep

# 3. Preview every change (no-drift check, like Project 01)
az deployment group what-if \
  --resource-group rg-network-lab \
  --parameters network.bicepparam \
  --parameters adminPassword='<your-strong-password>'

# 4. Deploy
az deployment group create \
  --resource-group rg-network-lab \
  --parameters network.bicepparam \
  --parameters adminPassword='<your-strong-password>'
```

> **Password rules:** 12–123 chars, 3 of 4 of {lowercase, uppercase, digit, symbol}. Don't commit it.

## Teardown (after each session)

```bash
# Bastion is the cost risk (~$0.19/hr). Deleting the RG removes everything; redeploy from Bicep next time.
az group delete --name rg-network-lab --yes --no-wait
```

## Design notes
- **No spoke-to-spoke peering** — inter-spoke traffic is forced through the hub (Azure Firewall lands there in Project 04).
- **Deny-by-default NSGs** with scoped allows via **ASGs** (`asg-web`, `asg-data`) — rules read as intent, survive IP changes.
- **Bastion-only VM access** — VMs have no public IPs; each VM NSG allows SSH *only* from the `AzureBastionSubnet` (10.0.1.0/26).
- **App Service integration subnet** (`snet-appsvc`) is delegated to `Microsoft.Web/serverFarms` — a delegated subnet can't host VMs, so the web test VM sits in `snet-web` separately.
- **Storage Private Endpoint** in `snet-data` + `privatelink.blob.core.windows.net` private DNS zone; the storage account has `publicNetworkAccess: Disabled`.
