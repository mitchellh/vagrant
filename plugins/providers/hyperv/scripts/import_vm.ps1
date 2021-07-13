#Requires -Modules VagrantVM, VagrantMessages

param(
    [parameter (Mandatory=$true)]
    [string] $VMConfigFile,
    [parameter (Mandatory=$true)]
    [string] $DestinationDirectory,
    [parameter (Mandatory=$true)]
    [string] $DataPath,
    [parameter (Mandatory=$false)]
    [switch] $LinkedClone,
    [parameter (Mandatory=$false)]
    [string] $VMName=$null,
    # The full paths to the virtual disk files in the downloaded and unpacked box, usually in $ENV:VAGRANT_HOME
    [parameter (Mandatory=$false)]
    [string]$SourceDiskFilesString = [string]::Empty,
    [parameter (Mandatory=$false)]
    [string[]] $SourceDiskFiles = ($SourceDiskFilesString -split "\|")
)

$ErrorActionPreference = "Stop"

try {
    if($LinkedClone) {
        $linked = $true
    } else {
        $linked = $false
    }
    $SourceFileHash = @{}
    foreach ($sourceFile in $SourceDiskFiles) {
        $SourceFileHash.Add([System.IO.Path]::GetFileName($sourceFile).ToLower(), $sourceFile)
    }

    $VM = New-VagrantVM -VMConfigFile $VMConfigFile -DestinationDirectory $DestinationDirectory `
      -DataPath $DataPath -LinkedClone $linked -VMName $VMName -SourceFileHash $SourceFileHash

    $Result = @{
        id = $VM.Id.Guid;
    }
    Write-OutputMessage (ConvertTo-Json $Result)
} catch {
    Write-ErrorMessage "${PSItem}"
    exit 1
}
