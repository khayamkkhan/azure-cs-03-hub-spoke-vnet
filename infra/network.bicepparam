using './network.bicep'

param location = 'eastus'
param adminUsername = 'azureuser'
param shutdownTimeZone = 'Singapore Standard Time' // UTC+8 = Philippine time
param shutdownTime = '1900'

// Secret is read from an environment variable so it never lands in the file/repo.
// Set it before deploying:  export VM_ADMIN_PASSWORD='<your-strong-pw>'
param adminPassword = readEnvironmentVariable('VM_ADMIN_PASSWORD')
