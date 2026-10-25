# Bergamota web

The website at **https://bergamota.zesmoi.com.br**: a landing page at `/` and the browser flasher at `/flash/`.
Svelte 5 + Vite, served as static assets by a Cloudflare Worker. Everything runs on the visitor's computer:
the site never hosts or receives Apple files (IPSW contents, shared caches, kernelcaches) or Qualcomm firmware.

## The flasher

Chrome or Edge on a desktop computer talks fastboot to the Poco F1 over **WebUSB**
(`src/lib/fastboot.ts`). Two paths:

- **Patch IPSW + flash** (the default): pick Apple's IPSW, patch it into a root image in the browser, flash it.
  The IPSW step checks the file against Renegade's profiles (`src/lib/profiles.ts`: ios26 = iOS 26.6.2 23G90
  for iPhone12,1, ios18 = iOS 18.7.8 22H352 for iPhone11,8). The in-browser patcher is phase 3 (Renegade in
  Rust compiled to WebAssembly); until it lands the Patch step points to `tools/renegade/renegade root` and the
  second path.
- **Flash an image**: an iOS root (`.simg` or `.img`, onto `userdata`), Enxerto's `boot.img` (onto `boot`) or a
  splash (onto `logo`).

Safety, enforced in code and covered by tests:

- Only `userdata`, `boot` and `logo` can be written. `FastbootDevice` refuses every other partition and every
  command except `getvar`, `download`, `flash:<allowed>`, `reboot` and `reboot-bootloader` (no erase, format,
  oem, flashing unlock, set_active...). Modem, persist, bluetooth, dsp and the bootloaders are unreachable.
- The phone must report `product` = `beryllium`; ABL must be unlocked; Bergamota fastboot must have
  `bergamota-flash` = 1.
- The image is validated before anything is sent (sparse chunk table fully checked, boot needs the `ANDROID!`
  header and 1-64 MiB, logo 1-32 MiB, a root at least 64 MiB, and the expanded size must fit
  `partition-size:<p>`), and the user types the partition name to confirm.

Large images are **streamed**: `src/lib/sparse.ts` reads only the sparse chunk table, splits the image into
pieces of at most 512 MiB (the size the Mac app uses for ABL; the phone's `max-download-size` when smaller;
selectable in Advanced), each a complete sparse image with leading/trailing DONT_CARE like libsparse's resparse,
and produces each piece's bytes from `File.slice()` reads in 1 MiB buffers. An 18 GB root costs a few MB of
memory. Raw images larger than a piece become sparse pieces too (last block zero-padded); small images go as is.

Linux needs a udev rule for the fastboot device; Windows needs the WinUSB driver (Google USB driver or Zadig).
The Connect step shows both.

Prior art: [fastboot.js](https://github.com/kdrag0n/fastboot.js) (Danny Lin, MIT) and GrapheneOS's
[web installer](https://github.com/GrapheneOS/grapheneos.org) (MIT). The code here is a fresh implementation.

## Develop

```sh
npm install
npm test          # node --test: sparse splitting round trips, end-to-end flash into a fake phone, allowlist
npm run check     # svelte-check
npm run dev       # Vite on http://localhost:5173 (dev only: window.__session drives the flow with test/helpers.ts FakePhone)
npm run build     # -> dist/
npx wrangler dev  # serve dist/ like production (headers, 404, /flash -> /flash/) on http://localhost:8787
```

`public/_headers` sets the CSP (fonts and images only from this origin, `wasm-unsafe-eval` for the coming
WASM patcher) and `Permissions-Policy: usb=(self)`.

## Deploy

`wrangler.jsonc` binds the Worker to the custom domain `bergamota.zesmoi.com.br` (Cloudflare creates the DNS
record on the first deploy). `npm run deploy` builds and deploys; it needs `wrangler login` on an account that
owns the `zesmoi.com.br` zone.

## Identity

Isaac Newton, after Godfrey Kneller's 1689 portrait (public domain), cut out and printed as a black-and-white
halftone, on a lime halftone ground with the iOS version in giant white numerals tucked behind him.
`DESIGN.md` has the system; `public/img/newton.webp` is the cutout.
