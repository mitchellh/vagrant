#Requires -Modules VagrantMessages

param(
    [Parameter(Mandatory=$true)]
    [string]$VmId
)

$ErrorActionPreference = "Stop"

try {
    $vm = Hyper-V\Get-VM -Id $VmId
} catch {
    Write-ErrorMessage "Failed to locate VM: ${PSItem}"
    exit 1
}

try {
    $netdev = Hyper-V\Get-VMNetworkAdapter -VM $vm | Select-Object -Index 0
    if ($netdev -ne $null) {
        if ($netdev.IpAddresses.Length -gt 0) {
            foreach ($ip_address in $netdev.IpAddresses) {
                if ($ip_address.Contains(".") -And [string]::IsNullOrEmpty($ip4_address)) {
                    $ip4_address = $ip_address
                } elseif ($ip_address.Contains(":") -And [string]::IsNullOrEmpty($ip6_address)) {
                    $ip6_address = $ip_address
                }
            }
        }

        # If no address was found in the network settings, check for
        # neighbor with mac address and see if an IP exists
        if (([string]::IsNullOrEmpty($ip4_address)) -And ([string]::IsNullOrEmpty($ip6_address))) {
            $macaddress = $netdev.MacAddress -replace '(.{2})(?!$)', '${1}-'
            $addr = Get-NetNeighbor -LinkLayerAddress $macaddress -ErrorAction SilentlyContinue | select IPAddress
            if ($addr) {
                $ip_address = $addr.IPAddress
                if ($ip_address.Contains(".")) {
                    $ip4_address = $ip_address
                } elseif ($ip_address.Contains(":")) {
                    $ip6_address = $ip_address
                }
            }
        }
    }

    if (-Not ([string]::IsNullOrEmpty($ip4_address))) {
        $guest_ipaddress = $ip4_address
    } elseif (-Not ([string]::IsNullOrEmpty($ip6_address))) {
        $guest_ipaddress = $ip6_address
    }

    if (-Not ([string]::IsNullOrEmpty($guest_ipaddress))) {
        $resultHash = @{
            ip = $guest_ipaddress
        }
        $result = ConvertTo-Json $resultHash
        Write-OutputMessage $result
    } else {
        Write-ErrorMessage "Failed to determine IP address"
        exit 1
    }
} catch {
    Write-ErrorMessage "Unexpected error while detecting network configuration: ${PSItem}"
    exit 1
}
