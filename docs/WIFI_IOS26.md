# Wi-Fi on iOS 26.6.2 (xnu-12377, Poco F1 / WCN3990)

Branch `wlan26` (off `ios26`). Patch numbers **1100-1199** in `xnu/patches-12377` are this work's; the iOS 26
port uses 1000-1099. iOS 18 background: `docs/WIFI_BT_IOS18.md` section 3 (the two missing drivers) and
`docs/WIFI_BT_PLAN.md` (the chip sequence). This file re-scopes the iOS half for iOS 26; the chip half is unchanged.

## 1. What iOS 26 expects (reverse-engineered 2026-10-25)

Sources: iPhone12,1 23G90 kernelcache (`ipsw download --kernel`), `/usr/sbin/wifid` and the
LaunchDaemons from the phone, and IO80211 / CoreWiFi / MobileWiFi / WiFiPolicy extracted from the iOS 26
shared cache (`research/ios26/dsc-fix`). Nothing Apple is committed; addresses below are IO80211.framework 1565.3
and wifid in 23G90.

### 1.1 The driver is no longer a kext

The iPhone12,1 kernelcache has **no IO80211Family and no AppleBCMWLAN kext**. Wi-Fi is the DriverKit
extension `/System/Library/DriverExtensions/com.apple.DriverKit-AppleBCMWLAN.dext` (user space), launched over
PCIe (`AppleBCMWLANBusInterfacePCIe` in the kernel only does PCIe power and dext crash recovery). The kernel
side of the data path is IOSkywalkFamily (`IOUserNetworkWLAN`, `AppleBCMWLANSkywalkInterface`), also closed.

For us this means there is **no closed kernel family to imitate any more**. What user space needs is a short,
fully identifiable list of IOKit properties, one BSD interface, two ioctls and one kernel-event class, all
of which xnu-12377 (open source) can provide.

### 1.2 How wifid finds a Wi-Fi device

* launchd starts wifid only if the device tree has a node named `wlan`, `marconi-wifi`, `centauri-alpha` or
  `centauri-alpha-protium` (`com.apple.wifid.plist` `_LimitLoadToDeviceTree`). Real N104 has `/arm-io/wlan`
  (`device_type = 'wlan'`, `local-mac-address`, many `wlan.*` tunables); our N104 ADT has none, so wifid
  never runs (confirmed: no wifid in `ps` on the iOS 26 boot).
* `WiFiManagerScheduleWithQueue` (wifid `sub_100079D04`) registers IOKit notifications on constant
  dictionaries; **no class name is involved**:
  1. `{IOPropertyExistsMatch: "WiFiHardwareHealthy"}`;
  2. `{IOPropertyMatch: {IO80211InterfaceRole: "Infrastructure"}}`. Its callback runs `WiFiDeviceCreate`
     (`sub_10005EF34`), which reads `IOInterfaceName` (falls back to `IOInterfaceNamePrefix` +
     `IOInterfaceUnit`) and needs an IOService-plane parent;
  3. `IOServiceNameMatching("AppleWLANDriver")` matched/terminated: driver-available events;
  4. `IOServiceNameMatching("AppleSunriseHALDevice")`, IOPMPowerSource, IOUSBDevice and IOPort entries
     (optional).
* `wifiFirmwareLoader` only launches on `IONameMatch AppleBCMWLANCoreFirmwareLoader`; we never publish that.

### 1.3 How the IO80211 framework talks to the driver

`Apple80211BindToInterfaceWithService` (IO80211 `0x25d441180`):

1. `IOServiceOpen` on the matched service, then struct method 0 with an `apple80211req`-style buffer
   (`SIOCGA80211` marker `0xc02869c9`, type 43 `DRIVER_VERSION`, 15408 bytes), methods 1
   (`useIOUCWhenPossible`) and 7 (`isDKSupported`). This is the DriverKit user client.
