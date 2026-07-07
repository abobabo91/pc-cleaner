# Apply: SMBv1 removal, LLMNR off, NetBIOS-over-TCP off, optional DNS/DoH override.
# REQUIRES ADMIN.

param(
    [Parameter(Mandatory=$true)][string]$Plan,
    [string]$SnapshotDir,
    [switch]$IKnowWhatImDoing
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\_lib\common.ps1')
Assert-Admin

if (-not $SnapshotDir) { $SnapshotDir = New-SnapshotDir -Module 'network' }
$log = Join-Path $SnapshotDir 'apply.log'
"===== network apply started $(Get-Date -Format o) =====" | Out-File $log -Encoding UTF8

$planData = Get-Content $Plan -Raw | ConvertFrom-Json
$reverts = New-Object System.Collections.Generic.List[string]

# Pre-checks — added 2026-07-07 after audit. Each network change requires
# confirmed:true in the plan (set by the orchestrator after the user answers).
# DNS override additionally refuses if a VPN adapter is Up, or if the current
# network profile has an active captive-portal state, because forcing public
# DNS breaks both.
$blocked = New-Object System.Collections.Generic.List[string]
$vpnActive = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {
    $_.Status -eq 'Up' -and ($_.InterfaceDescription -match 'VPN|TAP|OpenVPN|WireGuard|Wintun|NordLynx|Tailscale|ZeroTier' -or $_.Name -match 'VPN|OpenVPN|WireGuard|NordVPN|ExpressVPN|Tailscale|ZeroTier')
})
$captivePortal = $false
try {
    $profiles = Get-NetConnectionProfile -ErrorAction SilentlyContinue
    foreach ($p in $profiles) {
        if ($p.IPv4Connectivity -eq 'LocalNetwork' -or $p.IPv6Connectivity -eq 'LocalNetwork') { $captivePortal = $true }
    }
} catch {}

# Snapshot
$snap = Join-Path $SnapshotDir 'snapshot.json'
$before = [PSCustomObject]@{
    Timestamp = (Get-Date).ToString('o')
    SMB1Feature = (Get-WindowsOptionalFeature -Online -FeatureName SMB1Protocol -ErrorAction SilentlyContinue).State
    DNSServers = @(Get-DnsClientServerAddress -AddressFamily IPv4 | Select-Object InterfaceAlias, ServerAddresses)
}
$before | ConvertTo-Json -Depth 4 | Set-Content $snap -Encoding UTF8

# 1. Remove SMBv1
if ($planData.disableSMBv1) {
    if (-not $planData.disableSMBv1Confirmed -and -not $IKnowWhatImDoing) {
        Write-Log $log 'BLOCK' "SMBv1 disable requested but disableSMBv1Confirmed:true missing. Ask the user first — old NAS boxes and network printers can still require it."
        $blocked.Add('disableSMBv1')
    } else {
    try {
        $f = Get-WindowsOptionalFeature -Online -FeatureName SMB1Protocol
        if ($f.State -eq 'Enabled') {
            Disable-WindowsOptionalFeature -Online -FeatureName SMB1Protocol -NoRestart -ErrorAction Stop | Out-Null
            Write-Log $log 'APPLY' "SMBv1 protocol feature disabled (reboot needed to fully unload)"
            $reverts.Add("Enable-WindowsOptionalFeature -Online -FeatureName SMB1Protocol -NoRestart")
        } else {
            Write-Log $log 'SKIP' "SMBv1 already disabled"
        }
    } catch {
        Write-Log $log 'ERR' "SMBv1: $($_.Exception.Message)"
    }
    }
}

# 2. LLMNR off
if ($planData.disableLLMNR) {
    if (-not $planData.disableLLMNRConfirmed -and -not $IKnowWhatImDoing) {
        Write-Log $log 'BLOCK' "LLMNR disable requested but disableLLMNRConfirmed:true missing. On old networks LLMNR is how printer hostnames resolve."
        $blocked.Add('disableLLMNR')
    } else {
    try {
        $p = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient'
        if (-not (Test-Path $p)) { New-Item -Path $p -Force | Out-Null }
        $before = (Get-ItemProperty -Path $p -Name EnableMulticast -ErrorAction SilentlyContinue).EnableMulticast
        Set-ItemProperty -Path $p -Name EnableMulticast -Value 0 -Type DWord
        Write-Log $log 'APPLY' "LLMNR disabled via policy (was $before)"
        if ($null -ne $before) {
            $reverts.Add("Set-ItemProperty -Path '$p' -Name EnableMulticast -Value $before -Type DWord")
        } else {
            $reverts.Add("Remove-ItemProperty -Path '$p' -Name EnableMulticast -ErrorAction SilentlyContinue")
        }
    } catch { Write-Log $log 'ERR' "LLMNR: $($_.Exception.Message)" }
    }
}

