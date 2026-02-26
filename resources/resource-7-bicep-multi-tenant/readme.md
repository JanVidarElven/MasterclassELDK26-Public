# Bicep Templates for Multi-Tenant Extensions

The following will assist in deploying a Multi-Tenant setup for Custom Extensions for Lifecycle Workflows and Access Package Catalogs, using Bicep deployment templates for Multi-Tenant Apps, Managed Identities, Workload Identity Federation and Microsoft Graph API across multi-tenants. This deployment will also implement an Azure Function App that will act as a Token Broker using Managed Identities and Workload Identity Federation in a Multi-Tenant scenario where a Graph Token can be used by Custom Extensions using Logic Apps.

## Login to Azure Subscription

Login to an Azure subscription where you can create resources like Resource Groups, Logic Apps etc for the later labs, using Azure CLI.

```azurecli
az login --tenant yourtenant.onmicrosoft.com
```

After logging in, confirm the right subscription. If you need to verify or change between Azure subscriptions, run:

```azurecli
az account show

az account set --subscription "your-subscription-name-or-id"
```

## TODO - Change Parameter values in Main Bicep file

In the main.bicep file, change all relevant parameters to reflect your environment and choice of naming.

## Deploy Bicep

Deploy the main.bicep file with one of the following commands, changing the deployment names and location as needed.

Deploy as Subscription Deployment:

```azurecli
az deployment sub create --name 'deploy-sub-yourorg-iam-multi-tenant' --location norwayeast --template-file main.bicep
```

Deploy as Deployment Stack is *NOT* supported when using the Microsoft Graph API extension.

## Post-Deployment Configuration

After deploying the Function App using the Bicep code here, you need to follow some manual guidelines for setting up the Functions and prepare to integrate the Logic App Custom Extension.

# Create Function

In the Azure Portal, find the deployed Function App, and under Functions at the Overview page, select to Create in the Portal. (You can optionally use a local VS code editor or integrate with source control, but that is outside the scope here).

1. Select HTTP Trigger as Template
2. Name the Function something like 'GetGraphToken'
3. Use 'Function' as Authorization Level
4. Change the content of the files: copying the content of the files from this source:
    1. Run.ps1 -> https://github.com/JanVidarElven/token-broker-exchange-assertion-graph-token-multi-tenant-wif/blob/main/GetGraphToken/run.ps1
    1. Function.json -> https://github.com/JanVidarElven/token-broker-exchange-assertion-graph-token-multi-tenant-wif/blob/main/GetGraphToken/function.json
5. Copy the Function URL

