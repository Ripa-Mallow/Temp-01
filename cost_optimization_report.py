import streamlit as st
import pandas as pd
import matplotlib.pyplot as plt
import os
import sys
import argparse
from datetime import datetime

# Parse command line arguments for reports directory
def get_reports_dir():
    # Check if running in Streamlit (sys.argv will have streamlit run command)
    if 'streamlit' in ' '.join(sys.argv):
        # For Streamlit, check if reports_dir is passed as a parameter
        # We'll use Streamlit's sidebar for this
        return None
    else:
        # For command line execution
        parser = argparse.ArgumentParser(description='Azure Cost Optimization Report')
        parser.add_argument('--reports-dir', type=str, help='Directory containing CSV reports')
        args, unknown = parser.parse_known_args()
        return args.reports_dir if hasattr(args, 'reports_dir') else None

# Get reports directory with fallback logic
def determine_reports_dir(provided_dir=None):
    if provided_dir and os.path.exists(provided_dir):
        return provided_dir
    
    # Default to current date format: reports<yyyy-mm-dd>
    current_date = datetime.now().strftime("%Y-%m-%d")
    default_dir = os.path.join(os.path.dirname(__file__), f'../reports{current_date}')
    
    if os.path.exists(default_dir):
        return default_dir
    
    # Fallback to generic reports directory
    fallback_dir = os.path.join(os.path.dirname(__file__), '../reports')
    if os.path.exists(fallback_dir):
        return fallback_dir
    
    # If nothing exists, return the default date-based directory (will show warnings)
    return default_dir

# Initialize reports directory
provided_reports_dir = get_reports_dir()
REPORTS_DIR = determine_reports_dir(provided_reports_dir)

st.title('Azure Cost Optimization Report')
st.markdown('This dashboard analyzes Azure cost and usage CSV reports and provides actionable insights for cost optimization.')

# Display current reports directory
st.sidebar.markdown(f"**Reports Directory:** `{os.path.basename(REPORTS_DIR)}`")

# Allow users to specify reports directory via Streamlit sidebar
custom_reports_dir = st.sidebar.text_input(
    "Custom Reports Directory", 
    value="", 
    help="Enter a custom reports directory path, or leave empty to use default date-based directory"
)

if custom_reports_dir:
    if os.path.exists(custom_reports_dir):
        REPORTS_DIR = custom_reports_dir
        st.sidebar.success(f"Using custom directory: {custom_reports_dir}")
    else:
        st.sidebar.error(f"Directory not found: {custom_reports_dir}")

if not os.path.exists(REPORTS_DIR):
    st.error(f"Reports directory not found: {REPORTS_DIR}")
    st.info(f"Expected directory format: `reports{datetime.now().strftime('%Y-%m-%d')}` (e.g., reports2025-06-26)")
    st.stop()

# Helper to load CSVs safely
def load_csv(filename):
    path = os.path.join(REPORTS_DIR, filename)
    if os.path.exists(path):
        try:
            df = pd.read_csv(path)
        except pd.errors.EmptyDataError:
            st.info(f"{filename} is empty or has no columns.")
            return None
        if df.empty:
            st.info(f"{filename} is empty.")
            return None
        return df
    else:
        st.warning(f"{filename} not found.")
        return None

