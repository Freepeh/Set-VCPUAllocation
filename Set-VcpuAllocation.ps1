function Set-VcpuAllocation {
<#
.SYNOPSIS
 To report on and distribute virtual cpu cores evenly across hosts in a cluster.
.DESCRIPTION
 Use only cluster and server (Vcenter server) parameters to simply report on the before and after (No actual migrations will take place).
 When ready, use the -execute switch to execute the vmotions.
.PARAMETER Cluster
 Name of cluster to equalize distribution of vcpus.
.PARAMETER Server
 Name of VCenter which hosts the cluster.
.INPUTS
 None
.OUTPUTS
 Writes to screen the current host vcpu allocation, the VMs that will move and to which targets, and the resulting vcpu allocations
 if executed.
.EXAMPLE
 Set-VcpuAllocation -Cluster 'LRB Cluster 1' -Server eis-vc01cpc
  Default behavior without '-Execute' switch is to simply report: THis example gets the current allocation of Vcpus 
  displays report, then calculates the least amount of VM migrations to equalize the distribution of 
  virtual cores accross hosts in the cluster.  It will then report on the end resulting allocation if it were
  executed.
 Set-VcpuAllocation -Cluster 'LRB Cluster 1' -Server eis-vc01cpc -Execute
  This example will execute, meaing it will conduct all the migrations previously reported without the -execute switch. 
#>
    param(
        [parameter(Mandatory=$true)][string[]]$Cluster,
        [parameter(Mandatory=$true)][string[]]$Server,
        [string[]]$VMExclusion,
        [switch]$Execute
    )
    $cl = get-cluster $cluster -server $Server
    $report = @()
    $vmhosts = $cl | get-vmhost | ? {$_.ConnectionState -ne 'Disconnected' -and $_.ConnectionState -ne 'Maintenance' -and $_.ConnectionState -ne "NotResponding"}
    foreach ($vmhost in $vmhosts) {
        $vms = $vmhost | Get-VM | ? {$_.powerstate -eq 'poweredon' -AND $_.name -notin $VMExclusion}
        $row = "" | select Host,vms,pCPU,pMEMAvailable,vCPU,Available
        $row.Host = $vmhost
        $row.vms = @($vms)  # Capturing VMs running on host into this object so we do not have to keep running get-vm,
                            # we will manually move these around in this report object later.
        #$row.pCPU = $vmhost.NumCpu
        $row.pCPU = $vmhost.ExtensionData.Hardware.CpuInfo.NumCpuThreads
        $row.pMEMAvailable = ($vmhost.MemoryTotalGB - ($vms | Measure-Object -Property memorygb -Sum).sum ) -as [int]
        $row.vCPU = [int]($vms.NumCpu | measure -Sum).Sum
        $row.Available = [int]$($row.pCPU) - [int]$($row.vCPU)
        $report += $row
    }
    $report = $report | sort -Descending Available,pMEMAvailable # Sorting is critical to the function
    write-host "Starting Report: " -ForegroundColor Cyan
    $report | select * -ExcludeProperty vms | ft -autosize

    # Get Vms of the most over provisioned host, select the ONE VM with the least amount of resource as the VM to migrate
    # This will be the first VM we migrate and used throughout script as the source vm - msource.
    # Name notlike MB is specific to my site, excluding certain VM from migrating.
    $msource = $report[-1].Host | get-vm | ? {$_.powerstate -eq 'PoweredOn' -and $_.Name -notlike '*mb*'} | sort numcpu,memorygb | select -First 1
    $movecount = 0

    # Main loop
    # Determining if migration will take place by calculating available vCPUs of the least constrained host when/if the msource vm WERE to
    # migrate.  If that figure is greater than or equal to that same vm moving OFF of the HIGHEST contrained host meaning its available cpu count
    # is now lower than the one it will move to, the migration will not take place as that would mean there is no gain. This keeps migrating 
    # one vm at a time, adjusts all the available vcpus of each host in the list, sorts it again by available cpu capacity of hosts and repeats
    # the process until the while statement is false.

    while ($report[0].Available - $msource.numcpu -gt $report[-1].Available + $msource.NumCpu ) {
        $n = 0 
        # Available pMemory check This sets the target host to migrate to using the nth element in report
        while ($n -lt $report.Count) {
            if ($msource.MemoryGB -lt $report[$n].pMEMAvailable) {
                break
            } else {
                # Exclude this host from being considered any longer as it is out of mem using exclude flag
                $report[$n].Available = 0
                $n++ 
            }  
        }
        if ($Execute) { 
            # Do the migration
            Move-VM -VM $msource -Destination $report[$n].host -RunAsync -Confirm:$false | Out-Null
        } else {
            # Simply report it but do not migrate
            Write-Output "Would migrate $msource with $($msource.NumCpu)vCPUs/$($msource.memoryGB)GB from $($report[-1].host) to $($report[$n].host)"    
        }
        # Rather than waiting for a VM to move in order to get a new list of VMs on the hosts(Which we would have to wait
        # for the vmotion to complete THEN run a new get-vm), we are simply removing the VM objects from the report list.
        # We are using the report list as a means to track VMs and to what host they will move to and ajusting accordingly.
        # In other words, tracking the migrations without using vsphere.
    
        $report[-1].vms = $report[-1].vms | ? {$_ -notcontains $msource} # Removing the vm from the current hosting object
        $report[$n].vms += $msource # Adding the migrated vm to the target host object.
        $movecount ++
        $report[$n].Available -= $msource.NumCpu # Adjusting all the stats since we are doing this manually rather than waiting on migrations.
        $report[-1].Available += $msource.NumCpu
        $report[$n].pMEMAvailable -= $msource.memoryGB
        $report[-1].pMEMAvailable += $msource.memoryGB
        $report[$n].vCPU += $msource.NumCpu
        $report[-1].vCPU -= $msource.NumCpu
        $report = $report | sort -Descending Available,pMEMAvailable #sorting list again by available 
    
        # Get Vms of the most over provisioned host now with a new list, select the ONE VM with the least amount of resource as the VM to migrate.
    
        $msource = $report[-1].vms |  ? powerstate -eq 'PoweredOn' | sort numcpu,memorygb | select -First 1
    }

    Write-Host "New Report " -ForegroundColor Red
    $report | select * -ExcludeProperty vms | ft -autosize

    # pvcpu to vcpu ratio
    $vcputotal = ($report.vCPU | measure -Sum).sum 
    $pcputotal = ($report.pCPU | measure -Sum).sum 
    
    $ratio = "{0:N2}" -f ($vcputotal / $pcputotal)
    Write-Host "Vcpu to Pcpu ratio : $vcputotal/$pcputotal ($ratio)" -ForegroundColor DarkCyan
    if ($Execute){ Write-Host "Took $movecount move(s)" -ForegroundColor Red} 
    else {Write-Host "Would take $movecount move(s) , use '-Execute' to conduct the migrations" -ForegroundColor Red}

}