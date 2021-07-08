# Looks for a disk drive over 249 GB that *should* be the "D" drive and sets it as the D drive if it is not

class FixPartitions {
    [object] $PartitionList
  
    FixPartitions (){
      Write-Host "Checking for correct partitioning information"
      $this.PartitionList = get-partition
    }
  
    [void] CorrectPartition() {
      $CurrentD = $this.partitionlist | where-object { $_.DriveLetter -eq "D" }
      $correctD = $this.PartitionList | where-object { $_.Size -gt $(249 * 1024 * 1024 * 1024) }
  
      if ($correctD.DriveLetter -ne "D") {
        Write-Host "Fixing incorrect D drive"
        Remove-PartitionAccessPath -DiskNumber $CurrentD.DiskNumber -PartitionNumber $CurrentD.PartitionNumber -AccessPath $($CurrentD.DriveLetter + ":")
        Get-Partition -DiskNumber $CorrectD.DiskNumber | Set-Partition -NewDriveLetter D
      }    
    }
  }

[FixPartitions] $Fix = [FixPartitions]::New()
$fix.CorrectPartition()
Write-Host "Done"