# 1. AKS Nodepools Analysis
st.header('AKS Nodepools Analysis')
st.markdown('''**Column explanations:**  
- **Cluster**: Name of the AKS cluster.  
- **ResourceGroup**: Azure resource group containing the cluster.  
- **NodePool**: Name of the nodepool.  
- **VMSize**: Azure VM SKU used for nodes.  
- **Autoscaling**: Whether autoscaling is enabled.  
- **MinCount/MaxCount**: Minimum/maximum nodes allowed by autoscaler.  
- **NodeCount**: Current number of nodes.  
- **Warnings**: Detected cost or configuration issues.''')
df_aks = load_csv('07-platform-aks-nodepools-analysis.csv')
if df_aks is not None:
    st.dataframe(df_aks)
    # Enhanced visual: Node count by VM size (using Streamlit bar chart)
    st.subheader('Node Count by VM Size')
    nodecount_by_vmsize = df_aks.groupby('VMSize')['NodeCount'].sum().sort_values(ascending=False)
    st.bar_chart(nodecount_by_vmsize)

    # Highlight nodepools with high maxCount, expensive VM sizes, or disabled autoscaling
    st.subheader('Detailed Recommendations')
    expensive_vms = df_aks[df_aks['Warnings'].str.contains('Expensive VM size', na=False)]
    high_max = df_aks[df_aks['Warnings'].str.contains('High maxCount', na=False)]
    autoscale_disabled = df_aks[df_aks['Autoscaling'].str.lower() == 'disabled']

    if not expensive_vms.empty:
        st.markdown('**Nodepools with Expensive VM Sizes:**')
        st.dataframe(expensive_vms[['Cluster','NodePool','VMSize','NodeCount','Warnings']])
    if not high_max.empty:
        st.markdown('**Nodepools with High maxCount:**')
        st.dataframe(high_max[['Cluster','NodePool','VMSize','MaxCount','NodeCount','Warnings']])
    if not autoscale_disabled.empty:
        st.markdown('**Nodepools with Autoscaling Disabled:**')
        st.dataframe(autoscale_disabled[['Cluster','NodePool','VMSize','NodeCount','Warnings']])

    st.markdown('''
**Recommendations:**
- **Expensive VM Sizes:** Consider switching to more cost-effective VM sizes for nodepools where possible.
- **High maxCount:** Review nodepools with high maxCount settings; reduce maxCount if not needed to avoid overprovisioning.
- **Autoscaling Disabled:** Enable autoscaling for nodepools with fluctuating workloads to optimize resource usage and cost.
- **Zero NodeCount:** Remove or consolidate nodepools with zero nodes to reduce management overhead.
    ''')

# 2. App Service Plans
st.header('App Service Plans')
st.markdown('''**Column explanations:**  
- **ResourceGroup**: Azure resource group.  
- **AppServicePlan**: Name of the App Service Plan.  
- **SKU**: Pricing tier.  
- **InstanceCount**: Number of instances.  
- **Cost**: Estimated monthly cost (if available).  
- **Utilization**: Usage metric (if available).''')
df_appsvc = load_csv('08-platform-appservice-plans.csv')
if df_appsvc is not None:
    st.dataframe(df_appsvc)
    if 'Cost' in df_appsvc.columns:
        st.bar_chart(df_appsvc.set_index(df_appsvc.columns[0])['Cost'])
    st.markdown('**Recommendation:** Consider downgrading or consolidating underutilized plans.')

# 3. SQL Managed Instances
st.header('SQL Managed Instances')
st.markdown('''**Column explanations:**  
- **ResourceGroup**: Azure resource group.  
- **SQLMI**: Managed Instance name.  
- **SKU**: Pricing tier.  
- **vCores**: Number of vCores.  
- **StorageGB**: Allocated storage.  
- **Cost**: Estimated monthly cost (if available).''')
df_sqlmi = load_csv('09-platform-sql-mi-analysis.csv')
if df_sqlmi is not None:
    st.dataframe(df_sqlmi)
    if not df_sqlmi.empty and 'Cost' in df_sqlmi.columns:
        st.bar_chart(df_sqlmi.set_index(df_sqlmi.columns[0])['Cost'])
    st.markdown('**Recommendation:** Evaluate backup retention, performance tier, and unused instances.')

# 4. VM CPU Usage Analysis
st.header('VM CPU Usage Analysis')
st.markdown('''**Column explanations:**  
- **VMName**: Name of the virtual machine.  
- **ResourceGroup**: Azure resource group.  
- **AvgCPU**: Average CPU usage (%).  
- **MaxCPU**: Peak CPU usage (%).  
- **MinCPU**: Minimum CPU usage (%).''')
df_vm_cpu = load_csv('02-vm-cpu-usage-analysis.csv')
if df_vm_cpu is not None:
    st.dataframe(df_vm_cpu)
    if 'AvgCPU' in df_vm_cpu.columns:
        st.line_chart(df_vm_cpu.set_index(df_vm_cpu.columns[0])['AvgCPU'])
    st.markdown('**Recommendation:** Identify VMs with consistently low CPU usage for potential resizing or shutdown.')

