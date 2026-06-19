# Project 03 — Hub-and-Spoke VNet with Bastion + Workload Deploy

> **Pairs with**: AZ-104 Azure Administrator
> **Phase**: 2 — Core Associate
> **Status**: 🔒 Locked until AZ-104 study begins
> **Effort**: 3–4 weekends (~20 hours)
> **Cost**: ~$20–35 if Bastion torn down each session; App Service + SQL stay live at ~$18/month

> [!info] What's new vs original scope
> This project now deploys the **Contoso WebApp** — a 2-tier reference workload (App Service + Azure SQL) that lives inside the spoke VNet and serves as the target for Projects 04–07. The networking build is unchanged. The workload is added in Step 9.

---

## Why This Project

The hub-and-spoke topology is the **default reference architecture** for every Microsoft customer over 100 employees. It's also the model AZ-104, AZ-500, AZ-305, and SC-100 all assume you understand. Build it once, use the diagram in 4 projects.

Deploying the Contoso WebApp here gives Projects 04–07 a real workload to harden — WAF rules, private endpoints, Sentinel detection rules, and Purview classification all become meaningless without an actual application behind them. Every security control in Phase 3 will point at this app.

This is the Azure equivalent of the AWS Project #03 (Secure VPC Architecture).

---

## What You Build

**Networking (Steps 1–8):**
- 1 hub VNet with shared services
- 2 spoke VNets (workload + management)
- VNet peering hub ↔ each spoke (no spoke-to-spoke)
- Azure Bastion in the hub (no public IPs on workload VMs)
- NSGs with deny-by-default + scoped allows
- Application Security Groups (ASGs) for tier-based rules
- Private Endpoint for one Storage Account
- All deployed via **Bicep**

**Contoso WebApp — Persistent Workload (Step 9):**
- **App Service** (B1) with VNet Integration → deployed into workload/web subnet
- **Azure SQL Database** (Basic, 5 DTU) with Private Endpoint → deployed into workload/data subnet
- **Azure Key Vault** → connection string stored as a secret; App Service reads via App Settings reference
- **Application Insights** → wired to App Service; this telemetry feeds Sentinel in Project 05

> [!note] The app itself
> The app code doesn't matter — a bare ASP.NET "Hello World" or the Azure sample Todo app is fine. The point is a running App Service that produces HTTP logs, a SQL database that produces audit logs, and a Key Vault that produces access logs. That telemetry is the real deliverable.

---

## Prerequisites

- Project 01 baseline RG + Log Analytics workspace
- AZ-104 study underway
- Comfortable with Azure CLI

---

## Architecture

```
                    Internet
                       │
               (P04: App Gateway WAF)
                       │
                       ▼
                       ┌────────────────────────┐
                       │  Hub VNet 10.0.0.0/16  │
                       │ ┌──────────────────┐   │
                       │ │ AzureBastion-    │   │
                       │ │ Subnet           │   │
                       │ │ 10.0.1.0/26      │   │
                       │ └──────────────────┘   │
                       │ ┌──────────────────┐   │
                       │ │ Shared services  │   │
                       │ │ 10.0.2.0/24      │   │
                       │ └──────────────────┘   │
                       └────┬───────────────┬───┘
                            │               │
                  Peering   │               │  Peering
                            │               │
        ┌───────────────────▼──┐         ┌──▼──────────────────┐
        │ Workload Spoke       │         │ Management Spoke    │
        │ VNet 10.1.0.0/16     │         │ VNet 10.2.0.0/16    │
        │ ┌──────────────────┐ │         │ ┌─────────────────┐ │
        │ │ web tier         │ │         │ │ jumpbox VM      │ │
        │ │ 10.1.1.0/24      │ │         │ │ 10.2.1.0/24     │ │
        │ │ ASG: web         │ │         │ └─────────────────┘ │
        │ │                  │ │         │  no internet egress │
        │ │ App Service (B1) │ │         └─────────────────────┘
        │ │ VNet Integration │ │
        │ └──────────────────┘ │
        │ ┌──────────────────┐ │
        │ │ data tier        │ │
        │ │ 10.1.2.0/24      │ │
        │ │ ASG: data        │ │
        │ │                  │ │
        │ │ Azure SQL DB     │ │
        │ │ Private Endpoint │ │
        │ │ (P04: public     │ │
        │ │  access removed) │ │
        │ └──────────────────┘ │
        └──────────────────────┘

Supporting resources (not VNet-bound):
  App Insights → App Service
  Key Vault    → App Service (connection string secret)
  App Insights telemetry → Log Analytics → (P05: Sentinel)
```

---

