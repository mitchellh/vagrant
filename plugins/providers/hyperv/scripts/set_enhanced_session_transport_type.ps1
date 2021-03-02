#Requires -Modules VagrantMessages

param (
    [parameter (Mandatory=$true)]
    [Guid] $VMID,
    [parameter (Mandatory=$true)]
    [string] $Type
)

$ErrorActionPreference = "Stop"

try {
    $VM = Hyper-V\Get-VM -Id $VMID
} catch {
    Write-ErrorMessage "Failed to locate VM: ${PSItem}"
    exit 1
}

try {
    # HyperV 1.1 (Windows Server 2012R2) crashes on this call. Vagrantfiles before 2.2.10 do break without skipping this.
    $present = Get-Command Hyper-V\Set-VM -ParameterName EnhancedSessionTransportType -ErrorAction SilentlyContinue
    if($present) {
        Hyper-V\Set-VM -VM $VM -EnhancedSessionTransportType $Type
    }else{
        Write-OutputMessage "This version of HyperV does not support EnhancedSessionTransportType, ignoring."
    }
} catch {
    Write-ErrorMessage "Failed to assign EnhancedSessionTransportType to ${Type}:${PSItem}"
    exit 1
}
