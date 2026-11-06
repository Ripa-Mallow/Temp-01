# audit.ps1 - Master script to run all Azure audit scripts
# ================================================================
# All reports will be saved to a date-stamped folder: reports[YYYY-MM-DD]

param(
    [Parameter(Mandatory=$true)]
    [string]$TenantId,
    [switch]$SkipVMWorkflow,
    [switch]$SkipPlatformServices,
    [switch]$SkipNetworkAudit,
    [switch]$SkipBackupAudit,
    [switch]$SkipMonitoringAudit
)

# Create date-stamped reports folder
$currentDate = Get-Date -Format "yyyy-MM-dd"
$reportsDir = "./reports$currentDate"
Write-Host "Reports will be saved to: $reportsDir" -ForegroundColor Cyan

# Ensure Azure CLI login and correct tenant
Write-Host "Verifying Azure CLI authentication..." -ForegroundColor Cyan
try {
    $currentAccount = az account show --query "{subscriptionId:id, tenantId:tenantId, name:name}" -o json | ConvertFrom-Json
    if (-not $currentAccount) {
        throw "Not logged in to Azure CLI"
    }
    
    Write-Host "Current subscription: $($currentAccount.name) ($($currentAccount.subscriptionId))" -ForegroundColor Green
    Write-Host "Current tenant: $($currentAccount.tenantId)" -ForegroundColor Green
    
    # If tenant ID is specified, verify we're in the correct tenant
    if ($currentAccount.tenantId -ne $TenantId) {
        Write-Host "Switching to specified tenant: $TenantId" -ForegroundColor Yellow
        az login --tenant $TenantId
        $currentAccount = az account show --query "{subscriptionId:id, tenantId:tenantId, name:name}" -o json | ConvertFrom-Json
        Write-Host "Now using subscription: $($currentAccount.name) ($($currentAccount.subscriptionId))" -ForegroundColor Green
    }
}
catch {
    Write-Host "❌ Azure CLI authentication required. Please run:" -ForegroundColor Red
    Write-Host "   az login --tenant $TenantId" -ForegroundColor Yellow
    Write-Host "   ./audit.ps1 -TenantId $TenantId" -ForegroundColor Yellow
    exit 1
}

# Ensure required directories exist
Write-Host "`nSetting up directories..." -ForegroundColor Cyan
New-Item -ItemType Directory -Force -Path "./params" | Out-Null
New-Item -ItemType Directory -Force -Path "./reports" | Out-Null

# Function to log errors
function Write-ErrorLog {
    param(
        [string]$ScriptName,
        [string]$ErrorMessage
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] $ScriptName`: $ErrorMessage"
    Add-Content -Path "./errorlog.txt" -Value $logEntry
}

# Function to run script with error handling
function Invoke-AuditScript {
    param(
        [string]$ScriptPath,
        [string]$Description,
        [hashtable]$ScriptParameters = @{}
    )
    
    Write-Host "`n$("="*60)" -ForegroundColor Magenta
    Write-Host "Running: $Description" -ForegroundColor Yellow
    Write-Host "Script: $ScriptPath" -ForegroundColor Gray
    Write-Host $("="*60) -ForegroundColor Magenta
    
    try {
        & $ScriptPath @ScriptParameters 2>&1 | Tee-Object -Variable output
        
        # Check if there were any error records in the output
        $errorOutput = $output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }
        if ($errorOutput) {
            foreach ($err in $errorOutput) {
                Write-ErrorLog -ScriptName (Split-Path $ScriptPath -Leaf) -ErrorMessage $err.ToString()
            }
        }
        
        Write-Host "✅ Completed: $Description" -ForegroundColor Green
    }
    catch {
        $errorMsg = $_.Exception.Message
        Write-Host "❌ Error in $Description`: $errorMsg" -ForegroundColor Red
        Write-ErrorLog -ScriptName (Split-Path $ScriptPath -Leaf) -ErrorMessage $errorMsg
    }
}

Write-Host @"
╔══════════════════════════════════════════════════════════╗
║                Azure Resource Audit Suite               ║
║              Cost Optimization & Analysis               ║
╚══════════════════════════════════════════════════════════╝
"@ -ForegroundColor Cyan