# 5. VM Status Analysis (All VMs - Running and Deallocated)
st.header('VM Status Analysis - All VMs')
st.markdown('''**Column explanations:**  
- **Name**: Name of the virtual machine.  
- **Size**: Azure VM SKU.  
- **State**: Current power state (running, deallocated, stopped, etc.).  
- **ResourceGroup**: Azure resource group.  
- **Location**: Azure region.  
- **OSType**: Operating system type.  
- **CostHints**: Cost optimization recommendations.''')

df_vm_status = load_csv('01-vm-status-analysis.csv')
if df_vm_status is not None:
    # Show summary statistics
    st.subheader('VM State Summary')
    if 'State' in df_vm_status.columns:
        state_counts = df_vm_status['State'].value_counts()
        col1, col2, col3 = st.columns(3)
        
        with col1:
            running_count = state_counts.get('running', 0)
            st.metric("🟢 Running VMs", running_count)
        
        with col2:
            deallocated_count = state_counts.get('deallocated', 0)
            st.metric("🔴 Deallocated VMs", deallocated_count)
            
        with col3:
            total_count = len(df_vm_status)
            st.metric("📊 Total VMs", total_count)
        
        # State distribution chart
        st.subheader('VM State Distribution')
        st.bar_chart(state_counts)
    
    # Show detailed data
    st.subheader('All VMs')
    
    # Filter options
    col1, col2 = st.columns(2)
    with col1:
        state_filter = st.selectbox(
            "Filter by State:",
            ["All"] + sorted(df_vm_status['State'].unique().tolist()) if 'State' in df_vm_status.columns else ["All"]
        )
    
    with col2:
        if 'ResourceGroup' in df_vm_status.columns:
            rg_filter = st.selectbox(
                "Filter by Resource Group:",
                ["All"] + sorted(df_vm_status['ResourceGroup'].unique().tolist())
            )
        else:
            rg_filter = "All"
    
    # Apply filters
    filtered_df = df_vm_status.copy()
    if state_filter != "All":
        filtered_df = filtered_df[filtered_df['State'] == state_filter]
    if rg_filter != "All":
        filtered_df = filtered_df[filtered_df['ResourceGroup'] == rg_filter]
    
    st.dataframe(filtered_df)
    
    # Deallocated VMs warning
    if 'State' in df_vm_status.columns:
        deallocated_vms = df_vm_status[df_vm_status['State'] == 'deallocated']
        if len(deallocated_vms) > 0:
            st.warning(f"⚠️ {len(deallocated_vms)} deallocated VMs found! These still consume storage costs.")
            
            st.subheader('Deallocated VMs by Resource Group')
            deallocated_by_rg = deallocated_vms.groupby('ResourceGroup').size().sort_values(ascending=False)
            st.bar_chart(deallocated_by_rg)
    
    st.markdown('''
**Recommendations:**
- **Deallocated VMs:** Delete VMs that are no longer needed to eliminate storage costs
- **Running VMs:** Consider reserved instances for consistent workloads (30-70% savings)
- **Size Optimization:** Review VM sizes and consider rightsize based on actual usage
- **Location Consolidation:** Consider consolidating VMs in fewer regions to reduce complexity
    ''')

# 6. VM Running Analysis
st.header('VM Running Analysis')
st.markdown('''**Column explanations:**  
- **VMName**: Name of the virtual machine.  
- **ResourceGroup**: Azure resource group.  
- **RunningHours**: Number of hours VM was running in the period.  
- **Cost**: Estimated cost for running hours (if available).''')
df_vm_running = load_csv('vm-running-analysis.csv')
if df_vm_running is not None:
    st.dataframe(df_vm_running)
    if 'RunningHours' in df_vm_running.columns:
        st.bar_chart(df_vm_running.set_index(df_vm_running.columns[0])['RunningHours'])
    st.markdown('**Recommendation:** Shut down VMs outside business hours to save costs.')

