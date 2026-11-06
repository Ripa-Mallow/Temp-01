# Toggle whether to scan all subscriptions; defaults to all.
param(
    [bool]$IncludeAllSubscriptions = $true
)

# output ""./params/deallocated-vm-ids.json"

# Store all deallocated VM IDs
$allDeallocatedVmIds = @()

# Get all subscriptions if requested; otherwise use the active CLI subscription.
if ($IncludeAllSubscriptions) {
    $tenantId = az account show --query "tenantId" -o tsv
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($tenantId)) {
        throw "Unable to determine the active Azure tenant."
    }

    $subscriptions = @(az account list --query "[?tenantId=='$tenantId'].id" -o tsv)
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to list subscriptions in tenant $tenantId."
    }
} else {
    Write-Host "Fetching deallocated VMs from the active subscription..." -ForegroundColor Cyan
    $subscriptionId = az account show --query "id" -o tsv
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($subscriptionId)) {
        throw "Unable to determine the active Azure subscription."
    }
    $subscriptions = @($subscriptionId)
}

foreach ($sub in $subscriptions) {
    if ($IncludeAllSubscriptions) {
        Write-Host "Fetching deallocated VMs from subscription $sub..." -ForegroundColor Cyan
        az account set --subscription $sub
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to select subscription $sub."
        }
    }

    # Get deallocated VM IDs for the selected subscription.
    $vmIdsJson = az vm list --show-details `
        --query "[?powerState=='VM deallocated'].id" `
        -o json
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to list VMs in subscription $sub."
    }

    $vmIds = $vmIdsJson | ConvertFrom-Json
    if ($vmIds) {
        $allDeallocatedVmIds += $vmIds
    }
}

# Ensure params folder exists
$paramsFolder = "./params"
if (-not (Test-Path $paramsFolder)) {
    New-Item -ItemType Directory -Path $paramsFolder -Force | Out-Null
    Write-Host "Created params folder: $paramsFolder"
}

# Output to JSON file
$outputFile = "./params/deallocated-vm-ids.json"
$allDeallocatedVmIds | ConvertTo-Json -Depth 2 | Out-File -Encoding utf8 -FilePath $outputFile

Write-Host "Deallocated VM IDs saved to: $outputFile"