2. **If `IOServiceOpen` fails, it falls back to the ioctl path** ("Falling back to IOCTL path"): the
   interface must be in `_getIfListCopy` (getifaddrs, then `SIOCGIFMEDIA` with `(ifm_current & 0xe0) == 0x80`
   = IFM_IEEE80211, or `SIOCGIFTYPE` with type 6 / subfamily 3 = Ethernet/Wi-Fi). It must also pass
   `_isInfraInterface`: an IOKit service matching `{IOPropertyMatch: {IOInterfaceName: <ifname>}}` with
   `IO80211InterfaceRole = "Infrastructure"`. Then `SIOCGIFFLAGS` and `SIOCGA80211` type 12
   (`CARD_CAPABILITIES`) on a socket must succeed.
3. From then on every get/set is `ioctl(s, SIOCGA80211 / SIOCSA80211, struct apple80211req)` (40 bytes:
   `char ifname[16]; u32 type; u32 val; u32 len; u64 data`), the classic Apple80211 API. In xnu-12377 an unknown
   socket ioctl whose buffer starts with an interface name reaches that interface's `if_ioctl`
   (`bsd/net/if.c` `ifioctl` default case → `pru_control` → `ifnet_ioctl`), so no xnu change is needed
   to receive them.
4. Events: `Apple80211EventMonitoringInit2` tries the user client's async pipe, then falls back to a
   `PF_SYSTEM / SOCK_RAW / SYSPROTO_EVENT` socket with `SIOCSKEVFILT {vendor 1 (Apple), class 6
   (KEV_IEEE80211_CLASS), subclass 1}`. The kernel posts `APPLE80211_M_*` messages with `kev_post_msg`.

The ioctl type numbering is the framework's own name table (578 entries, in type order; e.g. 1 SSID,
10 SCAN_REQ, 11 SCAN_RESULT, 12 CARD_CAPABILITIES, 13 STATE, 19 POWER, 20 ASSOCIATE, 43 DRIVER_VERSION,
86 SCAN_REQ_MULTIPLE). It matches the old public `apple80211_ioctl.h` for the low numbers.

## 2. The smallest path to association

Two halves, as on iOS 18, but the iOS half is now much smaller and **testable without the chip**:

| Half | What | Size |
|------|------|------|
| A. iOS side | in-kernel `sweet80211` stand-in: `en0` (Ethernet, subfamily Wi-Fi), the IOKit entries of 1.2, the ioctl dispatcher of 1.3, kernel events; plus an ADT `/arm-io/wlan` node | days for "Wi-Fi On, empty list"; then grows with each ioctl wifid needs |
| B. Chip side | WCN3990: MSS/MBA boot, QMI WLFW, CE/HTC/WMI/HTT (ath10k-snoc class), host MLME (auth/assoc), WPA2 4-way handshake, 802.3 data path | 3-4 weeks to a scan (WIFI_BT_PLAN.md P3-P5), more to WPA2 traffic |

Half A no longer needs a 4-8 week Apple80211-lite family. The interface between the halves is an internal
backend struct (`power`, `scan`, `join`, `tx`) so A can be built and booted against a null backend now.

Not chosen:
* **Running Apple's dext** (driverkitd + IOUserServer are in xnu): the dext drives a Broadcom PCIe chip
  through IOSkywalkFamily, which we don't have; nothing of it applies to a Qualcomm SNOC chip.
* **Ethernet-only interface first** (IP over Wi-Fi with our own CLI, wifid not running): it skips Control
  Center/Settings entirely, and the ioctl stand-in costs about the same once the chip half exists. It
  remains a debugging aid (`ifconfig en0` + a test tool) during half B.

## 3. Steps

* **W1 (now): null-backend stand-in, patch 1100** `sweet80211=1` (off by default):
  * `en0` via `ifnet_allocate_extended` (IFNET_FAMILY_ETHERNET, IFNET_SUBFAMILY_WIFI), MAC from the ADT
    `wlan` node or a fixed locally-administered address; output drops packets; `SIOCGIFMEDIA` reports
    IFM_IEEE80211.
  * IOKit: controller `AppleWLANDriver` (name) with `WiFiHardwareHealthy`; child interface with
    `IOInterfaceName en0`, `IOInterfaceNamePrefix en`, `IOInterfaceUnit 0`, `BSD Name en0`,
    `IO80211InterfaceRole Infrastructure`. No user client, so IO80211 takes the ioctl path.
  * ioctls: answers CARD_CAPABILITIES, DRIVER_VERSION, HARDWARE_VERSION, POWER get/set, STATE, OP_MODE,
    PHY_MODE, SUPPORTED_CHANNELS, LOCALE, COUNTRY_CODE, SSID/BSSID (not associated), SCAN_REQ (posts SCAN_DONE)
    and SCAN_RESULT (none); every other type returns EOPNOTSUPP and is logged once as
    `SWEET 80211: get/set type N len L` so the first boot lists what wifid really needs.
  * `tools/adt-wlan.py` adds `/arm-io/wlan`, which is what launchd checks.
  * Goal: wifid stays up, Control Center shows Wi-Fi, and switching it on posts POWER and a scan with no
    networks. The phone boot needs the iOS 26 session (it owns the phone and the flashes).
