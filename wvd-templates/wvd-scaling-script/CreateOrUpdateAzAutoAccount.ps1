
<#
.SYNOPSIS
	This is a sample script to deploy the required resources to execute scaling script in Microsoft Azure Automation Account.
	v0.1.4
	# //todo refactor stuff from https://docs.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_comment_based_help?view=powershell-5.1
#>
param(
	[Parameter(mandatory = $false)]
	[string]$AADTenantId,
	
	[Parameter(mandatory = $false)]
	[string]$SubscriptionId,
	
	[switch]$UseARMAPI,

	[Parameter(mandatory = $false)]
	[string]$ResourceGroupName = "WVDAutoScaleResourceGroup",

	[Parameter(mandatory = $false)]
	[string]$AutomationAccountName = "WVDAutoScaleAutomationAccount",

	[Parameter(mandatory = $false)]
	[string]$Location = "West US2",

	[Parameter(mandatory = $false)]
	[string]$ArtifactsURI = 'https://raw.githubusercontent.com/Azure/RDS-Templates/master/wvd-templates/wvd-scaling-script'
)

$UseRDSAPI = !$UseARMAPI

# //todo refactor, improve error logging, externalize, centralize vars

# Setting ErrorActionPreference to stop script execution when error occurs
$ErrorActionPreference = "Stop"

# Initializing variables
[string]$RunbookName = "WVDAutoScaleRunbook"
[string]$WebhookName = "WVDAutoScaleWebhook"

if (!$UseRDSAPI) {
	$RunbookName += 'ARMBased'
	$WebhookName += 'ARMBased'
}

# Set the ExecutionPolicy
Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope CurrentUser -Force -Confirm:$false

# Import Az and AzureAD modules
Import-Module Az.Resources
Import-Module Az.Accounts
Import-Module Az.OperationalInsights
Import-Module Az.Automation

# Get the azure context
$AzContext = Get-AzContext
if (!$AzContext) {
	throw 'No Azure context found. Please authenticate to Azure using Login-AzAccount cmdlet and then run this script'
}

if (!$AADTenantId) {
	$AADTenantId = $AzContext.Tenant.Id
}
if (!$SubscriptionId) {
	$SubscriptionId = $AzContext.Subscription.Id
}

if ($AADTenantId -ne $AzContext.Tenant.Id -or $SubscriptionId -ne $AzContext.Subscription.Id) {
	# Select the subscription
	$AzContext = Set-AzContext -SubscriptionId $SubscriptionId -TenantId $AADTenantId

	if ($AADTenantId -ne $AzContext.Tenant.Id -or $SubscriptionId -ne $AzContext.Subscription.Id) {
		throw "Failed to set Azure context with subscription ID '$SubscriptionId' and tenant ID '$AADTenantId'. Current context: $($AzContext | Format-List -Force | Out-String)"
	}
}

# Get the Role Assignment of the authenticated user
$RoleAssignments = Get-AzRoleAssignment -SignInName $AzContext.Account -ExpandPrincipalGroups
if (!($RoleAssignments | Where-Object { $_.RoleDefinitionName -in @('Owner', 'Contributor') })) {
	throw 'Authenticated user should have the Owner/Contributor permissions to the subscription'
}

# Check if the resourcegroup exist
$ResourceGroup = Get-AzResourceGroup -Name $ResourceGroupName -Location $Location -ErrorAction SilentlyContinue
if (!$ResourceGroup) {
	New-AzResourceGroup -Name $ResourceGroupName -Location $Location -Force -Verbose
	Write-Output "Resource Group was created with name: $ResourceGroupName"
}

# Note: the URL for the scaling script will be suffixed with current timestamp in order to force the ARM template to update the existing runbook script in the auto account if any
$URISuffix = "?time=$(get-date -f "yyyy-MM-dd_HH-mm-ss")"
$ScriptURI = "$ArtifactsURI/basicScale.ps1"
if (!$UseRDSAPI) {
	$ScriptURI = "$ArtifactsURI/ARM_based/basicScale.ps1"
}

# Creating an automation account & runbook and publish the scaling script file
$DeploymentStatus = New-AzResourceGroupDeployment -ResourceGroupName $ResourceGroupName -TemplateUri "$ArtifactsURI/runbookCreationTemplate.json" -automationAccountName $AutomationAccountName -RunbookName $RunbookName -location $Location -scriptUri "$ScriptURI$($URISuffix)" -Force -Verbose

if ($DeploymentStatus.ProvisioningState -ne 'Succeeded') {
	throw "Some error occurred while deploying a runbook. Deployment Provisioning Status: $($DeploymentStatus.ProvisioningState)"
}

# Check if the Webhook URI exists in automation variable
$WebhookURIAutoVarName = 'WebhookURI'
if (!$UseRDSAPI) {
	$WebhookURIAutoVarName += 'ARMBased'
}
$WebhookName = "$WebhookName-$(New-Guid)"
$WebhookURI = Get-AzAutomationVariable -Name $WebhookURIAutoVarName -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -ErrorAction SilentlyContinue
if (!$WebhookURI) {
	$Webhook = New-AzAutomationWebhook -Name $WebhookName -RunbookName $RunbookName -IsEnabled $true -ExpiryTime (Get-Date).AddYears(5) -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -Force -Verbose
	Write-Output ($PSVersionTable | fl -Force | Out-String)
	Write-Output "Automation Account Webhook is created with name '$WebhookName'"
	Write-Output ($Webhook | fl -Force | Out-String)
	$URIofWebhook = $Webhook.WebhookURI | Out-String
	Write-Output ($URIofWebhook | fl -Force | Out-String)
	New-AzAutomationVariable -Name $WebhookURIAutoVarName -Encrypted $false -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -Value $URIofWebhook
	Write-Output "Webhook URI stored in Azure Automation Acccount variables"
	$WebhookURI = Get-AzAutomationVariable -Name $WebhookURIAutoVarName -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -ErrorAction SilentlyContinue
	Write-Output ($WebhookURI | fl -Force | Out-String)
}

Write-Output "Azure Automation Account Name: $AutomationAccountName"
Write-Output "Webhook URI: $($WebhookURI.value)"