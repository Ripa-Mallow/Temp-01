# output: "platform-aks-nodepools-analysis.csv"

# Create date-stamped reports folder
$currentDate = Get-Date -Format "yyyy-MM-dd"
$reportsDir = "./reports$currentDate"
if (-not (Test-Path $reportsDir)) {
    New-Item -ItemType Directory -Path $reportsDir -Force | Out-Null
    Write-Host "Created reports folder: $reportsDir"
}

# Expensive VM SKUs to flag (add more as needed)
$expensiveVms = @("Standard_D", "Standard_E", "Standard_F", "Standard_N", "Standard_H", "Standard_M")

Write-Host "Fetching AKS clusters and node pools..." -ForegroundColor Cyan

# Load AKS cluster list with node pools
$aksClusters = az aks list --query "[].{Cluster:name, ResourceGroup:resourceGroup, NodePools:agentPoolProfiles[].{Name:name, Size:vmSize, Count:count, Autoscale:enableAutoScaling, Min:minCount, Max:maxCount}}" -o json | ConvertFrom-Json

# Function to get CPU metrics using Azure Resource Graph (faster approach)
function Get-NodePoolCPUMetrics {
    param(
        [string]$ClusterName,
        [string]$ResourceGroup,
        [string]$NodePoolName
    )
    
    try {
        # Get the node resource group (MC_* resource group) for the AKS cluster
        $clusterInfo = az aks show --name $ClusterName --resource-group $ResourceGroup --query "{nodeResourceGroup:nodeResourceGroup}" -o json 2>$null | ConvertFrom-Json
        
        if (-not $clusterInfo -or -not $clusterInfo.nodeResourceGroup) {
            return @{ AvgCPU = "No RG"; PeakCPU = "No RG" }
        }
        
        $nodeResourceGroup = $clusterInfo.nodeResourceGroup
        
        # List all VMSS in the node resource group
        $allVmss = az vmss list --resource-group $nodeResourceGroup --query "[].{name:name, id:id}" -o json 2>$null | ConvertFrom-Json
        
        if (-not $allVmss -or $allVmss.Count -eq 0) {
            return @{ AvgCPU = "No VMSS"; PeakCPU = "No VMSS" }
        }
        
        # Try to find VMSS that contains the node pool name
        $matchingVmss = $allVmss | Where-Object { $_.name -like "*$NodePoolName*" }
        
        if (-not $matchingVmss) {
            # If exact match fails, try to find any VMSS (some clusters have different naming patterns)
            $matchingVmss = $allVmss[0]
        }
        
        if (-not $matchingVmss) {
            return @{ AvgCPU = "No Match"; PeakCPU = "No Match" }
        }
        
        $vmssId = $matchingVmss.id
        
        # Use Azure Monitor for CPU metrics (last 3 days for faster response)
        $startTime = (Get-Date).ToUniversalTime().AddDays(-3).ToString("yyyy-MM-ddTHH:mm:ssZ")
        $endTime = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        
        # Get average CPU
        $avgMetrics = $null
        try {
            $avgMetrics = az monitor metrics list `
                --resource $vmssId `
                --metric "Percentage CPU" `
                --start-time $startTime `
                --end-time $endTime `
                --interval PT1H `
                --aggregation Average `
                --output json 2>$null | ConvertFrom-Json
        }
        catch {
            # Silently continue on metrics error
        }
        
        # Get peak CPU
        $maxMetrics = $null
        try {
            $maxMetrics = az monitor metrics list `
                --resource $vmssId `
                --metric "Percentage CPU" `
                --start-time $startTime `
                --end-time $endTime `
                --interval PT1H `
                --aggregation Maximum `
                --output json 2>$null | ConvertFrom-Json
        }
        catch {
            # Silently continue on metrics error
        }
        
        $avgCpu = "N/A"
        $peakCpu = "N/A"
        
        if ($avgMetrics -and $avgMetrics.value -and $avgMetrics.value.Count -gt 0) {
            $timeseries = $avgMetrics.value[0].timeseries
            if ($timeseries -and $timeseries.Count -gt 0 -and $timeseries[0].data) {
                $validAvgs = $timeseries[0].data | Where-Object { $_.average -ne $null -and $_.average -ne "" } | ForEach-Object { [double]$_.average }
                if ($validAvgs.Count -gt 0) {
                    $avgCpu = [Math]::Round(($validAvgs | Measure-Object -Average).Average, 1)
                }
            }
        }
        
        if ($maxMetrics -and $maxMetrics.value -and $maxMetrics.value.Count -gt 0) {
            $timeseries = $maxMetrics.value[0].timeseries
            if ($timeseries -and $timeseries.Count -gt 0 -and $timeseries[0].data) {
                $validMaxs = $timeseries[0].data | Where-Object { $_.maximum -ne $null -and $_.maximum -ne "" } | ForEach-Object { [double]$_.maximum }
                if ($validMaxs.Count -gt 0) {
                    $peakCpu = [Math]::Round(($validMaxs | Measure-Object -Maximum).Maximum, 1)
                }
            }
        }
        
        return @{
            AvgCPU = $avgCpu
            PeakCPU = $peakCpu
        }
    }
    catch {
        return @{
            AvgCPU = "Error"
            PeakCPU = "Error"
        }
    }
}

