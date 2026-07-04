# module: profile

Tier: CORE. Auto-runs first on every full pass. No user prompts. Produces the JSON every other module reads.

## Success criteria

At the end of this module the user has:
1. A `profile.json` in the snapshot root that every subsequent module reads as authoritative machine state.
2. A one-screen summary printed to the run log: model, CPU, GPUs, WiFi chip + subsystem, RAM, disk, battery presence, OS build, available sleep states.
3. Zero side effects. Read-only.

## Flow

### 1. Diagnose

Run `ps/diagnose/profile.ps1`. It shells out to WMI / CIM / registry / `powercfg` and emits a single JSON blob to stdout:

| Field | Source |
|---|---|
| `system.manufacturer`, `system.model`, `system.mtm` | `Win32_ComputerSystem`, `Win32_ComputerSystemProduct` |
| `system.chassis` | `Win32_SystemEnclosure.ChassisTypes` (8/9/10/14 = laptop) |
| `cpu.name`, `cpu.vendor`, `cpu.family`, `cpu.cores`, `cpu.logicalCount` | `Win32_Processor` |
| `cpu.generation` | Parsed from `cpu.name` (e.g. "Ryzen 9 6900HS" → vendor=AMD, family=Ryzen 6000) |
| `gpu[].name`, `gpu[].vendor`, `gpu[].driverVersion`, `gpu[].driverDate` | `Win32_VideoController` |
| `ram.totalGB`, `ram.slots`, `ram.modules[]` | `Win32_PhysicalMemory` |
| `disk[]` | `Get-PhysicalDisk` + `Get-Disk` (model, firmware, media type, size, health) |
| `wifi.chip`, `wifi.vendorId`, `wifi.deviceId`, `wifi.subsystemId` | `Get-PnpDevice -Class Net` + registry `HardwareID` under `Enum\PCI` |
| `bt.chip`, `bt.driverProvider` | `Get-PnpDevice -Class Bluetooth` |
| `battery.present`, `battery.designCapacity`, `battery.fullCapacity` | `Win32_Battery` + `powercfg /batteryreport` (parsed) |
| `os.build`, `os.edition`, `os.installDate` | `Win32_OperatingSystem`, `HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion` |
| `sleep.states` | Parse `powercfg /a` (S1/S2/S3 present? S0ix? Hibernate?) |
| `firmware.mode`, `firmware.secureBoot`, `firmware.tpm` | `Confirm-SecureBootUEFI`, `Get-Tpm`, `bcdedit /enum` |
| `net.adapters[]` | `Get-NetAdapter` — id, name, chip, up/down, WiFi/wired |

### 2. Derive flags

Add a `.flags` object with booleans other modules key off:

- `isLaptop` — chassis type ∈ {8,9,10,14} OR battery present.
- `isModernStandbyOnly` — `sleep.states` has S0ix, not S3.
- `isRyzen6000Plus` — vendor=AMD AND family ≥ Ryzen 6000. (Sleep bugs, TDR risk.)
- `isIntel11Plus` — vendor=Intel AND generation ≥ 11. (Also Modern Standby prone.)
- `hasDiscreteGPU` — >1 GPU entry, one non-integrated.
- `hasComboWlanBt` — WLAN chip vendor matches BT chip vendor (Realtek/Intel/Qualcomm combo card).
- `oemSubsystemMismatch` — subsystem vendor ID != OEM vendor ID (e.g. Lenovo laptop with `103C` HP subsystem WiFi). Drivers module reads this.
- `isProEdition` — `os.edition` contains "Pro" or "Enterprise". Affects gpsvc / BitLocker copy.

### 3. Write

Write to `<snapshotRoot>/profile.json`. Also update `<snapshotRoot>/profile.summary.md` — a human-readable one-pager useful when reviewing an old snapshot.

### 4. Report

Print one screen: model, CPU, GPUs (with driver dates), RAM, disk, WiFi chip + subsystem (highlighted if `oemSubsystemMismatch`), battery health %, OS build, sleep states available.

## Known gotchas

- `Win32_ComputerSystemProduct` on some OEM images returns "To Be Filled By O.E.M." — fall back to `Get-CimInstance -Namespace root\wmi -ClassName MS_SystemInformation`.
- `Win32_Battery.FullChargeCapacity` is unreliable on many laptops. The authoritative source is `powercfg /batteryreport /output <path>` HTML, parsed for `DESIGN CAPACITY` and `FULL CHARGE CAPACITY`. That call takes 1-2 s.
- `powercfg /a` output is localized. Match on the presence of "S0 Low Power Idle" / "S3" / "Hibernate" substrings, not exact strings. On Hungarian locale the strings are Hungarian.
- WMI subsystem ID is not always populated. Fall back to registry `HKLM:\SYSTEM\CurrentControlSet\Enum\PCI\<vidDid>\<inst>\HardwareID` — grep for `SUBSYS_XXXXYYYY`.
- Some Ryzen laptops enumerate the iGPU as "AMD Radeon(TM) Graphics" with no clue it's a 680M/780M. Cross-reference CPU family to name the iGPU.
- Discrete GPU may be in D3cold (MUX-off) and not enumerate. Note `hasDiscreteGPU` as `unknown` if TDR count for `nvlddmkm`/`amdkmdag` in the last 30 days is non-zero — evidence of a dGPU that comes and goes.
- On PowerShell 5.1 default output is UTF-16 LE with BOM. `ConvertTo-Json | Out-File` must include `-Encoding utf8` or downstream diagnose scripts get garbage.

## Curated defaults / Data files

- `data/cpu_generations.json` — maps CPU model regex to `{vendor, family, generation, modernStandby: bool}`. Extend when a new CPU line ships. Schema: array of `{regex, vendor, family, generation, notes}`.
- `data/oem_pci_vendors.json` — VID → OEM name lookup (`103C=HP`, `17AA=Lenovo`, `1028=Dell`, `1043=ASUS`, `1458=Gigabyte`). Used by `oemSubsystemMismatch` derivation.

## Machine profile branches

Profile itself has none — it produces the profile. But: if `Win32_Battery` errors out on a machine claiming to be a laptop by chassis type, mark `flags.batteryQueryFailed=true` and other modules degrade gracefully (power module skips battery-dependent branches, unused-apps still runs).
