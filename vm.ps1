# output: "vm-status-analysis.csv"

# Create date-stamped reports folder
$currentDate = Get-Date -Format "yyyy-MM-dd"
$reportsDir = "./reports$currentDate"
if (-not (Test-Path $reportsDir)) {
    New-Item -ItemType Directory -Path $reportsDir -Force | Out-Null
    Write-Host "Created reports folder: $reportsDir"
}

Write-Host "Fetching ALL VMs (running and deallocated) using Azure Resource Graph..." -ForegroundColor Cyan

# Ensure Azure Resource Graph extension is installed
try {
    az extension show --name resource-graph > $null 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Installing Azure Resource Graph extension..." -ForegroundColor Yellow
        az extension add --name resource-graph
    }
} catch {
    Write-Host "Installing Azure Resource Graph extension..." -ForegroundColor Yellow
    az extension add --name resource-graph
}

# Resource Graph KQL Query - Get ALL VMs regardless of power state
$query = @"
Resources
| where type =~ 'microsoft.compute/virtualmachines'
| project 
    name,
    resourceGroup,
    location,
    vmSize = properties.hardwareProfile.vmSize,
    osType = properties.storageProfile.osDisk.osType,
    powerState = properties.extended.instanceView.powerState.code,
    powerStateDisplay = properties.extended.instanceView.powerState.displayStatus,
    subscriptionId,
    id
| extend state = case(
    powerState =~ 'PowerState/running', 'running',
    powerState =~ 'PowerState/deallocated', 'deallocated',
    powerState =~ 'PowerState/stopped', 'stopped',
    powerState =~ 'PowerState/starting', 'starting',
    powerState =~ 'PowerState/stopping', 'stopping',
    'unknown'
)
| order by state desc, name asc
"@

# Query Azure Resource Graph
try {
    $subscriptionId = az account show --query "id" -o tsv
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($subscriptionId)) {
        throw "Unable to determine the active Azure subscription."
    }

    $rawResult = az graph query -q $query --subscriptions $subscriptionId --first 1000 --output json | ConvertFrom-Json
    $allVMs = $rawResult.Data  # Capital 'D'

    if (-not $allVMs -or $allVMs.Count -eq 0) {
        Write-Host "No VMs found." -ForegroundColor Yellow
        exit
    }

    Write-Host "Found $($allVMs.Count) VMs across subscriptions" -ForegroundColor Green

} catch {
    Write-Host "Error querying Resource Graph." -ForegroundColor Red
    exit
}

# Prepare output structures
$results = @()
$vmSizeCounts = @{}
$locationCounts = @{}
$stateCounts = @{}

foreach ($vm in $allVMs) {
    # Safety: handle missing values
    if (-not $vm.vmSize -or -not $vm.location) {
        Write-Host "Skipping VM with missing data: Name=$($vm.name), Size=$($vm.vmSize), Location=$($vm.location)" -ForegroundColor Yellow
        continue
    }

    # Count VM sizes (only for running VMs for reservation analysis)
    if ($vm.state -eq 'running') {
        if ($vmSizeCounts.ContainsKey($vm.vmSize)) {
            $vmSizeCounts[$vm.vmSize]++
        } else {
            $vmSizeCounts[$vm.vmSize] = 1
        }
    }

    # Count by location
    if ($locationCounts.ContainsKey($vm.location)) {
        $locationCounts[$vm.location]++
    } else {
        $locationCounts[$vm.location] = 1
    }

    # Count by state
    if ($stateCounts.ContainsKey($vm.state)) {
        $stateCounts[$vm.state]++
    } else {
        $stateCounts[$vm.state] = 1
    }

    # Generate cost optimization hints
    $costHints = @()
    
    if ($vm.state -eq 'deallocated') {
        $costHints += "💰 DEALLOCATED - Consider deletion if unused"
    } elseif ($vm.state -eq 'running') {
        if ($vm.vmSize -match "_B\\d+") {
            $costHints += "Burstable (good for variable workloads)"
        } elseif ($vm.vmSize -match "_D\\d+s_v[3-5]") {
            $costHints += "General purpose (reservation candidate)"
        } elseif ($vm.vmSize -match "_E\\d+") {
            $costHints += "Memory optimized (high cost)"
        } elseif ($vm.vmSize -match "_F\\d+") {
            $costHints += "Compute optimized (high cost)"
        }
        # Only flag v1 as older generation
        if ($vm.vmSize -match "_v1\\b") {
            $costHints += "Older series - consider newer generation"
        }
    }

    $results += [PSCustomObject]@{
        Name           = $vm.name
        Size           = $vm.vmSize
        State          = $vm.state
        ResourceGroup  = $vm.resourceGroup
        Location       = $vm.location
        OSType         = $vm.osType
        CostHints      = ($costHints -join "; ")
        SubscriptionId = $vm.subscriptionId
    }
}