## Build Steps

### 1. Plan the address space

Document in `network-plan.md` BEFORE deploying:

| VNet | CIDR | Subnets |
|------|------|---------|
| `vnet-hub` | 10.0.0.0/16 | AzureBastionSubnet (/26), shared (/24) |
| `vnet-spoke-workload` | 10.1.0.0/16 | web (/24), data (/24) |
| `vnet-spoke-mgmt` | 10.2.0.0/16 | jumpbox (/24) |

Bastion subnet **must** be exactly named `AzureBastionSubnet` and at least /26.

### 2. Deploy networking via Bicep

`main.bicep` modules: `vnet.bicep`, `nsg.bicep`, `bastion.bicep`, `peering.bicep`, `vm.bicep`.

Key NSG rules (all default-deny inbound, scoped allows):

```bicep
// Web tier NSG: allow 443 from internet, 1433 to data tier ASG only
{
  name: 'allow-https-inbound'
  properties: {
    priority: 100
    direction: 'Inbound'
    access: 'Allow'
    protocol: 'Tcp'
    sourceAddressPrefix: 'Internet'
    sourcePortRange: '*'
    destinationApplicationSecurityGroups: [{ id: webAsg.id }]
    destinationPortRange: '443'
  }
}
{
  name: 'deny-all-inbound'
  properties: {
    priority: 4096
    direction: 'Inbound'
    access: 'Deny'
    protocol: '*'
    sourceAddressPrefix: '*'
    destinationAddressPrefix: '*'
    sourcePortRange: '*'
    destinationPortRange: '*'
  }
}
```

### 3. Configure VNet peering

Hub ↔ each spoke. **Critical settings**:
- Allow forwarded traffic: yes (hub-side)
- Allow gateway transit: yes (hub-side, if you add VPN later)
- Use remote gateway: yes (spoke-side)
- **Spoke-to-spoke peering: DO NOT create.** Force traffic through hub firewall (added in Project 04).

### 4. Deploy Azure Bastion (Standard SKU)

Bastion in the hub. Workload VMs have no public IPs — you connect via Bastion → over peering → into spoke. Tear down Bastion between sessions; it's hourly billed.

### 5. Deploy 3 VMs (smallest size, B1s)

- `vm-web-01` in workload/web subnet, ASG `asg-web`
- `vm-data-01` in workload/data subnet, ASG `asg-data`
- `vm-jump-01` in mgmt/jumpbox subnet (no inbound NSG rules; access via Bastion only)

Auto-shutdown all three at 7pm. Cost is ~$0.01/hr each — leave on, scheduled-shutdown handles waste.

### 6. Configure Private Endpoint

Storage account in workload spoke → Private Endpoint in `data` subnet → disable public network access on the storage account. From `vm-data-01`, `nslookup storage.blob.core.windows.net` should resolve to `10.1.2.x`. From your laptop over the internet, the same name resolves to a public IP that returns 403.

### 7. Test the segmentation

| Test | Expected result |
|------|-----------------|
| Bastion → vm-web-01 SSH | ✅ allowed |
| vm-web-01 → vm-data-01 on 1433 | ✅ allowed (ASG rule) |
| vm-web-01 → vm-data-01 on 22 | ❌ denied (NSG default deny) |
| vm-web-01 → vm-jump-01 (cross-spoke) | ❌ denied (no spoke-spoke peering) |
| Internet → vm-web-01 public IP | n/a — VM has no public IP |
| Storage account from internet | ❌ 403 (public network disabled) |

Document each in `tests.md` with screenshots.

### 8. Send NSG flow logs to Log Analytics

NSG → Diagnostic settings → flow logs v2 → `log-portfolio-baseline`. Now you can query:

```kql
AzureNetworkAnalytics_CL
| where SubType_s == "FlowLog"
| where FlowStatus_s == "D"  // denied
| summarize count() by SrcIP_s, DestIP_s, DestPort_d
| sort by count_ desc
```

Every blocked packet is now visible.

### 9. Deploy the Contoso WebApp (Persistent Workload)

This step adds the workload that Projects 04–07 will build on. Deploy into the existing workload spoke.

#### 9a. Create resource group for the workload

```bash
az group create --name rg-contoso-webapp --location australiaeast
```

> [!note] Separate RG deliberately
> Keep workload in its own RG (`rg-contoso-webapp`). The network RG (`rg-network-lab`) gets torn down and rebuilt between sessions. The workload RG stays live through Project 07.

#### 9b. Deploy App Service + App Insights via Bicep

