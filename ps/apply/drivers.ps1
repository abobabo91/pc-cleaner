# Apply: for a list of user-confirmed drivers, look up matching OEM SoftPaq / driver package
# and DOWNLOAD it to snapshot dir. Does NOT auto-install — driver install is high-risk
# and requires user click-through for the vendor's installer.
#
# The user then runs the .exe manually. Best behavior we can provide safely.

param(
    [Parameter(Mandatory=$true)][string]$Plan,
    [string]$SnapshotDir
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot '..\_lib\common.ps1')

if (-not $SnapshotDir) { $SnapshotDir = New-SnapshotDir -Module 'drivers' }
$log = Join-Path $SnapshotDir 'apply.log'
"===== drivers apply started $(Get-Date -Format o) =====" | Out-File $log -Encoding UTF8

$planData = Get-Content $Plan -Raw | ConvertFrom-Json

# Plan JSON shape:
#   {
#     "downloads": [
#       { "url": "https://ftp.hp.com/pub/softpaq/sp162501-163000/sp162860.exe",
#         "expectedName": "sp162860_RealtekWLAN.exe",
#         "reason": "Realtek RTL8822CE WLAN driver (2024.10.230.600) - stale local driver",
#         "vendor": "HP", "chip": "RTL8822CE" }
#     ]
#   }

$downloadsDir = Join-Path $SnapshotDir 'downloaded'
New-Item -ItemType Directory -Path $downloadsDir -Force | Out-Null

$results = New-Object System.Collections.Generic.List[object]
$headers = @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' }

foreach ($item in @($planData.downloads)) {
    $out = Join-Path $downloadsDir $item.expectedName
    try {
        Invoke-WebRequest -Uri $item.url -OutFile $out -Headers $headers -UseBasicParsing -ErrorAction Stop
        $sig = Get-AuthenticodeSignature $out
        $sizeMB = [math]::Round((Get-Item $out).Length / 1MB, 1)
        $results.Add([PSCustomObject]@{
            Success       = $true
            Path          = $out
            SizeMB        = $sizeMB
            SigStatus     = $sig.Status.ToString()
            Signer        = if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { $null }
            Url           = $item.url
            Chip          = $item.chip
            Vendor        = $item.vendor
            Reason        = $item.reason
        })
        Write-Log $log 'DOWNLOADED' "$($item.chip) from $($item.vendor): $out ($sizeMB MB, sig=$($sig.Status))"
    } catch {
        $results.Add([PSCustomObject]@{
            Success = $false
            Url     = $item.url
            Error   = $_.Exception.Message
            Chip    = $item.chip
        })
        Write-Log $log 'ERR' "$($item.chip): $($_.Exception.Message)"
    }
}

$results | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $SnapshotDir 'downloads.json') -Encoding UTF8

# Emit revert (there's nothing to revert since we didn't install)
$revert = Join-Path $SnapshotDir 'revert.ps1'
Set-Content $revert -Value "# drivers module downloaded installers but did NOT install them.`n# To remove downloaded installers:`n#   Remove-Item -Recurse '$downloadsDir'`n" -Encoding UTF8

"===== drivers apply done. $($results.Count) downloads, $(($results | Where-Object Success).Count) succeeded =====" | Add-Content -Path $log
Write-Host ""
Write-Host "Downloaded installers (RUN THEM MANUALLY as Administrator):"
$results | Where-Object Success | ForEach-Object {
    Write-Host "  $($_.Chip) [$($_.Vendor)]: $($_.Path)  (signed by $($_.Signer -replace '^CN=([^,]+).*','$1'))"
}