* **W2:** iterate on the logged ioctls until Settings › Wi-Fi shows "On" and scans.
* **W3:** a fake backend (`sweet80211=2`) that returns one synthetic BSS in SCAN_RESULT, to fix the
  scan-result struct layout and Settings' list before any radio exists.
* **W4+ (half B):** WIFI_BT_PLAN.md P0-P5 forward-ported to xnu-12377: read-only probes, then the gated MSS
  boot (user present, first TZ-mediated step), QMI WLFW, WMI scan → feeds SCAN_RESULT. Then MLME + WPA2 +
  data path → ASSOCIATE.

Rules for every step: never write modem/persist/bluetooth/dsp; firmware stays out of git; flashes only
through the Bergamota queue, and only with the user's OK.

## 4. Log

* 2026-10-25: re-scope (this file). Kernelcache/dext finding, wifid matching dictionaries, IO80211 ioctl
  fallback and event socket confirmed by disassembly. No phone changes.
* 2026-10-25: **W1 written, not booted.** `xnu/patches-12377/1100-sweet-80211-wifi-standin.patch`:
  `bsd/dev/sweet_80211.c` (en0, ioctl dispatcher, kernel events, null backend; started from
  `sweet_ufs.c` next to `beryllium_wlan_init`), `IO80211Controller` / `IO80211Interface` and
  `sweet_net_publish_wlan()` in `iokit/Kernel/arm/SweetNetwork.cpp` (after 0110). Compile-checked with
  `tools/xnu-cc.py` against the iOS 26 CI log (objects link only against existing kernel exports);
  the full 12377 series + 1100 applies to pristine xnu-12377.121.6 and gives the checked files byte for
  byte. `tools/adt-wlan.py` adds `/arm-io/wlan` (tested on `enxerto/out/beryllium-n104-2x.adt`:
  phandle 24, MAC 02:00:5e:77:e0:01 from `/chosen mac-address-wifi0`).
  * To test: kernel with 1100 + ADT from `adt-wlan.py` + boot-arg `sweet80211=1`. Expect the console lines
    `SWEET 80211: en0 ... up` and `IOKit interface en0 published`, wifid running, then one
    `SWEET 80211: get/set type N` line per ioctl type wifid uses; `SWEET NET: wifid opened
    IO80211Controller user client: 0x...` shows the IOServiceOpen refusal that selects the ioctl path.
  * CI run 40191362682 (wlan26 012ed29 = ios26 fb82624 + 1100): success, kernel sha256 `31e6c9c3...`;
    **superseded, do not boot**: it carries the old 1013 (touch events in a layout iOS 26 doesn't read).
    wlan26 is merged into ios26 (bd41a75); the iOS 26 session builds boot 23 from the ios26 tip with 1100,
    `enxerto/out/beryllium-n104-2x-wlan.adt` and `sweet80211=1`.
  * Side effect of the ADT node alone (without 1100): wifid starts and waits for a device; harmless.
* 2026-10-25: **boot 23 (iOS 26 session, ios26 tip with 1100, `beryllium-n104-2x-wlan.adt`, `sweet80211=1`):
  wifid starts and stays up (pid 47) and binds to en0 over the ioctl path.** `IOServiceOpen` on
  IO80211Interface (type 0) and IO80211Controller (type 1) returns 0xe00002c7 (unsupported) for wifid and
  configd as intended. wifid reads CARD_CAPABILITIES and POWER, then sets POWER on ("radio on", event 1
  posted). 37 types in all, no SCAN_REQ yet (nothing asked for a scan; Settings › Wi-Fi was not opened).
  Sizes wifid uses (len 0 = value in req_val):

  | dir | type | name | len | 1100 answer |
  |-----|------|------|-----|-------------|
  | get | 12 | CARD_CAPABILITIES | 21 | 0 (version + 17 zero capability bytes) |
  | get/set | 19 | POWER | 24 | 0 |
  | get | 13 / 14 / 15 | STATE / PHY_MODE / OP_MODE | 8 / 12 / 0 | 0 |
  | get | 51 | COUNTRY_CODE | **3** | 0, but 1100 sent a versioned struct: wifid read `01 00 00` |
  | get | 1 / 9 / 4 / 8 / 16 / 17 | SSID / BSSID / CHANNEL / RATE / RSSI / NOISE | 32 / 6 / 16 / 0 / 52 / 52 | ENXIO (not associated) |
  | get | 2, 5, 57, 70, 96, 97, 103, 106, 115, 207, 254, 423 | AUTH_TYPE, POWERSAVE, MCS, WOW_ENABLED, VIRTUAL_IF_ROLE/PARENT, CURRENT_NETWORK, RSSI_BOUNDS, AWDL_SYNC_PARAMS, AWDL_AF_TX_MODE, BTCOEX_PROFILE, WCL_LEAVE_NETWORK | various | EOPNOTSUPP (102) |
  | set | 25, 469, 473, 481, 483, 485, 490, 512, 564, 572, 575, 582 | HOST_AP_MODE, BATTERY_POWERSAVE_CONFIG, WCL_CONFIG_BGSCAN, APP_REPORT, BYPASS_TX_POWER_CAP, FACETIME_WIFICALLING_PARAMS, WCL_LIMITED_AGGREGATION, SYSTEM_STATE, ACCESSORY_STATE, NAN_CCA, NB_RANGING_SESSION, (582) | various | EOPNOTSUPP (102) |

  Also `ioctl 0xc0206944 not handled` = SIOCGIFDEVMTU.
* 2026-10-25: **1101** (`1101-sweet-80211-boot23-fixes.patch`, compile-checked, not booted): COUNTRY_CODE as
  bare char[3] (get and set), SIOCGIFDEVMTU (1500), unknown *set* types accepted and ignored (still logged
  once). Unknown gets stay EOPNOTSUPP. Next test: open Settings › Wi-Fi and look for SCAN_REQ (10) or
  SCAN_REQ_MULTIPLE (86), `event 10`, and what the screen shows.
* 2026-10-25: **1102** (W3, compile-checked, not booted): `sweet80211=2` returns one synthetic open network,
  "Bergamota-test" (BSSID 02:00:5e:77:e0:aa, channel 6, RSSI -52), per scan. Layout from IO80211
  `Apple80211Scan` / `_addScanResultToList`: SCAN_REQ is a 5528-byte set; after the SCAN_DONE event the
  framework gets type 11 into a 2272-byte buffer until the get fails with EIO (or 0xe0820446). One result is
  the classic `apple80211_scan_result`: version @0, channel {version, number, flags} @4, unk/noise/snr/rssi
  int16 @16-22, beacon interval @24, capability @26 (bit 0 ESS, 0x10 privacy), BSSID @28, rate count @34,
  rates u32[15] (Mb/s) @36, SSID length @96, SSID @97, age @132, flags @136, IE length @138, IEs @140
  (2048), u64 @2256. A privacy bit makes the framework parse WPA/RSN IEs; the fake network is open.
  Joining it fails (ASSOCIATE -> ENXIO). With `sweet80211=1` nothing changes.
* 2026-10-25: boot 24/25 (`sweet80211=2`, 1101 + 1102): wifid up, optional sets now accepted (new: 470, 482,
  560), COUNTRY_CODE fine. Still no SCAN_REQ: touch does not work yet, so nobody can open Settings ›
  Wi-Fi. Added `tools/sweetnet/sweetwifi.c` (`sweetwifi info | power on|off | scan`; built by
  `tools/sweetnet/build.sh` into `research/sweetnet/ios18/`, arm64e + pacstrip, runs on iOS 26). It calls the
  framework's own Apple80211Open/BindToInterface/Scan over SSH, which tests the scan path (kernel stand-in
  plus IO80211's result parser) without wifid or the UI.
* 2026-10-25: **paused** by the user (focus on touch). Next step when resumed: `sweetwifi info` / `scan` on a `sweet80211=2` boot.
* 2026-10-25: **resumed** (user). Touch works on iOS 26 (boot 27, tag ios26-touch-works); the iOS 26 session runs `sweetwifi` steps 1-4 and opens Settings › Wi-Fi on boot 28 (`sweet80211=2`).
* 2026-10-25: **boot 27 (ios26 with 1100-1102, `sweet80211=2`): the scan path works end to end.**
  `sweetwifi info`: bind en0 0, power 1, COUNTRY_CODE "BR", STATE 0, OP_MODE 1 (STA), SSID/BSSID -3903 (not
  associated). `sweetwifi scan`: `Apple80211Scan -> 0`, one result, parsed by IO80211 into SSID_STR
  "Bergamota-test", BSSID 2:0:5e:77:e0:aa, CHANNEL 6, CHANNEL_FLAGS 138, CHANNEL_WIDTH 20, PHY_MODE 8 (11g), RSSI
  -52, NOISE -92, SNR 40, RATES 1..54, CAPABILITIES 1, AP_MODE 2, IE (29 bytes). Kernel log: set type 10 (len
  5528), event 10, get type 11 (len 2272) -> result then EIO; a second event 10 shows that another client
  (wifid) also scanned. New set type 571 (len 8) accepted. Still open: what Settings › Wi-Fi shows (asked).
* 2026-10-25: **Settings › Wi-Fi showed "No networks" (boot 28, user)**. The iOS 26 session's log stream of wifid and
  Preferences shows why: on opening the page, Settings asks wifid for the hardware channel list (CoreWiFi
  "GET HW SUPP CHANNELS", `queryHardwareSupportedChannelsWithRequestParams`). wifid sends ioctl type **254**, named
  `APPLE80211_IOC_HW_SUPPORTED_CHANNELS` by IO80211 itself (len 4824). 1100 refused it, so Settings logged "device
  scan channels are nil" and "scanning did finish ... results=0" without ever requesting a scan.
  **1103** (compile-checked, not booted) answers 254 with the SUPPORTED_CHANNELS list. The IO80211 parser
  (CopyValue, 0x25d42b428) reads `{u32 version; u32 count @4; {version, channel @12, flags @16} x count}`,
  12-byte stride, into SUP_CHANNEL / SUP_CHANNEL_FLAGS.
  **Correction: type numbers.** The names in the boot 23 table came from string order. The framework's real
  index table (`gAppleIoucIndexToString`, 587 entries, `convertApple80211IOCTLToString`) has empty slots at 0,
  114 and 353 (CARD_SPECIFIC is -1). Names are right for 1-113 (everything the stand-in implements), one off
  for 114-352 (e.g. 254 = HW_SUPPORTED_CHANNELS, not BTCOEX_PROFILE) and two off from 353 up.
* 2026-10-25: **MILESTONE, boot 29 (ios26 2ba2989 with 1100-1103, `sweet80211=2`): Settings › Wi-Fi lists
  "Bergamota-test" (user-confirmed).** The iOS half (W1-W3) is complete: wifid, CoreWiFi and Settings accept the
  in-kernel stand-in, power the radio, scan and show results. What remains is the chip half (W4+): a real WCN3990
  backend behind `s8_get/s8_set` (power, scan results from WMI, then join/WPA2/data). Joining the synthetic
  network fails by design (ASSOCIATE -> ENXIO).

## 5. Chip half (W4+): read-only probes first

Started 2026-10-25 (user: "start the chip half with the read-only sweetwlan probes on xnu-12377").
`bsd/dev/beryllium_wlan.c` (0104 and the BT patches, forward-ported in patches-12377) already carries P0 and P1 of
`docs/WIFI_BT_PLAN.md` unchanged:

* `sweetwlan=1`: GCC clock branches (SE and MSS), S6 DFS table, TLMM gpio45-48, SE6 protocol/FIFO (only when its
  clocks are on), cmd-db addresses of the WCN3990 rails, SMEM table + apps<->modem items, TCSR mutex, apps SMMU
  SMR/S2CR for stream 0x40 / 0x740. RMB (0x4180000) and QDSP6 (0x4080000) are deliberately not read.
* `sweetwlan=3`: the stage-1 probe, then a read-only inventory: sizes and first bytes of modemst1/2, fsg, fsc,
  persist, dsp; FAT16 walk of `modem` (mba.mbn, wlanmdsp.mbn, qdsp6m.qdb, bdwlan.*, bdf_*, modem.mdt segment
  table vs the MPSS carve-out 0x8e400000..0x95c00000, MBA vs 0x96900000 + 2 MiB) and of `bluetooth`.

Reviewed for iOS 26: no writes, no SCM call, no MSS reset. Stage 3's partition reads take `sweet_ufs_lock` (the
root's own I/O lock), issue READ(10) only and restore the root LUN afterwards. **One boot with
`sweetwlan=3 sweetwlandelay=30` covers P0 and P1**; it can keep `sweet80211=2`. Output: `SWEET WLAN:` lines in the
console log / sweetlog. Stage 2 (Bluetooth power-up) is the only stage that writes registers and is not part of
this step.

What the output decides: whether MSS clocks/GDSC and the SMMU stream for WLAN (0x40) are left set up by the
bootloader (they were not on iOS 16: "WLAN sid 0x40 unmapped"), whether SMEM has the modem items, and whether the
phone's own `modem` partition holds an MBA/MPSS pair that fits the carve-outs. That fixes the inputs of P3
(MBA load, the first TZ-mediated step, run only with the user present).

### 5.1 Boot 30: `sweetwlan=3` result (2026-10-25, 74 lines, no crash)

| Area | Observed | Meaning for P3+ |
|------|----------|-----------------|
| MSS clocks | `mss cfg_ahb` on, `mss mfab_axis` on, `q6_memnoc_axi` and `snoc_axi` **off**; GPLL0 div vote bit17 set | modem is cold (expected: Linux q6v5-mss turns the AXI branches on itself) |
| SE6 (BT UART) | clocks gated, registers not read; TLMM gpio45-48 at func 0 | as on iOS 16; only stage 2 configures them |
| Rails | cmd-db: smpa4 0x40600, ldoa5 0x40f00, ldoa7 0x41300, ldoa17 0x40c00, ldoa23 0x41e00, ldoa25 0x42000 | RPMh addresses for the WCN3990 votes resolve |
| SMEM | `$TOC` v1, 15 entries; seen: global, 0<->5, 2<->3, 7<->8, 1<->8 | **incomplete: probe bug**, see below |
| apps SMMU | 76 SMRs / 45 CBs; **sid 0x40 (WLAN) has no SMR**; 0x740 -> SMR6, CB3 | we must map WLAN's stream ourselves (bypass or our own context bank) before the CE rings |
| EFS | modemst1, modemst2 (LUN 5) and fsg (LUN 4) 8 MiB each, non-zero; fsc, persist, dsp start with zeros | rmtfs can serve the real EFS (reads; writes dropped by rule) |
| `modem` FAT16 | `image/mba.mbn` 238304 B (fits the 2 MiB carve-out at 0x96900000); `modem.mdt` 30 phdrs, 28 loadable segments spanning **exactly** 0x8e400000..0x95c00000 (120 MiB carve-out), relocatable, hash segment 7400 B; `wlanmdsp.mbn` 3645892 B; `qdsp6m.qdb`; 29 `bdwlan.*`, 5 `bdf_*` | the phone's own MBA/MPSS fit the Linux beryllium carve-outs; WLAN firmware and board data are present (the modem fetches wlanmdsp.mbn through the QRTR TFTP service we host) |
| `bluetooth` FAT16 | crbtfw21.tlv **222988 B**, crnv21.bin 4591 B (+ the 2.0/1.1 variants) | the phone ships a newer BT rampatch than linux-firmware's 177060 B one we install; worth trying for BT later |

**Probe bug, fixed in 1104** (compile-checked): `wl_dump_smem` stepped the partition table by 32 bytes, but Linux
`struct smem_ptable_entry` is 48 bytes, so it read only real entries 0, 2, 4, 6 and 8 (printed as 0, 3, 6, 9, 12)
and skipped every odd one, which is where apps<->modem (hosts 0<->1) normally is. It also read
`offset_free_uncached` of a partition header at +16 instead of +12. "No apps<->modem partition" is therefore NOT
a finding yet. Next probe boot (same `sweetwlan=3`) with 1104 lists all 15 entries and the apps<->modem items.

Next after that: write P2/P3 for xnu-12377: the MSS power/clock/reset sequence (q6v5-mss sdm845: AOSS/PDC reset,
halt registers, the AXI branches above), the MBA load into 0x96900000 and the RMB handshake, as one gated patch
that stops at "MBA alive" and is run only with the user present (the first TZ-mediated step).

### 5.2 P3: MSS power-up and MBA boot (patches 1105 + 1106, compile-checked, NOT run)

Written 2026-10-25 against Linux v6.6 `qcom_q6v5_mss.c` (`sdm845_mss`: has_alt_reset, need_mem_protection, proxy
power domains cx/mx/mss, proxy clocks xo/prng, reset clocks iface/snoc_axi, active clocks bus/mem/gpll0_mss/mnoc_axi)
and `qcom_q6v5.c` (`qcom,qmp` load_state). Stage `sweetwlan=4` runs only when **`sweetmss=1`** is set as well:

1. `mba.mbn` (the phone's own, 238304 bytes) from the `modem` FAT16 partition (read-only).
2. AOSS QMP (0xc300000; doorbell apss_shared 0x17990000 +12 bit 0): link/channel handshake, then
   `{class: image, res: load_state, name: modem, val: on}`.
3. RPMh ARC votes cx.lvl, mx.lvl, mss.lvl at their highest level (1105: `sweet_rpmh_arc_vote`, active set, allow-list
   of those three; the VRM path for the BT rails is unchanged).
4. Checks that cfg_ahb, prng, boot_rom and mfab_axis are on (boot 30: they are); enables snoc_axi (BRANCH_HALT, polled).
5. Alt reset deassert: PDC modem sync reset (0xb2e0100 bit 9) asserted, `RMB_MBA_ALT_RESET`=1, AOSS MSS restart pulse
   (0xc2b0000 1 -> 0, 300 us each), `RMB_MBA_ALT_RESET`=0, PDC released. Then q6_memnoc_axi (BRANCH_VOTED, not polled).
6. MBA copied into its carve-out 0x96900000 (write-combined mapping) while the kernel still owns it, then two SCM
   hyp-assigns, HLOS -> MSS_MSA (RW): MPSS 0x8e400000+0x7800000, MBA 0x96900000+0x200000
   (SMC 0x42000c16, arginfo 0x1117, args 3..6 in an indirect buffer).
7. `RMB_MBA_IMAGE` = MBA address; QDSP6SS sleep clock on, `BOOT_CORE_START`=1, `BOOT_CMD`=1, wait `RMB_MBA_MSS_STATUS`
   bit 0 (10 ms), `RMB_PBL_STATUS` (1 s, 1 = success), `RMB_MBA_STATUS` (5 s, 1/2 = XPU unlocked = **"MBA ALIVE"**).
8. Teardown (always, unless `sweetmsskeep=1` and alive), in `q6v5_mba_reclaim` order: halt the q6/modem/nc AXI ports
   (TCSR 0x1f63000/0x1f65000/0x1f64000), alt reset assert, clocks off, hyp-assign both carve-outs back to HLOS (RWX),
   ARC votes to level 0, QMP load_state off. A carve-out that could not be reclaimed is reported and never touched.

Log lines: `SWEET MSS:` (+ `SWEET RPMH:` for the votes). Expected outcomes, in order of increasing progress: QMP not
acked; an ARC lookup/vote failure; an SCM hyp-assign error (TZ/hypervisor policy); boot FSM timeout; PBL status
other than 1; MBA status 0 (MBA did not start); `MBA ALIVE`.

Hazards (WIFI_BT_PLAN.md section 5, P3 = high): the first TZ/hypervisor-mediated action; the QHEE hypervisor may
treat an unexpected request or an SMMU fault as fatal and reset the SoC. A reset is recoverable (the phone reboots
to fastboot / Android bootloader as usual); nothing is written to storage. Run it **only with the user present**,
with `sweetwlandelay` long enough for the persistent log to be up, and read the log before any second attempt.
