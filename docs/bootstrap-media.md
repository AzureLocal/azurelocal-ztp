# Bootstrap media

> How the newest maintenance (bootstrap) ISO is found, downloaded and verified, what goes on the media and what does not, and exactly which statements were checked live.

Scripts: `Get-ZtpBootstrapIso.ps1` and `Invoke-ZtpPrepareMedia.ps1` in `scripts/simplified-provisioning/`. `Invoke-ZtpPrepareMedia.ps1` resolves the ISO and builds and checks the images, nothing else. Every script is a plan by default and writes nothing until `-Execute`. Facts below were probed on **15 Oct 2026**; Microsoft can change any of them, so the scripts re-probe on every run.

## Which maintenance ISO is the newest

Microsoft documents the download as portal links (Azure Arc > Machine provisioning > Get started > View downloads) and the `usb_prep.exe` tool. The same files are published behind a short link per release train:

```text
https://aka.ms/aep/installeros/<YYMM>
```

A **published** train answers `301` with a blob on `*.download.prss.microsoft.com`. An **unpublished** train answers `302` to a search page (`www.bing.com?ref=aka&shorturl=...`); treat that as "not published", not as an error. Results of `HEAD` requests without redirects:

| Train | Result | Download | Size | Last-Modified |
|-------|--------|----------|------|---------------|
| `2610` | 301 | `roe-10.2610.0.3061.zip`, later `roe-10.2610.0.3062.zip` | 1.39 GB | 12 Oct 2026, then 15 Oct 2026 |
| `2607` | 301 | `roe-10.2607.0.3085.zip` | 1.01 GB | 4 Aug 2026 |
| `2604` | 301 | `roe-10.2604.0.3100.zip` | 0.89 GB | 6 Jun 2026 |
| `2602`, `2512` | 301 | `roe-10.2602.20.3005.zip`, `roe-10.2512.20.3092.zip` | | |
| `2510`, `2507` | 301 | `provision-os.iso` directly (older trains ship the ISO itself) | 1.4 GB | |
| `2609`, `2608`, `2606`, `2605`, `2603`, `2601`, `2611`, `2612` and others | 302 to a search page | not published | | |
| `latest` (not a train) | 302 to a search page | there is no `latest` alias | | |

Observations that shaped the design:

- **The train URL moves.** `2610` pointed at build `10.2610.0.3061` in the morning and at `10.2610.0.3062` (modified 15 Oct 2026 14:34 UTC) ninety minutes later. Every build gets its own cache folder and manifest.
- **The maintenance train is not the solution version.** The maintenance ISO is `10.YYMM.x.y`; the solution recipe the machine installs afterwards is `12.YYMM.x.y` from the OS image catalog (`osImages`). A maintenance build one month ahead of the newest published solution release is normal. `-MaxBootstrapTrain 2609` caps the train if you want to stay on the train of a given solution release.
- **There is no `aka.ms/aep/hci/<yymm>` download.** That short link answered with the search-page redirect for the months probed (2608, 2609, 2610); the string appears in recorded jobs only as the `osImageLocation` the service uses itself.
- **What is in the zip** (read with HTTP Range requests on the zip's central directory, no full download): `usb_prep.exe` (2.1 MB), `provision-os.iso` (about 1.34 GB, deflated) and `readme.txt`. The ISO holds the boot loader (`efi/boot/bootx64.efi`, `boot/grub2/grub.cfg` with `search --label CDROM`), `liveos/rootfs.img`, `images/roe.zip` and `prov_config/` (`download/` is staged to `/var/staging/roesetup/download` on the maintenance OS; `pxe/roesetup.json`). The kernel command line logs to `tty0`, `tty1` and `ttyS0,115200n8`, so a serial-over-LAN console shows the setup messages (not used by the scripts).

### How "latest" is decided

`Select-ZtpBootstrapLatest` (pure function, unit tested) never takes the highest string:

1. Only trains that answered 301 to a Microsoft download host count.
2. A train `YYMM` is **general availability** when its month is `01`-`12` **and** it is not later than the current calendar month. A calendar train in the future is never eligible, even if it is published.
3. A month above 12 (for example `2613`) is a **preview** train and counts only with `-IncludePreview`.
4. `-MaxTrain` drops trains above a cap.
5. The highest train wins; a tie is broken by the highest `[version]` build.

The probe goes back 24 months (`-MonthsBack`), one `HEAD` for the short link without redirects and one for the blob. The redirect target must be `https` on `download.prss.microsoft.com` or `download.microsoft.com`; storage and CDN domains (`blob.core.windows.net`, `azureedge.net`) are refused because any tenant can host content there, and the final URL after redirects is checked again.

### Integrity: what is and is not verified

Microsoft publishes **no hash** for this download (the response carries `ETag`, `Content-Length` and `Last-Modified`, no `Content-MD5`). The scripts therefore use trust on first use, recorded in `bootstrap-manifest.json` next to the ISO:

```json
{ "version": "10.2610.0.3061", "url": "https://...download.prss.microsoft.com/.../roe-10.2610.0.3061.zip",
  "sha256": "<zip>", "size": 1389035592, "downloadedUtc": "2026-10-15T14:01:55Z",
  "isoPath": ".../provision-os.iso", "isoSha256": "<iso>", "etag": "0x...", "lastModified": "...", "trust": "TrustOnFirstUse: ..." }
```

| Check | When |
|-------|------|
| Download completes only when the byte count equals the `Content-Length` of the `HEAD`; resume uses a `.partial` file, a `Range` request and `If-Range` bound to the ETag (a changed file restarts, never two builds in one file) | every download |
| The zip opens, has `provision-os.iso`, the extracted size matches the directory, at most 16 GB | every download |
| The ISO carries the ISO 9660 signature `CD001` | every download |
| The SHA256 of the zip equals the manifest of the same build | a second download of the same build; a difference stops the run unless `-RefreshTrust` |
| The SHA256 of the cached ISO equals `isoSha256` | every reuse |
| Each per-node image: GPT, one FAT32 volume labelled `CDROM`, boot loader, `grub.cfg` and `rootfs.img` present (`Test-ZtpMediaImage`) | every media build |

This detects truncation, corruption and a changed publication. It does **not** detect a poisoned first download, a Microsoft-signed-but-bad build, or a swap that preserves the ETag. There is no Authenticode signature on the ISO to check; `usb_prep.exe` is not used by this repo.

The Resolve stage records the ISO's version, URL and SHA256 as its evidence: in the state file (`stages.Resolve.data`) and in its `StageCompleted` event, for example `maintenance ISO 10.2610.0.3061 (GA), SHA256 ..., from <url>`. The handoff doesn't carry them.

## The OEM layer: `config/oem/<oem>.json`

Adding an OEM is adding a file, not code. The file holds the BMC layer only, for the Bootstrap watch: the BMC kind, its log services and the log patterns that signal a boot from the media, completion and a reset. `ZtpOem.Common.ps1` loads it. Dell is complete; Lenovo, HPE and Supermicro carry the layout with empty signal patterns, marked unverified.

```json
{ "oem": "Dell", "publisher": "Dell",
  "bmc": { "kind": "idrac", "logServices": [ { "id": "Lclog", "path": "/redfish/v1/Managers/iDRAC.Embedded.1/LogServices/Lclog/Entries" }, ... ],
           "signals": { "bootedFromMedia": [...], "completion": [...], "reset": [...] }, "signalsStatus": "unverified: ..." } }
```

## No SBE in ZTP

ZTP doesn't find, download, check or stage an OEM Solution Builder Extension (SBE).

- **The OS install discovers its own.** Microsoft's provisioned OS install runs SBE discovery itself: the `ProvisionOs` job has an `SBEDiscoveryDownload` step.
- **The maintenance ISO has no SBE slot.** No Microsoft source says the maintenance environment reads one (`prov_config/download` is staged onto the maintenance OS only), so nothing SBE-related goes on the media.
- **Staging the SBE is OS configuration, and optional.** The toolkit side-loads an SBE only when a person asks for it (`hardware.sbe.delivery` is `winrm_copy` or `node_pull`); never by default. Learn says to install the OEM's drivers and firmware, and to place the SBE in `C:\SBE` on each machine before deployment ([install drivers and firmware](https://learn.microsoft.com/azure/azure-local/deploy/deployment-install-os#install-drivers-and-firmware)). That happens after ZTP, in [azurelocal-toolkit Phase 03: OS Configuration](https://azurelocal.cloud/docs/implementation/04-cluster-deployment/phase-03-os-configuration/), before Validate and Deploy.

A file that still carries SBE settings works. The run ignores them and prints a note: `Note: hardware.sbe ignored: SBE belongs to OS configuration.` (schema 5), `Note: ztp.node_preparation ignored: SBE belongs to OS configuration.` (older layout), or `<key> in <file> ignored: SBE belongs to OS configuration.` for `SbeModel`, `SbeFamily`, `SbeSolutionVersion` or `SbePackagePath` in an orchestrator settings file.

## What is proven and what is not

| Statement | State |
|-----------|-------|
| The short link, redirect, `HEAD`, `Range` and zip-directory results in the tables above | **Verified live** on 15 Oct 2026 with the scripts' own probe |
| `Get-ZtpBootstrapIso.ps1 -Execute` downloads 1.3 GB, extracts, hashes, writes the manifest and reuses it on the next run (builds `3061` and `3062`) | **Verified live** |
| `Invoke-ZtpPrepareMedia.ps1 -Execute` builds a 4 GiB GPT/FAT32 `CDROM` image from the downloaded `10.2610` ISO and the read-back check passes (boot loader, `grub.cfg`, `rootfs.img`) | **Verified live** (no hardware) |
| Booting that image from the iDRAC USB-stick slot | **Proven on Dell AX-760 / iDRAC 7.30** with maintenance image `10.2610.0.3063` |
| Hash of the maintenance ISO from Microsoft | **None published**; trust on first use |
| The whole flow, from the ISO to provisioned, Arc-connected nodes | **Proven on Dell AX-760 / iDRAC 7.30**; see [Design and architecture](architecture.md) |

## Sources

- Microsoft Learn: *Install the operating system and register Azure Local machines by using simplified machine provisioning (preview)*, *Install the maintenance environment ... small form factor*, *Install drivers and firmware* (Azure Local deployment, install the OS).
- `HEAD` and `Range` requests against the short links above, 15 Oct 2026. Anything not in these sources is labelled unverified.