# 7. VM Scaleset Analysis
st.header('VM Scaleset Analysis')
st.markdown('''**Column explanations:**  
- **ScaleSetName**: Name of the VM scaleset.  
- **ResourceGroup**: Azure resource group.  
- **InstanceCount**: Number of VM instances.  
- **SKU**: VM SKU.  
- **Cost**: Estimated monthly cost (if available).''')
df_vm_scaleset = load_csv('06-vm-scaleset-analysis.csv')
if df_vm_scaleset is not None:
    st.dataframe(df_vm_scaleset)
    if 'InstanceCount' in df_vm_scaleset.columns:
        st.bar_chart(df_vm_scaleset.set_index(df_vm_scaleset.columns[0])['InstanceCount'])
    st.markdown('**Recommendation:** Review scaleset instance counts and scale down where possible.')

# 8. Backup Vaults
st.header('Backup Vaults')
st.markdown('''**Column explanations:**  
- **Vault**: Name of the backup vault.  
- **ResourceGroup**: Azure resource group.  
- **Location**: Azure region.  
- **StorageType**: Type of storage redundancy.  
- **CostNote**: Cost-related notes.''')
df_backup_vaults = load_csv('11-backup-vaults.csv')
if df_backup_vaults is not None:
    st.dataframe(df_backup_vaults)
    if 'StorageType' in df_backup_vaults.columns:
        st.bar_chart(df_backup_vaults['StorageType'].value_counts())
    st.markdown('**Recommendation:** Prefer Locally Redundant Storage (LRS) for non-critical backups to reduce costs.')

# 9. Backup Policies Summary
st.header('Backup Policies Summary')
st.markdown('''**Column explanations:**  
- **Vault**: Name of the backup vault.  
- **PolicyName**: Name of the backup policy.  
- **Daily/Weekly/Monthly/Yearly Points**: Number of backup points retained for each period.''')
df_backup_policies = load_csv('13-backup-policies-summary.csv')
if df_backup_policies is not None:
    st.dataframe(df_backup_policies)
    st.markdown('**Recommendation:** Review retention policies to avoid excessive backup storage costs.')

# 10. Backup Protected Items
st.header('Backup Protected Items')
st.markdown('''**Column explanations:**  
- **Vault**: Name of the backup vault.  
- **ResourceGroup**: Azure resource group.  
- **ItemName**: Name of the protected item.  
- **WorkloadType**: Type of workload.  
- **BackupType**: Type of backup.  
- **PolicyName**: Associated backup policy.  
- **ProtectionState**: Protection status.''')
df_backup_items = load_csv('12-backup-protected-items.csv')
if df_backup_items is not None:
    st.dataframe(df_backup_items)
    st.markdown('**Recommendation:** Remove protection from unused or obsolete items to save costs.')

# 11. Backup VM Snapshots
st.header('Backup VM Snapshots')
st.markdown('''**Column explanations:**  
- **Name**: Snapshot name.  
- **ResourceGroup**: Azure resource group.  
- **Location**: Azure region.  
- **SizeGB**: Size of the snapshot.  
- **Tier**: Storage tier.  
- **Orphaned**: Whether the snapshot is orphaned.  
- **TierNote**: Cost-related notes.  
- **SourceRef**: Source disk reference.''')
df_vm_snapshots = load_csv('15-backup-vm-snapshots.csv')
if df_vm_snapshots is not None:
    st.dataframe(df_vm_snapshots)
    if 'Tier' in df_vm_snapshots.columns:
        st.bar_chart(df_vm_snapshots['Tier'].value_counts())
    st.markdown('**Recommendation:** Delete orphaned or expensive tier snapshots when not needed.')

st.markdown('---')
st.markdown('Add new CSV reports to `/reportsyyyy-mm-dd` and restart the app to include them in the analysis.')
