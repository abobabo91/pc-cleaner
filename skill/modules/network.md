# module: network

Tier: OPTIONAL. Auto-runs SMBv1 detection + removal (strong default). Everything else opt-in via `AskUserQuestion`.

## Success criteria

At the end of this module the user has:
1. Snapshot of current network stack config (`Get-WindowsOptionalFeature`, `Get-NetAdapter`, `Get-DnsClientServerAddress`, `Get-DnsClient`, NetBIOS state, DoH state) BEFORE change.
2. SMBv1 optional feature removed if present.
3. DoH enabled per-adapter if user opts in.
4. DNS overridden per-adapter if user opts in (Cloudflare/Quad9/custom).
5. NetBIOS over TCP/IP disabled per-adapter if user opts in (unless the machine is on a domain).
6. A `revert.ps1`.

## Flow

### 1. Diagnose

Run `ps/diagnose/network.ps1`. Emits:
- `.smbv1.installed` — `(Get-WindowsOptionalFeature -Online -FeatureName SMB1Protocol).State`
- `.smbServer.enabled` — `(Get-SmbServerConfiguration).EnableSMB1Protocol`
- `.adapters[]` — for each: `Name`, `InterfaceAlias`, `InterfaceIndex`, `Status`, `Kind` (WiFi / Wired / vEthernet / Loopback), `DnsServers[]`, `DnsAutoconfigured: bool`, `DoHState` per address (`Get-DnsClientDohServerAddress`), `NetBIOS` (`(Get-CimInstance Win32_NetworkAdapterConfiguration).TcpipNetbiosOptions` — 0=default, 1=enabled, 2=disabled), `LmhostsLookup`.
- `.domain.joined` — `(Get-CimInstance Win32_ComputerSystem).PartOfDomain`
- `.wifi.currentSsid` — `netsh wlan show interfaces`
- `.knownVpnClients[]` — installed VPN clients (OpenVPN, WireGuard, Tailscale, Cisco AnyConnect, Windows built-in VPN entries via `Get-VpnConnection -AllUserConnection`).

### 2. Categorize

- **AUTO** — remove SMBv1 optional feature + `Set-SmbServerConfiguration -EnableSMB1Protocol $false` if enabled.
- **ASK** — DoH per-adapter; DNS override; NetBIOS off.
- **NEVER** — touch adapters that are `virtual` (Hyper-V, WSL2 `vEthernet (WSL)`, Docker `vEthernet (Default Switch)`, VPN tunnels).

### 3. Ask the user

**Plain-English rule: DNS is "who translates website names into addresses"; skip protocol acronyms in the visible copy.** Keep raw provider IPs and adapter names INTERNAL.

`AskUserQuestion`, ≤3 questions:

**Q1 — "Which company do you want to translate website names to addresses?" (pick one — this is your DNS provider; it sees which sites you visit)** — `multiSelect: false`
- Leave it alone (your internet provider or WiFi router decides — the default)
- Cloudflare — fast, doesn't log
- Quad9 — blocks known-malware sites automatically
- Google — fast, but Google sees the lookups
- AdGuard Family — blocks ads and adult sites at the network level

**Q2 — "Encrypt the lookups so your internet provider can't see which sites you visit?" (check to enable)** — `multiSelect: true`
- Yes, encrypt these lookups (uses the provider I picked above)

**Q3 — "Turn off some old network-discovery features you almost certainly don't need?" (check all that apply — these are minor security wins)** — `multiSelect: true`
- Turn off an old Windows way of finding computers by name on the local network (only breaks things on very old office/print setups)
- Turn off another legacy "find device by name on WiFi" feature (rarely used since Windows 10)

If user is on a domain (`.domain.joined=true`), skip Q3 — enterprise auth often still uses NBT.

### 4. Build plan JSON

```json
{
  "removeSmbv1": true,
  "disableSmbServer1": true,
  "dns": {"provider":"cloudflare","adapters":["Wi-Fi","Ethernet"]},
  "doh": {"enable":true,"servers":[{"addr":"1.1.1.1","template":"https://cloudflare-dns.com/dns-query"},...]},
  "netbios": {"disable":true,"skipDomainAdapters":true},
  "llmnr": {"disable":true}
}
```

### 5. Apply (elevated)