# 3. NetBIOS over TCP off per adapter
if ($planData.disableNetBIOS) {
    if (-not $planData.disableNetBIOSConfirmed -and -not $IKnowWhatImDoing) {
        Write-Log $log 'BLOCK' "NetBIOS disable requested but disableNetBIOSConfirmed:true missing. Domain-joined machines and some legacy Windows share setups still use it."
        $blocked.Add('disableNetBIOS')
    } else {
    try {
        Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=TRUE' | ForEach-Object {
            $adapter = $_.Description
            $before = $_.TcpipNetbiosOptions
            $result = $_ | Invoke-CimMethod -MethodName SetTcpipNetbios -Arguments @{ TcpipNetbios = 2 }  # 2 = Disable
            if ($result.ReturnValue -eq 0) {
                Write-Log $log 'APPLY' "NetBIOS over TCP disabled on: $adapter (was $before)"
                $reverts.Add("Get-CimInstance Win32_NetworkAdapterConfiguration -Filter `"Description='$adapter'`" | Invoke-CimMethod -MethodName SetTcpipNetbios -Arguments @{ TcpipNetbios = $before }")
            } else {
                Write-Log $log 'WARN' "NetBIOS on $adapter : SetTcpipNetbios returned $($result.ReturnValue)"
            }
        }
    } catch { Write-Log $log 'ERR' "NetBIOS: $($_.Exception.Message)" }
    }
}

# 4. Optional DNS override
if ($planData.dnsOverride -and $planData.dnsOverride.ipv4) {
    $dnsBlocked = $false
    if (-not $planData.dnsOverrideConfirmed -and -not $IKnowWhatImDoing) {
        Write-Log $log 'BLOCK' "DNS override requested but dnsOverrideConfirmed:true missing. Ask the user first."
        $blocked.Add('dnsOverride:no-confirm')
        $dnsBlocked = $true
    }
    if ($vpnActive.Count -gt 0 -and -not $IKnowWhatImDoing) {
        Write-Log $log 'BLOCK' "DNS override refused: VPN adapter is Up ($(($vpnActive | ForEach-Object { $_.Name }) -join ', ')). Forcing public DNS on top of a VPN can leak requests around the tunnel or break split-DNS. Pass -IKnowWhatImDoing if you actually want this."
        $blocked.Add('dnsOverride:vpn-active')
        $dnsBlocked = $true
    }
    if ($captivePortal -and -not $IKnowWhatImDoing) {
        Write-Log $log 'BLOCK' "DNS override refused: current network is a captive-portal / no-Internet profile. Public DNS will break the login redirect."
        $blocked.Add('dnsOverride:captive-portal')
        $dnsBlocked = $true
    }
    if (-not $dnsBlocked) {
    try {
        $adapters = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.HardwareInterface }
        foreach ($a in $adapters) {
            $ifBefore = (Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4).ServerAddresses -join ','
            Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ServerAddresses $planData.dnsOverride.ipv4
            Write-Log $log 'APPLY' "DNS on $($a.Name) -> $($planData.dnsOverride.ipv4 -join ',')  (was $ifBefore)"
            $reverts.Add("Set-DnsClientServerAddress -InterfaceIndex $($a.ifIndex) -ResetServerAddresses")
        }
    } catch { Write-Log $log 'ERR' "DNS override: $($_.Exception.Message)" }
    }
}

$revertScript = Join-Path $SnapshotDir 'revert.ps1'
$header = "# Auto-generated by pc-cleaner (network). Reverts SMBv1, LLMNR, NetBIOS, DNS.`n`n"
Set-Content -Path $revertScript -Value ($header + ($reverts -join "`n")) -Encoding UTF8

if ($blocked.Count -gt 0) {
    $blockedJson = Join-Path $SnapshotDir 'blocked-network.json'
    $blocked | ConvertTo-Json | Set-Content -Path $blockedJson -Encoding UTF8
    Write-Host ""
    Write-Host "Blocked $($blocked.Count) network change(s): $($blocked -join ', ')" -ForegroundColor Yellow
    Write-Host "See apply.log for reasons." -ForegroundColor DarkGray
}

"===== network apply done $(Get-Date -Format o) =====" | Add-Content -Path $log
Write-Host "Snapshot: $snap"
Write-Host "Revert  : $revertScript"
