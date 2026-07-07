# module: network

Tier: OPTIONAL. Auto-runs SMBv1 detection + removal is offered as a strong-default question. Everything else opt-in via one-at-a-time conversational questions.

## Success criteria

At the end of this module the user has:
1. Snapshot of current network stack config (`Get-WindowsOptionalFeature`, `Get-NetAdapter`, `Get-DnsClientServerAddress`, `Get-DnsClient`, NetBIOS state, DoH state) BEFORE change.
2. SMBv1 optional feature removed if user opted in.
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

- **NEVER-AUTO** — nothing is applied without a question (removing SMBv1 requires reboot, changing DNS can break split-brain; both are asked).
- **ASK-USER** — SMBv1 removal, DNS privacy (DoH), DNS provider choice, NetBIOS / LLMNR off.
- **NEVER-TOUCH** — adapters that are `virtual` (Hyper-V, WSL2 `vEthernet (WSL)`, Docker `vEthernet (Default Switch)`, VPN tunnels).

### 3. Ask the user, one at a time

**Plain-English rule: DNS is "who translates website names into addresses"; skip protocol acronyms in the visible copy.** Keep raw provider IPs and adapter names INTERNAL. Use `AskUserQuestion` with `multiSelect: false` — one call per question.

---

**Q1 — SMBv1 removal**

> "There's an old Windows file-sharing protocol from 2005 called SMBv1 that has known security issues. Want me to remove it? (You won't miss it — modern devices don't use it.)"

*Skip if:* `.smbv1.installed = Disabled` (already gone).

*"I'm not sure" inference:* → YES. Modern home networks don't use SMBv1; the only real users are people with a very old NAS or Windows XP box. Almost universally the right answer.

*Controls:* `Disable-WindowsOptionalFeature -Online -FeatureName SMB1Protocol -NoRestart` + `Set-SmbServerConfiguration -EnableSMB1Protocol $false`.

---

**Q2 — Encrypted DNS (DoH)**

> "Do you want your internet name lookups (DNS) to be private, so your internet provider can't see which websites you visit? (Faster too. Free service from Cloudflare or Quad9.)"

*Skip if:* user is on a domain-joined machine AND the domain enforces DNS via GPO (would break internal name resolution).

*"I'm not sure" inference:* → YES with Cloudflare as default (see Q3 for provider choice). Cloudflare is the fastest DoH-capable public resolver; the privacy win is real; ISP DNS is universally slow and often has ad-injection.

*Controls:* `Add-DnsClientDohServerAddress` per configured DNS + per-adapter binding. If Q3 answers with a specific provider, use that provider's DoH template; if not answered yet, default to Cloudflare.

---

**Q3 — DNS provider choice** (asked only if Q2 was YES)

> "Which DNS provider do you want to use?"

Answers:
- `Cloudflare (fastest)`
- `Quad9 (blocks malware)`
- `Google (fast)`
- `Keep current` (uses provider's DoH if available; no override)
- `I'm not sure`

*Skip if:* Q2 was NO (nothing to override).
*Skip if:* domain-joined AND adapter is on the domain (would break internal name resolution).

*"I'm not sure" inference:* → `Cloudflare`. (`Quad9` is the runner-up if user is a nervous parent / on a family machine — flag in report but don't override.)

*Controls:* `Set-DnsClientServerAddress -InterfaceIndex <i> -ServerAddresses (@(<v4>,<v4-alt>))` per adapter. Provider IPs from `data/dns_providers.json`.

---

**Q4 — Legacy discovery protocols (NetBIOS / LLMNR)**

> "Turn off two old ways Windows finds devices by name on your local network? (One is called NetBIOS, the other LLMNR. Home users don't need them; disabling both is a small security win. Only breaks very old office / print setups.)"

*Skip if:* domain-joined (`.domain.joined=true`) — enterprise auth often still uses NBT, and disabling can break domain login.

*"I'm not sure" inference:* → YES on a home / small-office machine. NBT + LLMNR are common poisoning vectors, and 99% of home users have no dependency.

*Controls:* per-adapter `$adapter.SetTcpipNetbios(2)` on `Win32_NetworkAdapterConfiguration` (skip domain adapters). LLMNR: `HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient\EnableMulticast = 0`.

---

### After all questions, show the decision summary

> **DEPRECATED under the batched orchestrator (SKILL.md, 2026-07-07).** In full `/pc-cleaner` runs, this per-module summary is absorbed into the unified plan preview — do NOT emit it. Kept below as reference for the single-module invocation `/pc-cleaner network` where a per-module summary still makes sense.

```
Network / privacy tweaks — here's what I figured out:

  SMBv1 (old file share):    REMOVE       (auto — universally safe)
  Encrypted DNS (DoH):       ON           (you said yes)
  DNS provider:              Cloudflare   (auto: fastest)
  NetBIOS + LLMNR off:       YES          (auto — home machine)

Reboot needed for SMBv1 removal to fully unload.
Continue?  [Yes / No / Show me the list]
```

### 4. Build plan JSON

```json
{
  "removeSmbv1": true,
  "disableSmbServer1": true,
  "dns": {"provider":"cloudflare","adapters":["Wi-Fi","Ethernet"]},
  "doh": {"enable":true,"servers":[{"addr":"1.1.1.1","template":"https://cloudflare-dns.com/dns-query"}]},
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
- Cycle each touched adapter — but batched via SKILL.md cross-module contract #3.

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
- LLMNR disable removes some Windows-native network discovery — this is intentional for security (LLMNR is a common phishing surface) but can break "find printer by name" for home users. Skip on domain-joined.
- IPv6 DNS: many users disable IPv6 DNS by leaving it blank and expect IPv6 to fall back to IPv4 DNS. That's a misconception. If IPv6 is enabled on the adapter, set IPv6 DNS to the provider's v6 addresses.
- Do NOT disable IPv6 entirely (`DisabledComponents = 0xFF`). Microsoft explicitly says not to. Some Windows features (Home Group, Direct Access, Teams meeting join) break silently.

## Curated defaults / Data files

- `data/dns_providers.json` — `{name, ipv4[], ipv6[], dohTemplates[], notes}`. Extend to add providers (NextDNS, ControlD, Mullvad DoH, etc.).
- `data/network_risky_features.json` — features / protocols to alert on if enabled: SMBv1, LLMNR, NBT, WPAD, Web Client / WebDAV, Print Spooler over network. Referenced by the "risky features on this machine" section of the report.

## Machine profile branches

- `profile.flags.isLaptop=true` and WiFi as primary uplink: cycle WiFi adapter on config change; skip cycling Ethernet if not the active uplink.
- Domain-joined (`.domain.joined=true`): skip Q4 (NetBIOS) entirely; skip Q3 DNS override on domain adapter. Still ask Q1 (SMBv1) — it's independent.
- WSL2 present (`wsl -l -q` returns any distro): do not touch `vEthernet (WSL)` or `vEthernet (Default Switch)`.
- Hyper-V role installed: same — skip virtual switches.
- Tailscale installed: skip the Tailscale adapter (`Tailscale` interface). It manages its own DNS via MagicDNS.
- Multi-homed machine (>1 active adapter with default gateway): warn user — DNS override across both may cause split-brain resolution when both networks are up.
