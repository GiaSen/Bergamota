// The flasher's state: which path (patch an IPSW, or flash an image), the phone, the chosen image and the
// flash itself. One instance per page.

import { ALLOWED_PARTITIONS, FastbootDevice, FastbootError, type LogKind, type Partition } from "../lib/fastboot.ts";
import { checkImage, flash, identify, phoneProblems, SAFE_PIECE, type Checked, type PhoneInfo, type Progress } from "../lib/flasher.ts";
import { blobSource, type ByteSource } from "../lib/sparse.ts";

export type Path = "patch" | "image";
export const STEPS: Record<Path, string[]> = {
  patch: ["IPSW", "Patch", "Connect", "Confirm", "Flash"],
  image: ["Connect", "Choose", "Confirm", "Flash"],
};

export interface LogLine {
  kind: LogKind;
  text: string;
  at: number;
}

export interface Picked {
  name: string;
  size: number;
  from: "file" | "browser";
  src: ByteSource;
}

class Session {
  path = $state<Path>(location.hash === "#image" ? "image" : "patch");
  step = $state(0);
  advanced = $state(false);

  fb = $state.raw<FastbootDevice | null>(null);
  phone = $state.raw<PhoneInfo | null>(null);
  phoneProblems = $state.raw<string[]>([]);
  connecting = $state(false);
  connectError = $state<string | null>(null);

  ipsw = $state.raw<File | null>(null);

  partition = $state<Partition>("userdata");
  picked = $state.raw<Picked | null>(null);
  checked = $state.raw<Checked | null>(null);
  checking = $state(false);
  checkError = $state<string | null>(null);

  pieceCap = $state(SAFE_PIECE);
  rebootWhenDone = $state(true);
  flashState = $state<"idle" | "flashing" | "done" | "stopped" | "error">("idle");
  flashError = $state<string | null>(null);
  progress = $state.raw<Progress | null>(null);
  stopRequested = $state(false);
  rebooted = $state(false);

  log = $state<LogLine[]>([]);

  get steps() {
    return STEPS[this.path];
  }
  get stepName() {
    return this.steps[this.step];
  }

  setPath(p: Path) {
    if (this.flashState === "flashing") return;
    this.path = p;
    history.replaceState(null, "", p === "image" ? "#image" : location.pathname);
    // keep the phone; restart the flow at the first step that is not done
    this.step = p === "image" ? (this.phone && !this.phoneProblems.length ? 1 : 0) : this.ipsw ? 1 : 0;
  }

  go(name: string) {
    const i = this.steps.indexOf(name);
    if (i >= 0) this.step = i;
  }

  addLog(kind: LogKind, text: string) {
    this.log.push({ kind, text, at: Date.now() });
    if (this.log.length > 500) this.log.splice(0, this.log.length - 500);
  }

  async connect(dev?: USBDevice) {
    if (this.connecting || this.flashState === "flashing") return;
    this.connecting = true;
    this.connectError = null;
    try {
      if (this.fb) await this.fb.close();
      const fb = dev ? await FastbootDevice.open(dev) : await FastbootDevice.request();
      fb.log = (k, t) => this.addLog(k, t);
      this.addLog("note", `opened ${fb.usb.productName ?? "fastboot device"} (${hex(fb.usb.vendorId)}:${hex(fb.usb.productId)})`);
      const phone = await identify(fb);
      this.fb = fb;
      this.phone = phone;
      this.phoneProblems = phoneProblems(phone);
      if (this.picked) await this.recheck();
    } catch (e) {
      const err = e as Error;
      // closing the picker is not an error
      if (err.name !== "NotFoundError") this.connectError = explainUsb(err);
    } finally {
      this.connecting = false;
    }
  }

  disconnected(dev: USBDevice) {
    if (this.fb?.usb !== dev) return;
    this.addLog("note", "the phone was disconnected");
    this.fb = null;
    if (this.flashState === "flashing") {
      this.flashState = "error";
      this.flashError = "The phone disconnected during the flash. Plug it back in (it stays in fastboot) and flash again: the image is written from the start.";
    }
    if (this.flashState !== "done") this.phone = null;
  }

  async pick(file: File | Blob, name: string, from: Picked["from"]) {
    this.picked = { name, size: file.size, from, src: blobSource(file) };
    await this.recheck();
  }

  async recheck() {
    if (!this.picked) return;
    this.checking = true;
    this.checkError = null;
    this.checked = null;
    try {
      this.checked = await checkImage(this.picked.src, this.picked.name, this.partition, this.phone, this.pieceCap);
    } catch (e) {
      this.checkError = (e as Error).message;
    } finally {
      this.checking = false;
    }
  }

  async setPartition(p: Partition) {
    if (!(ALLOWED_PARTITIONS as readonly string[]).includes(p)) return;
    this.partition = p;
    await this.recheck();
  }

  async startFlash() {
    const { fb, picked, checked } = this;
    if (!fb || !picked || !checked || checked.problems.length || this.phoneProblems.length) return;
    this.flashState = "flashing";
    this.flashError = null;
    this.stopRequested = false;
    this.rebooted = false;
    this.progress = null;
    this.go("Flash");
    let lock: WakeLockSentinel | null = null;
    try {
      lock = await navigator.wakeLock?.request("screen");
    } catch {
      /* not allowed: fine */
    }
    try {
      const ok = await flash({
        fb,
        src: picked.src,
        partition: this.partition,
        checked,
        onProgress: (p) => (this.progress = p),
        shouldStop: () => this.stopRequested,
      });
      this.flashState = ok ? "done" : "stopped";
      if (ok && this.rebootWhenDone) {
        await fb.reboot();
        this.rebooted = true;
      }
    } catch (e) {
      this.flashState = "error";
      this.flashError = e instanceof FastbootError ? e.message : explainUsb(e as Error);
    } finally {
      await lock?.release().catch(() => {});
    }
  }

  async reboot() {
    if (!this.fb) return;
    try {
      await this.fb.reboot();
      this.rebooted = true;
    } catch (e) {
      this.flashError = (e as Error).message;
    }
  }

  resetFlash() {
    this.flashState = "idle";
    this.flashError = null;
    this.progress = null;
    this.go("Confirm");
  }
}

function hex(n: number) {
  return (n ?? 0).toString(16).padStart(4, "0");
}

function explainUsb(e: Error): string {
  const m = e.message || String(e);
  if (e.name === "SecurityError") return "The browser blocked USB access. WebUSB needs Chrome or Edge, on https or localhost, and it is off in some managed browsers.";
  if (e.name === "NetworkError" || /Unable to claim|claim interface|Access denied/i.test(m))
    return "The phone is busy or the browser has no permission. Close fastboot/adb and the Bergamota app, then replug. On Linux add the udev rule below; on Windows the device needs the WinUSB driver.";
  return m;
}

export const session = new Session();

if (FastbootDevice.supported()) {
  navigator.usb.addEventListener("connect", (e) => {
    // a phone this site was already allowed to use came back (fastboot detected automatically)
    if (!session.fb) FastbootDevice.known().then((d) => { if (d.includes(e.device)) session.connect(e.device); });
  });
  navigator.usb.addEventListener("disconnect", (e) => session.disconnected(e.device));
  FastbootDevice.known().then((d) => { if (d[0]) session.connect(d[0]); });
}

window.addEventListener("beforeunload", (e) => {
  if (session.flashState === "flashing") e.preventDefault();
});

// dev server only: lets the browser drive the flow against test/helpers.ts's FakePhone (stripped from builds)
if (import.meta.env.DEV) (window as unknown as { __session: Session }).__session = session;