# Output table
Write-Host "`n$("="*100)" -ForegroundColor Cyan
Write-Host "VM STATUS ANALYSIS - ALL VMs (via Azure Resource Graph)" -ForegroundColor Cyan
Write-Host $("="*100) -ForegroundColor Cyan

# Separate running and deallocated for display
$runningVMs = $results | Where-Object { $_.State -eq 'running' }
$deallocatedVMs = $results | Where-Object { $_.State -eq 'deallocated' }
$otherStateVMs = $results | Where-Object { $_.State -notin @('running', 'deallocated') }

Write-Host "`n🟢 RUNNING VMs ($($runningVMs.Count)):" -ForegroundColor Green
if ($runningVMs.Count -gt 0) {
    $runningVMs | Format-Table -AutoSize
}

Write-Host "`n🔴 DEALLOCATED VMs ($($deallocatedVMs.Count)):" -ForegroundColor Red
if ($deallocatedVMs.Count -gt 0) {
    $deallocatedVMs | Format-Table -AutoSize
}

if ($otherStateVMs.Count -gt 0) {
    Write-Host "`n⚪ OTHER STATE VMs ($($otherStateVMs.Count)):" -ForegroundColor Yellow
    $otherStateVMs | Format-Table -AutoSize
}

# Summary
Write-Host "`nANALYTICS SUMMARY:" -ForegroundColor Yellow

Write-Host "`nVM State Distribution:" -ForegroundColor Green
$stateCounts.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object {
    $emoji = switch ($_.Key) {
        'running' { '🟢' }
        'deallocated' { '🔴' }
        'stopped' { '🟡' }
        default { '⚪' }
    }
    Write-Host "  $emoji $($_.Key): $($_.Value) VMs" -ForegroundColor White
}

Write-Host "`nRunning VM Size Distribution (Reservation Opportunities):" -ForegroundColor Green
$vmSizeCounts.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object {
    $hint = if ($_.Value -ge 3) { "⭐ Possible reservation candidates" } else { "" }
    Write-Host "  $($_.Key): $($_.Value) VMs $hint" -ForegroundColor White
}

Write-Host "`nLocation Distribution:" -ForegroundColor Green
$locationCounts.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object {
    Write-Host "  $($_.Key): $($_.Value) VMs" -ForegroundColor White
}

Write-Host "`nCOST OPTIMIZATION RECOMMENDATIONS:" -ForegroundColor Yellow

# Deallocated VMs analysis
if ($deallocatedVMs.Count -gt 0) {
    Write-Host "`n💰 DEALLOCATED VMs - Immediate Action Required:" -ForegroundColor Red
    Write-Host "   → $($deallocatedVMs.Count) VMs are deallocated but still consuming storage costs" -ForegroundColor White
    
    $deallocatedByRG = $deallocatedVMs | Group-Object ResourceGroup | Sort-Object Count -Descending
    Write-Host "`n   Top Resource Groups with deallocated VMs:" -ForegroundColor Yellow
    $deallocatedByRG | Select-Object -First 5 | ForEach-Object {
        Write-Host "     - $($_.Name): $($_.Count) VMs" -ForegroundColor White
    }
    
    Write-Host "`n   Consider:" -ForegroundColor Cyan
    Write-Host "     • Delete VMs that are no longer needed" -ForegroundColor White
    Write-Host "     • Convert to images if templates are needed" -ForegroundColor White
    Write-Host "     • Document the purpose of each deallocated VM" -ForegroundColor White
}

# Reservation candidates
$reservationCandidates = $vmSizeCounts.GetEnumerator() | Where-Object { $_.Value -ge 3 } | Sort-Object Value -Descending
if ($reservationCandidates) {
    Write-Host "`n💰 Consider Azure Reserved VM Instances for running VMs:" -ForegroundColor Green
    $reservationCandidates | ForEach-Object {
        Write-Host "   - $($_.Key): $($_.Value) instances" -ForegroundColor White
    }
    Write-Host "   → Potential 30-70% savings with 1-3 year commitments" -ForegroundColor Cyan
}

# Older VMs
$olderVMs = $results | Where-Object { $_.CostHints -like "*Older series*" -and $_.State -eq 'running' }
if ($olderVMs) {
    Write-Host "`n⚠️  Consider upgrading older generation running VMs:" -ForegroundColor Yellow
    $olderVMs | Select-Object Name, Size, Location, State | Format-Table -AutoSize
}

# Export to CSV
$csvPath = "$reportsDir/01-vm-status-analysis.csv"
$results | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
Write-Host "`n📊 Report exported to $csvPath" -ForegroundColor Green

Write-Host "`n💡 Key Insights:" -ForegroundColor Cyan
Write-Host "   • Running VMs: $($runningVMs.Count) (actively costing money)" -ForegroundColor White
Write-Host "   • Deallocated VMs: $($deallocatedVMs.Count) (still consuming storage costs)" -ForegroundColor White
Write-Host "   • Total VMs: $($results.Count)" -ForegroundColor White
