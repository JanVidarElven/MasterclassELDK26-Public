// Main Bicep deployment file for Microsoft Graph & Azure resources:
// Multi-tenant app, Workload Identity Federation, Function App

targetScope = 'subscription'

// Main Parameters for Deployment
// TODO: Change these to match your environment
param applicationName string = 'iam-governance'
param orgName string = 'elven'
param projectName string = 'ELDK26'
param location string = 'norwayeast'
var resourceGroupName string = 'rg-${orgName}-${applicationName}'

// Your Microsoft Entra tenant Id
// TODO: Change these to match your environment
@secure()
param entraTenantId string = '0da56191-c95e-431f-acee-67e84aeb791a' // = 'your-tenant-id-here'

// Resource Tags for all resources deployed with this Bicep file
// TODO: Change, add or remove these to match your environment
var defaultTags = {
  'service-name': 'IAM Governance'
  'deployment-type': 'Bicep'
  'project-name': projectName
  'last-updated-by-deployer': az.deployer().userPrincipalName
}

// Create Resource Group for IAM Azure Resources
// PS! Depending on if you created a resource group from resource-3 (Bicep Custom Extensions), 
// comment out this section and uncomment the next section to use the existing resource group instead.
/* 
resource rg 'Microsoft.Resources/resourceGroups@2025-04-01' = {
  name: resourceGroupName
  location: location
  tags: defaultTags
}
*/
resource rg 'Microsoft.Resources/resourceGroups@2025-04-01' existing = {
  name: resourceGroupName
}

// Refer to existing User Assigned Managed Identity for Custom Extension created in resource-3 (Bicep Custom Extensions)
// Creating User Assigned Managed Identity for Custom Extension
// Using AVM module for User Assigned Managed Identity
resource userAssignedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2018-11-30' existing = {
  name: 'mi-${toLower(replace(applicationName,' ',''))}-${toLower(projectName)}'
  scope: resourceGroup(rg.name)
}
/* module userAssignedIdentity 'br/public:avm/res/managed-identity/user-assigned-identity:0.5.0' = {
  name: 'userAssignedIdentityDeployment'
  scope: resourceGroup(rg.name)
  params: {
    // Required parameters
    name: 'mi-${toLower(replace(applicationName,' ',''))}-${toLower(projectName)}'
  }
}
*/

// Initialize the Graph provider
extension microsoftGraphV1

// Get the Resource Id of the Graph resource in the tenant
resource graphSpn 'Microsoft.Graph/servicePrincipals@v1.0' existing = {
  appId: '00000003-0000-0000-c000-000000000000'
}

// Define the App Roles to assign to the Multi-Tenant App Registration Service Principal
param appRoles array = [
  'ProvisioningLog.Read.All'
  'SynchronizationData-User.Upload'
  'User.Read.All'
]

// Set Variables for Audience, Login Endpoint and Tenant ID and Issuer
var microsoftEntraAudience = 'api://AzureADTokenExchange'
var loginEndpoint = environment().authentication.loginEndpoint
var azureTenantId = tenant().tenantId
var issuer = '${loginEndpoint}${azureTenantId}/v2.0'

// First we will create a Multi-Tenant App Registration in the Entra Tenant of the Azure Subscription where we deploy our resources. This app registration will represent the application in the tenant and allow us to configure permissions and consent for the application.
resource multiTenantApp 'Microsoft.Graph/applications@v1.0' = {
  displayName: 'mta-${toLower(replace(applicationName,' ',''))}-${toLower(projectName)}'
  uniqueName: uniqueString('mta-${toLower(replace(applicationName,' ',''))}-${toLower(projectName)}')
  signInAudience: 'AzureADMultipleOrgs'

  requiredResourceAccess: [
    {
      resourceAppId: graphSpn.appId
      resourceAccess: [ for appRole in appRoles: {
          id: (filter(graphSpn.appRoles, role => role.value == appRole)[0]).id
          type: 'Role'
        }
      ]
    }
  ]

  resource myMsiFic 'federatedIdentityCredentials@v1.0' = {
    name: '${multiTenantApp.uniqueName}/msiAsFic'
    description: 'Trust the workload\'s user-assigned MI as a credential for the app'
    audiences: [microsoftEntraAudience]
    issuer: issuer
    subject: userAssignedIdentity.properties.principalId
  }

}

// Create service principal for Multi-Tenant App Registration
resource multiTenantSpn 'Microsoft.Graph/servicePrincipals@v1.0' = {
  appId: multiTenantApp.appId
}

// Looping through the App Roles and assigning them to the 
// Multi-Tenant App Registration Service Principal
// This gives Admin Consent to the app in the Azure Tenant where we deploy our resources
resource assignAppRole 'Microsoft.Graph/appRoleAssignedTo@v1.0' = [
  for appRole in appRoles: {
    appRoleId: (filter(graphSpn.appRoles, role => role.value == appRole)[0]).id
    principalId: multiTenantSpn.id
    resourceId: graphSpn.id
  }
]

