# Diagnose: network-related legacy features + DNS state.
# Read-only. No admin needed. Emits JSON.

param(
    [string]$DataDir = (Join-Path $PSScriptRoot '..\..\data')
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot '..\_lib\common.ps1')

# SMBv1 state
$smbv1 = @{}
try {
    $f = Get-WindowsOptionalFeature -Online -FeatureName 'SMB1Protocol' -ErrorAction Stop
    $smbv1.Present = $true
    $smbv1.Enabled = ($f.State -eq 'Enabled')
    $smbv1.State   = [string]$f.State
} catch {
    $smbv1.Present = $false
    $smbv1.Error   = $_.Exception.Message
}

# LLMNR (Link-Local Multicast Name Resolution)
$llmnr = @{}
try {
    $k = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' -Name EnableMulticast -ErrorAction SilentlyContinue
    $llmnr.PolicyValue = if ($k) { $k.EnableMulticast } else { $null }
    $llmnr.Disabled = ($llmnr.PolicyValue -eq 0)
} catch {}

# NetBIOS over TCP per adapter
$nbt = @()
try {
    Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=TRUE' | ForEach-Object {
        $mode = switch ($_.TcpipNetbiosOptions) {
            0 { 'Default (from DHCP)' }
            1 { 'Enabled' }
            2 { 'Disabled' }
            default { 'Unknown' }
        }
        $nbt += [PSCustomObject]@{
            Adapter = $_.Description
            Mode = $mode
            Raw = $_.TcpipNetbiosOptions
        }
    }
} catch {}

# DNS servers on active adapters
$dns = @()
try {
    Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.ServerAddresses.Count -gt 0 } |
        ForEach-Object {
            $dns += [PSCustomObject]@{
                Interface       = $_.InterfaceAlias
                ServerAddresses = $_.ServerAddresses -join ','
            }
        }
} catch {}

# DoH (Windows 11 native)
$doh = @{}
try {
    $doh.Registered = @(Get-DnsClientDohServerAddress -ErrorAction SilentlyContinue | Select-Object ServerAddress, DohTemplate)
} catch {}

[PSCustomObject]@{
    profile   = Get-MachineProfile
    smbv1     = $smbv1
    llmnr     = $llmnr
    netbios   = $nbt
    dns       = $dns
    doh       = $doh
} | ConvertTo-Json -Depth 6
