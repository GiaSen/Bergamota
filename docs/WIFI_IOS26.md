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
    copies in `research/ios26/wlan1100/` (kernel + `beryllium-n104-2x-wlan.adt`, not in git). Not booted.
  * Side effect of the ADT node alone (without 1100): wifid starts and waits for a device; harmless.