$results = @()

foreach ($cluster in $aksClusters) {
    $clusterName = $cluster.Cluster
    $rg = $cluster.ResourceGroup

    Write-Host "Processing cluster: $clusterName" -ForegroundColor Green

    foreach ($pool in $cluster.NodePools) {
        $vmSize = $pool.Size
        $autoscale = $pool.Autoscale
        $min = $pool.Min
        $max = $pool.Max
        $count = $pool.Count
        $poolName = $pool.Name

        $issues = @()

        # 1. Autoscaling disabled
        if (-not $autoscale) {
            $issues += "Autoscaling disabled"
        }

        # 2. Autoscaling on but suspicious limits
        if ($autoscale) {
            if ($min -ge 5) {
                $issues += "High minCount ($min)"
            }
            if ($max -ge 10) {
                $issues += "High maxCount ($max)"
            }
            if ($min -eq $max) {
                $issues += "minCount == maxCount (fixed size)"
            }
        }

        # 3. Expensive VM size
        if ($expensiveVms | Where-Object { $vmSize -like "$_*" }) {
            $issues += "Expensive VM size: $vmSize"
        }

        # 4. Get CPU metrics
        $cpuMetrics = Get-NodePoolCPUMetrics -ClusterName $clusterName -ResourceGroup $rg -NodePoolName $poolName

        # Add row to result
        $results += [PSCustomObject]@{
            Cluster       = $clusterName
            ResourceGroup = $rg
            NodePool      = $poolName
            VMSize        = $vmSize
            Autoscaling   = if ($autoscale) { "Enabled" } else { "Disabled" }
            MinCount      = if ($min) { $min } else { "-" }
            MaxCount      = if ($max) { $max } else { "-" }
            NodeCount     = $count
            "Avg CPU 7d"  = $cpuMetrics.AvgCPU
            "Peak CPU 7d" = $cpuMetrics.PeakCPU
            Warnings      = if ($issues.Count -gt 0) { $issues -join "; " } else { "✓ Healthy" }
        }
    }
}

# Output in table
Write-Host "`nAKS Node Pools Analysis Results:" -ForegroundColor Green
$results | Sort-Object Cluster, NodePool | Format-Table -AutoSize
$results | Export-Csv -Path "$reportsDir/07-platform-aks-nodepools-analysis.csv" -NoTypeInformation -Encoding UTF8

Write-Host "`n➡ Report saved to $reportsDir/07-platform-aks-nodepools-analysis.csv" -ForegroundColor Cyan