Call `ps/apply/network.ps1 -Plan <path> -SnapshotDir <path>`. It:
- Snapshots current config to `<snapshotDir>/network/state-before.json` + per-adapter `Get-NetIPConfiguration` output.
- SMBv1: `Disable-WindowsOptionalFeature -Online -FeatureName SMB1Protocol -NoRestart`. Restart required — flag in report.
- SMB server: `Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force`.
- DNS: `Set-DnsClientServerAddress -InterfaceIndex <i> -ServerAddresses (@("1.1.1.1","1.0.0.1"))` per adapter. Then `Clear-DnsClientCache`.
- DoH: `Add-DnsClientDohServerAddress -ServerAddress <addr> -DohTemplate <tmpl> -AllowFallbackToUdp $false -AutoUpgrade $true` per server, then per-adapter `Set-DnsClientDohServerAddress` if needed to bind. Some Win11 builds need `netsh dns add encryption server=<ip> dohtemplate=<tmpl> autoupgrade=yes udpfallback=no` as fallback.
- NetBIOS: for each adapter, `$adapter.SetTcpipNetbios(2)` via `Get-CimInstance Win32_NetworkAdapterConfiguration`. Skip domain adapters.
- LLMNR: `HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient\EnableMulticast = 0`.
- Cycle each touched adapter: `Disable-NetAdapter; Enable-NetAdapter` (or `Restart-NetAdapter`) — DNS changes take effect immediately, but adapter cycle ensures WLAN 802.1X etc. reinitializes cleanly.

### 6. Report

- SMBv1 removed / already absent.
- DNS provider set (or unchanged).
- DoH status per server.
- NetBIOS state after.
- Note: SMBv1 removal requires reboot to fully unload the driver.

## Known gotchas

- SMBv1 is TWO things: the optional feature (client + server drivers) AND the server-side toggle (`EnableSMB1Protocol` in `Set-SmbServerConfiguration`). Both need to be off for full removal. Disabling only the optional feature leaves `Set-SmbServerConfiguration` false-but-unloadable, which is fine on next boot but confuses `Get-SmbServerConfiguration` until then.
- Restart after SMBv1 removal is required — the `mrxsmb10.sys` driver won't unload while services are using it. Flag reboot need.
- On corporate networks, NetBIOS is sometimes still needed for legacy print servers and share browsing. Skip disabling on domain-joined machines unless user overrides.
- `Set-DnsClientDohServerAddress` with `-AutoUpgrade $true` means Windows tries DoH first, falls back to plain DNS on failure. This is usually right, but if the user is trying to enforce DoH (e.g. bypass ISP DNS hijacking) they need `-AllowFallbackToUdp $false`. Different intent — ask if strict is what they want.
- Some VPN clients (Cisco AnyConnect, Sophos, GlobalProtect) install their own NDIS filter and grab DNS at connect. Our per-adapter DNS is overridden while VPN is connected. That's expected — note it.
- WSL2 uses `resolv.conf` inside the distro with `nameserver 172.<n>.<n>.1` pointing at the Hyper-V vNIC. Changing HOST DNS does NOT change WSL DNS unless `/etc/wsl.conf` has `generateResolvConf=false`. Do not touch `vEthernet (WSL)`.
- `netsh dns show encryption` and `Get-DnsClientDohServerAddress` sometimes disagree on Win11 22H2 — the netsh view is authoritative for what's actually being used. Prefer netsh for verification.
- LLMNR disable removes some Windows-native network discovery — this is intentional for security (LLMNR is a common phishing surface) but can break "find printer by name" for home users. Ask before applying.
- IPv6 DNS: many users disable IPv6 DNS by leaving it blank and expect IPv6 to fall back to IPv4 DNS. That's a misconception. If IPv6 is enabled on the adapter, set IPv6 DNS to the provider's v6 addresses.
- Do NOT disable IPv6 entirely (`DisabledComponents = 0xFF`). Microsoft explicitly says not to. Some Windows features (Home Group, Direct Access, Teams meeting join) break silently.

## Curated defaults / Data files

- `data/dns_providers.json` — `{name, ipv4[], ipv6[], dohTemplates[], notes}`. Extend to add providers (NextDNS, ControlD, Mullvad DoH, etc.).
- `data/network_riskyFeatures.json` — features / protocols to alert on if enabled: SMBv1, LLMNR, NBT, WPAD, Web Client / WebDAV, Print Spooler over network. Referenced by the "risky features on this machine" section of the report.

## Machine profile branches

- `profile.flags.isLaptop=true` and WiFi as primary uplink: cycle WiFi adapter on config change; skip cycling Ethernet if not the active uplink.
- Domain-joined (`.domain.joined=true`): skip NetBIOS disable, skip DNS override on domain adapter (would break internal name resolution). Still apply SMBv1 removal.
- WSL2 present (`wsl -l -q` returns any distro): do not touch `vEthernet (WSL)` or `vEthernet (Default Switch)`.
- Hyper-V role installed: same — skip virtual switches.
- Tailscale installed: skip the Tailscale adapter (`Tailscale` interface). It manages its own DNS via MagicDNS.
- Multi-homed machine (>1 active adapter with default gateway): warn user — DNS override across both may cause split-brain resolution when both networks are up.
