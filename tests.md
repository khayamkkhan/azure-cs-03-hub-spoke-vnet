# Project 03 — Test Results

## ✅ Workload verification (complete)

| # | Test | Expected | Result | Evidence |
|---|---|---|---|---|
| W1 | Browse the App Service URL | Loads, HTTP 200 | ✅ Pass — default page, `HTTP 200` | `05-appservice-live.png` |
| W2 | App Service identity reads the SQL secret from Key Vault | `SQLDB_CONNECTIONSTRING` shows source = Key Vault (resolved) | ✅ Pass — green "Key vault" | `06-keyvault-reference-resolved.png` |
| W3 | Key Vault access is audited to Log Analytics | `SecretGet` events appear | ✅ Pass — multiple `SecretGet (Success)` | `07-keyvault-audit-logs.png` |
| W4 | App Insights wired to the workspace | Workspace-based, linked to `log-portfolio-baseline` | ✅ Pass — `WorkspaceResourceId` set at deploy |

## ✅ Network segmentation — verified from deployed config

The segmentation policy is **deployed and provable from the live config** (no VMs required to prove the rules exist and are active):

| # | Control | Evidence | Result |
|---|---|---|---|
| C1 | `nsg-data` is deny-by-default with scoped allows | `08-nsg-rules.png` | ✅ `allow-sql-from-web` (1433, pri 100), `allow-bastion-ssh` (22 from 10.0.1.0/26, pri 110), `deny-all-inbound` (Deny \*, pri 4096) |
| C2 | No spoke-to-spoke path exists | `09-no-spoke-peering.png` | ✅ workload spoke has a **single** peering (`peer-workload-to-hub`); none to the mgmt spoke |
| C3 | Storage is off the public internet | `workload.bicep` / portal | ✅ `publicNetworkAccess: Disabled` + Private Endpoint in `snet-data` |

## ⬜ Live segmentation tests (optional v1.1 — pending test VMs / Compute `Bpsv2` quota)

The config above proves the rules; these would demonstrate them with live traffic once VM quota lands (`deployTestVms=true`, rebuild Bastion):

| # | Test | Expected | Enforced by |
|---|---|---|---|
| S1 | Bastion → `vm-web-01` SSH (22) | ✅ allowed | `nsg-web` allows 22 from `AzureBastionSubnet` (10.0.1.0/26) |
| S2 | `vm-web-01` → `vm-data-01` :1433 | ✅ allowed | `nsg-data` rule `asg-web → asg-data` on 1433 |
| S3 | `vm-web-01` → `vm-data-01` :22 | ❌ denied | not in allow rules → `deny-all-inbound` (4096) |
| S4 | `vm-web-01` → `vm-jump-01` (cross-spoke) | ❌ denied | no spoke-to-spoke peering (no route) |
| S5 | Internet → `vm-web-01` public IP | n/a | VM has no public IP |
| S6 | Storage account from the internet | ❌ 403 | `publicNetworkAccess: Disabled` |
| S7 | `nslookup storage…blob.core.windows.net` from `vm-data-01` | resolves to **10.1.2.x** | Private Endpoint + `privatelink.blob` DNS zone |

## ⬜ NSG flow logs (Step 8 — pending)

Enable NSG flow logs v2 → Log Analytics, then query denied traffic:

```kql
AzureNetworkAnalytics_CL
| where SubType_s == "FlowLog" and FlowStatus_s == "D"   // denied
| summarize count() by SrcIP_s, DestIP_s, DestPort_d
| sort by count_ desc
```
