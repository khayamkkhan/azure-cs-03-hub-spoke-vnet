# Network Plan — Hub-and-Spoke (Project 03)

> Plan the address space **before** deploying. Non-overlapping CIDRs, room to grow, and the reserved Azure subnet rules respected.

**Region:** `eastus` (must match the `log-portfolio-baseline` Log Analytics workspace and all prior projects)

## Address space

| VNet | CIDR | Subnet | Subnet CIDR | Purpose |
|------|------|--------|-------------|---------|
| `vnet-hub` | `10.0.0.0/16` | `AzureBastionSubnet` | `10.0.1.0/26` | Bastion host (name + /26 are **mandatory**) |
| | | `snet-shared` | `10.0.2.0/24` | Shared services (future: DNS, firewall in P04) |
| `vnet-spoke-workload` | `10.1.0.0/16` | `snet-web` | `10.1.1.0/24` | Web tier — test VM (`vm-web-01`) |
| | | `snet-data` | `10.1.2.0/24` | Data tier — test VM + SQL/Storage **Private Endpoints** (`privateEndpointNetworkPolicies: Disabled`) |
| | | `snet-appsvc` | `10.1.3.0/24` | **App Service VNet Integration** — delegated to `Microsoft.Web/serverFarms` |
| `vnet-spoke-mgmt` | `10.2.0.0/16` | `snet-jumpbox` | `10.2.1.0/24` | Jumpbox VM, no internet egress |

> [!important] Why a separate `snet-appsvc` subnet
> App Service VNet Integration requires a subnet **delegated** to `Microsoft.Web/serverFarms`, and a delegated subnet is **exclusive** to that service — it can't also host a VM. So the web *test VM* lives in `snet-web` and App Service integration gets its own `snet-appsvc`. (The walkthrough's "App Service in the web subnet" isn't deployable as-is; this is the correct split.)

**Non-overlap check:** 10.0.x / 10.1.x / 10.2.x — distinct /16s, no overlap. ✅

## Peering topology

```
vnet-hub  ◄──peer──►  vnet-spoke-workload
   ▲
   └────────peer────►  vnet-spoke-mgmt

vnet-spoke-workload  ✗ NO peering ✗  vnet-spoke-mgmt   (forces inter-spoke traffic through the hub)
```

| Peering | allowForwardedTraffic | allowGatewayTransit | useRemoteGateways |
|---|---|---|---|
| hub → spoke (both) | `true` | `true` | `false` |
| spoke → hub (both) | `true` | `false` | `false`* |

\* `useRemoteGateways` stays `false` until a VPN/ER gateway is added to the hub (future). Setting it `true` with no gateway fails the deployment.

## Application Security Groups (ASGs)

| ASG | Members | Used by NSG rule |
|---|---|---|
| `asg-web` | `vm-web-01` NIC (+ App Service integration conceptually) | allow 443 inbound from Internet |
| `asg-data` | `vm-data-01` NIC | allow 1433 inbound **from `asg-web` only** |

ASGs let rules target *roles* instead of IP ranges — so the rules survive IP changes and read like intent.

## NSG rule design (deny-by-default)

**`nsg-web` (on snet-web):**
| Pri | Name | Dir | Src | Dst | Port | Action |
|---|---|---|---|---|---|---|
| 100 | allow-https-inbound | In | Internet | `asg-web` | 443 | Allow |
| 4096 | deny-all-inbound | In | * | * | * | Deny |

**`nsg-data` (on snet-data):**
| Pri | Name | Dir | Src | Dst | Port | Action |
|---|---|---|---|---|---|---|
| 100 | allow-sql-from-web | In | `asg-web` | `asg-data` | 1433 | Allow |
| 4096 | deny-all-inbound | In | * | * | * | Deny |

**`nsg-jumpbox` (on snet-jumpbox):** no custom inbound allows — access is **Bastion-only** (Bastion reaches it over peering from the hub; the platform `AllowAzureLoadBalancerInBound`/Bastion paths are permitted by Azure defaults). Default deny covers the rest.

> Bastion itself sits in `AzureBastionSubnet`, which **must not** have a restrictive NSG that blocks Bastion's required ports — leave it without a custom NSG, or use the documented Bastion NSG template. We attach no NSG to `AzureBastionSubnet`.
