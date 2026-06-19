# Project 03 — Architecture

> Hub-and-spoke topology with a VNet-integrated workload. Renders natively on GitHub (Mermaid).

```mermaid
flowchart TB
    internet(("🌐 Internet"))

    subgraph hub["vnet-hub · 10.0.0.0/16 · eastus"]
        bastion["Azure Bastion (Standard)<br/>AzureBastionSubnet 10.0.1.0/26"]
        shared["snet-shared 10.0.2.0/24<br/><i>reserved — Azure Firewall in P04</i>"]
    end

    subgraph workload["vnet-spoke-workload · 10.1.0.0/16 · eastus"]
        web["snet-web 10.1.1.0/24<br/>nsg-web · asg-web<br/>vm-web-01"]
        data["snet-data 10.1.2.0/24<br/>nsg-data · asg-data<br/>vm-data-01 · Private Endpoint"]
        appsvcsub["snet-appsvc 10.1.3.0/24<br/><i>delegated → Microsoft.Web</i>"]
    end

    subgraph mgmt["vnet-spoke-mgmt · 10.2.0.0/16 · eastus"]
        jump["snet-jumpbox 10.2.1.0/24<br/>nsg-jumpbox · no egress<br/>vm-jump-01"]
    end

    subgraph app["Contoso WebApp · rg-contoso-webapp"]
        appsvc["App Service B1 (eastus)<br/>system-assigned identity"]
        kv["Key Vault<br/>SqlConnectionString"]
        ai["Application Insights"]
        sql["Azure SQL Basic<br/>db-contoso (centralus)*"]
    end

    storage["Storage Account<br/><i>public access disabled</i>"]
    law[("Log Analytics<br/>log-portfolio-baseline")]

    internet -->|"443 → asg-web"| web
    internet -->|HTTPS| appsvc

    hub <-->|peering| workload
    hub <-->|peering| mgmt
    web x-.x mgmt
    bastion -. "SSH via peering" .-> web
    bastion -. "SSH via peering" .-> data
    bastion -. "SSH via peering" .-> jump

    appsvc ==>|VNet integration| appsvcsub
    web -->|"1433 (asg rule)"| data
    appsvc -->|managed identity| kv
    appsvc --> ai
    appsvc -->|conn string| sql
    data --> storage

    appsvc -. diag .-> law
    sql -. audit .-> law
    kv -. audit .-> law
    ai --> law

    classDef region fill:#eaf3fb,stroke:#0078d4,color:#000
    class hub,workload,mgmt,app region
```

\* **Note:** SQL was deployed to **centralus** rather than eastus — the East US geo (eastus + eastus2) was capacity-restricted for new SQL servers during the build. The region is a Bicep parameter (`sqlLocation`); the architecture is otherwise region-consistent, and the cross-region private endpoint planned for P04 still applies.

## Segmentation summary

| Control | Implementation |
|---|---|
| **Hub-and-spoke** | Hub peers to each spoke; **no spoke-to-spoke peering** → inter-spoke traffic forced through the hub (Azure Firewall lands there in P04) |
| **Deny-by-default NSGs** | Every VM subnet: explicit `deny-all-inbound` (priority 4096) + scoped allows |
| **ASG-based rules** | `asg-web` / `asg-data` target *roles* not IPs — e.g. 1433 allowed **from asg-web → asg-data only** |
| **Bastion-only access** | VMs have **no public IPs**; SSH allowed only **from the AzureBastionSubnet** |
| **Private Endpoint** | Storage account `publicNetworkAccess: Disabled`; reachable only via PE in `snet-data` + `privatelink.blob` DNS zone |
| **Secret management** | SQL connection string in **Key Vault**, read via App Service **managed identity** — never in code |
| **Centralised telemetry** | App Service / SQL / Key Vault / NSG-flow diagnostics → `log-portfolio-baseline` (→ Sentinel in P05) |