```bicep
// workload.bicep (key resources)
resource appServicePlan 'Microsoft.Web/serverfarms@2022-09-01' = {
  name: 'asp-contoso-webapp'
  sku: { name: 'B1', tier: 'Basic' }
}

resource appService 'Microsoft.Web/sites@2022-09-01' = {
  name: 'app-contoso-webapp-${uniqueString(resourceGroup().id)}'
  properties: {
    serverFarmId: appServicePlan.id
    virtualNetworkSubnetId: webSubnetId  // VNet Integration → web tier subnet
    siteConfig: {
      appSettings: [
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsights.properties.ConnectionString }
        { name: 'SQLDB_CONNECTIONSTRING', value: '@Microsoft.KeyVault(SecretUri=${kvSecret.properties.secretUri})' }
      ]
    }
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: 'ai-contoso-webapp'
  kind: 'web'
  properties: { Application_Type: 'web', WorkspaceResourceId: logAnalyticsId }
}
```

#### 9c. Deploy Azure SQL Database

```bicep
resource sqlServer 'Microsoft.Sql/servers@2022-11-01-preview' = {
  name: 'sql-contoso-${uniqueString(resourceGroup().id)}'
  properties: {
    administratorLogin: 'sqladmin'
    administratorLoginPassword: sqlAdminPassword  // sourced from Key Vault param
    publicNetworkAccess: 'Enabled'  // P04 removes this
  }
}

resource sqlDatabase 'Microsoft.Sql/servers/databases@2022-11-01-preview' = {
  parent: sqlServer
  name: 'db-contoso'
  sku: { name: 'Basic', tier: 'Basic', capacity: 5 }
}

// Enable SQL Audit logs → Log Analytics (feeds Sentinel in P05)
resource sqlAudit 'Microsoft.Sql/servers/auditingSettings@2022-11-01-preview' = {
  parent: sqlServer
  name: 'default'
  properties: {
    state: 'Enabled'
    isAzureMonitorTargetEnabled: true
  }
}
```

#### 9d. Store connection string in Key Vault

```bash
# Create Key Vault
az keyvault create \
  --name kv-contoso-$(az account show --query id -o tsv | cut -c1-8) \
  --resource-group rg-contoso-webapp \
  --location australiaeast

# Store SQL connection string as secret
az keyvault secret set \
  --vault-name <kv-name> \
  --name "SqlConnectionString" \
  --value "Server=tcp:<sql-server>.database.windows.net,1433;Database=db-contoso;..."

# Enable App Service to read Key Vault (system-assigned identity — P06 upgrades this)
az webapp identity assign --name <app-name> --resource-group rg-contoso-webapp
az keyvault set-policy --name <kv-name> \
  --object-id <app-identity-id> \
  --secret-permissions get list
```

#### 9e. Enable diagnostic logging on all three resources

| Resource | Log to send | Destination |
|----------|-------------|-------------|
| App Service | `AppServiceHTTPLogs`, `AppServiceConsoleLogs` | `log-portfolio-baseline` |
| Azure SQL | `SQLSecurityAuditEvents`, `SQLInsights` | `log-portfolio-baseline` |
| Key Vault | `AuditEvent` | `log-portfolio-baseline` |

All three go to the **same** Log Analytics workspace from Project 01. This workspace becomes the Sentinel workspace in Project 05.

#### 9f. Verify the workload is live

| Test | Expected |
|------|----------|
| Browse to App Service URL | App loads, no errors |
| App Insights Live Metrics | HTTP requests visible |
| SQL audit logs in Log Analytics | `SQLSecurityAuditEvents` table has rows after a DB query |
| Key Vault access log | `AzureDiagnostics` shows secret reads from App Service identity |

---

## SOC Value / Attack Scenarios

| Attack | MITRE | Defense in P03 | Upgraded in |
|--------|-------|----------------|-------------|
| Direct internet → DB tier | T1190 | NSG denies non-web inbound; no public IP on DB VM | P04: Private Endpoint removes SQL from internet entirely |
| Lateral movement spoke → spoke | T1021 | No spoke-to-spoke peering; traffic forced through hub | P04: Azure Firewall in hub inspects all inter-spoke traffic |
| Public storage account exfil | T1567.002 | Private endpoint + public access disabled | — |
| SSH brute force on jumpbox | T1110.001 | Jumpbox has no inbound rules; Bastion-only access | — |
| Web app probing / injection | T1190 | App Service publicly accessible (by design at P03) | P04: WAF rules detect + block OWASP Top 10 |
| Credential theft via hardcoded DB string | T1552.001 | Connection string in Key Vault (not in app code) | P06: Managed Identity replaces secret entirely |
| Suspicious Key Vault reads | T1555 | KV access logs → Log Analytics | P05: Sentinel alert fires on anomalous read pattern |