Write-Host "`nStarting comprehensive Azure audit..." -ForegroundColor White
Write-Host "Start time: $(Get-Date)" -ForegroundColor Gray

# VM Analysis Workflow
if (-not $SkipVMWorkflow) {
    Write-Host "`n🖥️  VIRTUAL MACHINE ANALYSIS WORKFLOW" -ForegroundColor Cyan
    Invoke-AuditScript -ScriptPath "./vm.ps1" -Description "VM State Audit"
    Invoke-AuditScript -ScriptPath "./vmusage.ps1" -Description "VM CPU Usage Analysis"
    Invoke-AuditScript -ScriptPath "./vm-list-deallocated.ps1" -Description "Deallocated VM Identification" -ScriptParameters @{ IncludeAllSubscriptions = $false }
    Invoke-AuditScript -ScriptPath "./deallocateddisksandips.ps1" -Description "Deallocated VM Resource Analysis"
    Invoke-AuditScript -ScriptPath "./diskandipcost.ps1" -Description "Disk and IP Cost Analysis"
}

# Platform Services Analysis
if (-not $SkipPlatformServices) {
    Write-Host "`n⚙️  PLATFORM SERVICES ANALYSIS" -ForegroundColor Cyan
    Invoke-AuditScript -ScriptPath "./scaleset.ps1" -Description "Virtual Machine Scale Sets Audit"
    Invoke-AuditScript -ScriptPath "./aksnodepools.ps1" -Description "AKS Node Pools Analysis"
    Invoke-AuditScript -ScriptPath "./appserviceplans.ps1" -Description "App Service Plans Analysis"
    Invoke-AuditScript -ScriptPath "./sqlmi.ps1" -Description "SQL Managed Instance Analysis"
}

# Network Analysis
if (-not $SkipNetworkAudit) {
    Write-Host "`n🌐 NETWORK ANALYSIS" -ForegroundColor Cyan
    Invoke-AuditScript -ScriptPath "./audit-network.ps1" -Description "Cross-Region Network Audit"
}

# Backup Analysis
if (-not $SkipBackupAudit) {
    Write-Host "`n💾 BACKUP ANALYSIS" -ForegroundColor Cyan
    Invoke-AuditScript -ScriptPath "./audit-backup.ps1" -Description "Backup Services Audit"
}

# Monitoring Analysis
if (-not $SkipMonitoringAudit) {
    Write-Host "`n📊 MONITORING ANALYSIS" -ForegroundColor Cyan
    Invoke-AuditScript -ScriptPath "./audit-monitoring.ps1" -Description "Monitoring and Logging Audit"
}

# Summary
Write-Host "`n$("="*60)" -ForegroundColor Green
Write-Host "🎉 AUDIT COMPLETE" -ForegroundColor Green
Write-Host $("="*60) -ForegroundColor Green
Write-Host "End time: $(Get-Date)" -ForegroundColor Gray

# Check if error log exists and report
if (Test-Path "./errorlog.txt") {
    $errorCount = (Get-Content "./errorlog.txt" | Measure-Object).Count
    Write-Host "`n⚠️  $errorCount error(s) logged to errorlog.txt" -ForegroundColor Yellow
    Write-Host "Review the error log for details on any issues encountered." -ForegroundColor Yellow
} else {
    Write-Host "`n✅ No errors encountered during audit execution." -ForegroundColor Green
}

Write-Host "`nGenerated reports can be found in the ./reports/ directory" -ForegroundColor Cyan
Write-Host "Configuration files are stored in the ./params/ directory" -ForegroundColor Cyan

Write-Host "`nUsage examples for partial runs:" -ForegroundColor Gray
Write-Host "  ./audit.ps1 -TenantId <tenant-id>                    # Full audit" -ForegroundColor Gray
Write-Host "  ./audit.ps1 -TenantId <tenant-id> -SkipVMWorkflow    # Skip VM analysis" -ForegroundColor Gray
Write-Host "  ./audit.ps1 -TenantId <tenant-id> -SkipNetworkAudit  # Skip network analysis" -ForegroundColor Gray
Write-Host "  ./audit.ps1 -TenantId <tenant-id> -SkipBackupAudit   # Skip backup analysis" -ForegroundColor Gray