// Build Admin Consent URL for the Multi-Tenant App Registration for other tenants
output adminConsentUrl string = '${environment().authentication.loginEndpoint}/${entraTenantId}/adminconsent?client_id=${multiTenantApp.appId}&state=eldk26&redirect_uri=https://jwt.ms'

// ---------- Storage for Flex deployments ----------
@description('Name of the container that holds Flex deployment artifacts.')
param deploymentContainerName string = 'deployments'

// Storage account names must be <= 24 chars, lowercase, and globally unique.
// This keeps it deterministic but unique per RG/subscription/location.
var storageAccountName = toLower('sa${take(orgName, 3) }${take(replace(replace(applicationName,'-',''),' ',''), 19) }')
// Build a container URL (works for public Azure; for sovereign clouds use environment().suffixes.storage)
var deploymentBlobContainerUrl = 'https://${storageAccountName}.blob.core.windows.net/${deploymentContainerName}'

module functionStorage 'br/public:avm/res/storage/storage-account:0.31.1' = {
  scope: resourceGroup(rg.name)
  name: 'functionStorage'
  params: {
    // Required
    name: storageAccountName

    // Minimal + secure-ish defaults (optional parameters supported by the module)
    location: location
    kind: 'StorageV2'
    skuName: 'Standard_LRS'
    allowBlobPublicAccess: true
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    // If you want identity-only auth, keep Shared Key off:
    allowSharedKeyAccess: true

    // Create the blob container if you are going to use Flex deployments
    blobServices: {
      containers: [
        {
          name: deploymentContainerName
          publicAccess: 'None'
        }
      ]
    }

    // Grant the Function App's managed identity access to blobs (for deployment + runtime usage as needed)
    roleAssignments: [
      {
        name: guid(storageAccountName, userAssignedIdentity.id, 'StorageBlobDataContributor')
        principalId: userAssignedIdentity.properties.principalId
        principalType: 'ServicePrincipal'
        roleDefinitionIdOrName: 'Storage Blob Data Owner'
      }
    ]

    tags: defaultTags
  }
}

// Deploy Log Analytics Workspace and Application Insights for the Function App
module logAnalytics 'br/public:avm/res/operational-insights/workspace:0.4.0' = {
  scope: resourceGroup(rg.name)
  name: 'logAnalytics'
  params: {
    name: 'law-${toLower(replace(applicationName,' ',''))}-${toLower(projectName)}'
    location: location
    tags: defaultTags
  }
}
module appInsights 'br/public:avm/res/insights/component:0.7.1' = {
  scope: resourceGroup(rg.name)
  name: 'appInsights'
  params: {
    name: 'appi-${toLower(replace(applicationName,' ',''))}-${toLower(projectName)}'
    location: location
    applicationType: 'web'
    workspaceResourceId: logAnalytics.outputs.resourceId
    tags: defaultTags
  }
}

// Create Consumption Plan for the Function App
module serverfarm 'br/public:avm/res/web/serverfarm:0.7.0' = {
  scope: resourceGroup(rg.name)
  name: 'hostingplan'
  params: {
    // Required parameters
    name: 'hostingplan-function-sec-${applicationName}-${projectName}'
    // Non-required parameters
    reserved: false
    skuName: 'Y1'
    tags: defaultTags
    zoneRedundant: false
  }
}

// Create Function App for Token Broker
module functionAppTokenBroker 'br/public:avm/res/web/site:0.21.0' = {
  scope: resourceGroup(rg.name)
  name: 'functionAppTokenBroker'
  params: {
    // Required parameters
    kind: 'functionapp'
    name: 'fa-iam-${toLower(projectName)}-tokenbroker'
    serverFarmResourceId: serverfarm.outputs.resourceId
    
    // To override defaults in AVM module not relevant for Flex Consumption
    siteConfig: {}

    location: location
    managedIdentities: {
      userAssignedResourceIds: [
        userAssignedIdentity.id
      ]
    }
    
    // App settings / config
    configs: [
      {
        name: 'appsettings'
        properties: {
          FUNCTIONS_WORKER_RUNTIME: 'powershell'
          FUNCTIONS_EXTENSION_VERSION: '~4'
          AzureWebJobsStorage: functionStorage.outputs.primaryConnectionString
          WEBSITE_CONTENTAZUREFILECONNECTIONSTRING: functionStorage.outputs.primaryConnectionString
          WEBSITE_CONTENTSHARE: 'fa-iam-${toLower(projectName)}-tokenbroker'
          APPLICATIONINSIGHTS_CONNECTION_STRING: appInsights.outputs.connectionString
          APP_CLIENT_ID: multiTenantApp.appId
          UAMI_CLIENT_ID: userAssignedIdentity.properties.clientId
          RESTRICT_TENANTS: 'false'
          ALLWOWED_TENANTS: ''
        }

        applicationInsightResourceId: appInsights.outputs.resourceId
        // Connect the Function App to the storage account using MI (supported by AVM site module)
        storageAccountResourceId: functionStorage.outputs.resourceId
        storageAccountUseIdentityAuthentication: true
      }
    ]

    tags: defaultTags

  }
}
