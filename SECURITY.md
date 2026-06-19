# Security Policy

## Project scope

This repository contains a hub-and-spoke virtual network (1 hub + 2 spokes) with deny-by-default NSG segmentation, Azure Bastion, a storage private endpoint, and a VNet-integrated 2-tier workload (App Service + Azure SQL + Key Vault), deployed via Bicep. It is Project 03 of the Microsoft Cybersecurity Architect Portfolio and builds on the tenant baseline from Project 01.

It is a personal learning/portfolio repository — **not a production system** — and does not handle real user data, secrets, or live workloads. However, because the patterns here are meant to be referenced and reused by others studying Azure network security, responsible reports of issues in the configuration or documentation are welcomed.

## What counts as a security issue here

| In scope | Out of scope |
|---|---|
| Misconfigurations in `infra/*.bicep` that weaken the intended segmentation (NSG rules, peering, private endpoint) | Suggestions to enable additional paid Defender/WAF plans (intentionally deferred to Project 04) |
| Documentation that misleads readers into insecure network setups | Stylistic preferences or unrelated linting |
| Leaked secrets, keys, connection strings, or tenant/subscription identifiers in commit history | Theoretical attacks against Azure infrastructure itself |
| Bicep code that would deploy resources with hardcoded credentials, public exposure, or missing diagnostic logging | The SQL server's public access being enabled (a documented, intentional pre-hardening state handed off to Project 04) |
| ASG/NSG bypasses or peering misconfigurations that break isolation | Bugs in Azure itself (report to Microsoft Security Response Center) |

## How to report

Please **do not open a public GitHub issue** for anything that resembles a security concern. Instead, report privately via one of the following:

- **GitHub Security Advisories** — use the *Security* tab on this repository → *Report a vulnerability* (preferred — keeps history together with the fix)
- **Email** — `khan.khayam.koh@gmail.com` with subject prefix `[security][azure-cs-03]`
- **LinkedIn DM** — https://www.linkedin.com/in/khankhayamk/ (slower but works)

Please include:
- A clear description of the issue and the file(s) / commit(s) affected
- Repro steps (Bicep snippet, CLI command, or screenshot)
- The impact you believe it has (data exposure, privilege escalation, lateral movement, cost runaway, etc.)
- Optional: a suggested fix

## What I will do

- Acknowledge receipt within **5 business days**
- Triage and respond with my assessment within **14 business days**
- Credit reporters by name (unless they prefer otherwise) in the fix commit and in the project README's `## Acknowledgements` section
- Document fixes in the project's *Lessons Learned* section, because real security feedback is some of the most valuable portfolio content there is

## What I won't do

- Threaten or pressure reporters
- Sit on disclosed issues — if I disagree, I'll explain why
- Pay bug bounties (this is a personal learning portfolio, not a funded program)

## Out-of-band notes

- All secrets (VM admin password, SQL admin password) are read from environment variables at deploy time via `readEnvironmentVariable()` and are **never committed**. The `.bicepparam` files reference env vars only.
- The SQL connection string is stored in Key Vault and read by the App Service's managed identity — there are no credentials in app settings or code.
- All Bicep deployments are validated with `az deployment group what-if` before apply; any unexplained drift is itself a security signal worth raising.

---

This file follows GitHub's recommended `SECURITY.md` format. See: <https://docs.github.com/code-security/getting-started/adding-a-security-policy-to-your-repository>.
