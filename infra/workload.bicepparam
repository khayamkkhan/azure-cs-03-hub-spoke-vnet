using './workload.bicep'

param location = 'eastus'
param sqlLocation = 'centralus' // East US geo (eastus + eastus2) was capacity-restricted for new SQL servers; centralus is a different pool
param networkResourceGroup = 'rg-network-lab'
param baselineResourceGroup = 'rg-portfolio-baseline'
param workspaceName = 'log-portfolio-baseline'
param sqlAdminLogin = 'sqladmin'

// Secret read from an environment variable — never stored in the repo.
// Set it before deploying:  export SQL_ADMIN_PASSWORD='<your-strong-pw>'
param sqlAdminPassword = readEnvironmentVariable('SQL_ADMIN_PASSWORD')