---

## Deliverables Checklist

**Networking:**
- [ ] GitHub repo `azure-cs-03-hub-spoke-vnet`
- [ ] `network-plan.md` (CIDR plan)
- [ ] `bicep/` directory with all modules (networking + workload)
- [ ] `architecture/diagram.png` (updated to include App Service + SQL)
- [ ] `tests.md` with all 6 segmentation tests + 4 workload verification tests + screenshots
- [ ] NSG flow log KQL examples

**Workload:**
- [ ] `bicep/workload.bicep` with App Service, SQL, Key Vault, App Insights
- [ ] Screenshot: App Insights Live Metrics showing HTTP requests
- [ ] Screenshot: Log Analytics showing SQL audit events
- [ ] Screenshot: Key Vault access log showing App Service identity reads

**README + LinkedIn:**
- [ ] Attack Scenarios section (updated with workload attacks)
- [ ] LinkedIn post: "AZ-104 passed + hub-spoke architecture + persistent workload shipped"

---

## End of Session — What to Keep vs Stop

> [!warning] VMs and Bastion are the cost risk here

| Resource | Action | Cost if forgotten |
|----------|--------|-------------------|
| Azure Bastion | ⛔ **Delete after every session** | ~$137/month |
| VMs (vm-web-01, vm-mgmt-01, vm-data-01) | ⛔ **Stop (deallocate)** — don't delete | ~$30/month each |
| App Service (Contoso WebApp) | ✅ Keep running | ~$13/month |
| Azure SQL (db-contoso) | ✅ Keep running | ~$5/month |
| Key Vault, Storage, App Insights | ✅ Keep running | ~$3/month |
| VNets, NSGs, VNet peering | ✅ Keep running | Free |

**Idle cost (VMs stopped, Bastion deleted): ~$28/month total**
**If Bastion left on 24/7: +$137/month — always delete it before you close your laptop**

---

## Cleanup

> [!warning] Two resource groups — different teardown rules

| Resource Group | Contains | Teardown rule |
|----------------|----------|---------------|
| `rg-network-lab` | VNets, Bastion, NSGs, VMs | Delete after each session — fully reproducible via Bicep |
| `rg-contoso-webapp` | App Service, SQL, Key Vault, App Insights | **Keep alive through Project 07** — this is the persistent workload |

```bash
# Teardown after each session (network only)
az group delete --name rg-network-lab --yes --no-wait

# To pause App Service cost between sessions (does NOT delete)
az webapp stop --name <app-name> --resource-group rg-contoso-webapp

# Full workload teardown (only after Project 07 ships)
az group delete --name rg-contoso-webapp --yes --no-wait
```

Bastion is hourly billed (~$0.19/hr Standard SKU) — **always destroy after each session**. The `bicep deploy` is repeatable; you can rebuild the network in 8 minutes.

---

## Handoff to Project 04

When this project ships, Project 04 (Azure Security Hardening Lab) inherits the following live resources:

| Resource | State handed off | What P04 does to it |
|----------|-----------------|---------------------|
| App Service | Publicly accessible, HTTP logs flowing | Put Application Gateway WAF in front; restrict direct access |
| Azure SQL | Public endpoint enabled, audit logs flowing | Add Private Endpoint; remove public access |
| Key Vault | App identity has get/list permissions | Scope down to get-only; add Purview later in P07 |
| App Insights | Wired to App Service, feeding Log Analytics | P05 builds Sentinel on top of this workspace |
| Log Analytics workspace | Receiving NSG flows + App + SQL + KV logs | P05 upgrades to Sentinel workspace |

Before starting Project 04, verify:
- [ ] App Service URL is reachable from the internet (WAF has nothing to block yet)
- [ ] SQL audit events are appearing in Log Analytics
- [ ] Key Vault access logs showing App Service identity reads

---

## Resources

- Microsoft Learn: [AZ-104 learning path](https://learn.microsoft.com/training/courses/az-104t00)
- Docs: [Hub-spoke reference architecture](https://learn.microsoft.com/azure/architecture/networking/architecture/hub-spoke)
- Docs: [Azure Bastion sizing](https://learn.microsoft.com/azure/bastion/configuration-settings)
- Docs: [App Service VNet Integration](https://learn.microsoft.com/azure/app-service/overview-vnet-integration)
- Docs: [Azure SQL Private Endpoint](https://learn.microsoft.com/azure/azure-sql/database/private-endpoint-overview)
- Cross-link: CCDL2 Module 1 (Network Forensics) — segmentation theory carries over
