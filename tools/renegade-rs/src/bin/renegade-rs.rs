//! renegade-rs: the Rust port of Renegade's stages, one subcommand per Python tool, same arguments and
//! same output where the tests compare them.
//!
//!   renegade-rs img2simg RAW.img OUT.simg [--block 4096]
//!   renegade-rs simg2img IN.simg OUT.img
//!   renegade-rs hfs SIMG ls PATH | cat PATH | get PATH OUT | getdir PATH OUTDIR | stat PATH | find SUBSTR | dsc OUTDIR
//!   renegade-rs strip [-v] [--scan] [--dylinker PATH] [--subtype arm64] [-o OUT] IN...
//!   renegade-rs fixupcheck ROOT_DIR | IMAGE.simg [--prefix /System/Library] [--quiet]

use renegade::fixups::{check_bytes, looks_like_macho};
use renegade::hfs::{Entry, Volume, FILE, FOLDER};
use renegade::io::{FileAt, ReadAt};
use renegade::pacstrip::{strip, Options, Report};
use renegade::sparse::{img2simg, simg2img, Sparse};
use std::collections::BTreeMap;
use std::fs::{self, File};
use std::io::{self, BufWriter, Write};
use std::os::unix::fs::{symlink, PermissionsExt};
use std::path::Path;
use std::process::ExitCode;

type Res<T> = Result<T, Box<dyn std::error::Error>>;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let r = match args.first().map(String::as_str) {
        Some("img2simg") => cmd_img2simg(&args[1..]),
        Some("simg2img") => cmd_simg2img(&args[1..]),
        Some("hfs") => cmd_hfs(&args[1..]),
        Some("strip") => cmd_strip(&args[1..]),
        Some("fixupcheck") => cmd_fixupcheck(&args[1..]),
        Some("owners") => cmd_owners(&args[1..]),
        Some("trim") => cmd_trim(&args[1..]),
        Some("mkhfs") => cmd_mkhfs(&args[1..]),
        Some("rebuild") => cmd_rebuild(&args[1..]),
        Some("root") => cmd_root(&args[1..]),
        Some("plist") => cmd_plist(&args[1..]),
        Some("tweaks") => cmd_tweaks(&args[1..]),
        Some("sign") => cmd_sign(&args[1..]),
        Some("resign-check") => cmd_resign_check(&args[1..]),
        _ => {
            eprintln!("{}", USAGE);
            return ExitCode::from(2);
        }
    };
    match r {
        Ok(code) => code,
        Err(e) => {
            eprintln!("renegade-rs: {e}");
            ExitCode::FAILURE
        }
    }
}

const USAGE: &str = "usage: renegade-rs img2simg RAW OUT [--block N] | simg2img IN OUT | hfs SIMG CMD ARGS | strip [opts] IN... | fixupcheck SRC [--prefix P] [--quiet] | owners IMAGE [--map MAP] [--default-root] | trim IMAGE";

/// "64m", "20g", "4096".
fn parse_size(s: &str) -> Res<u64> {
    let (n, mul) = match s.chars().last() {
        Some('k' | 'K') => (&s[..s.len() - 1], 1u64 << 10),
        Some('m' | 'M') => (&s[..s.len() - 1], 1 << 20),
        Some('g' | 'G') => (&s[..s.len() - 1], 1 << 30),
        _ => (s, 1),
    };
    Ok(n.parse::<u64>()? * mul)
}

fn cmd_mkhfs(args: &[String]) -> Res<ExitCode> {
    let (pos, opts, flags) = split(args, &["--size", "--name", "--map", "--date"]);
    let [src, out] = &pos[..] else { return Err("mkhfs SRC_DIR OUT.img [--size 20g] [--name iOSRoot] [--map owners.tsv] [--default-root] [--date UNIX]".into()) };
    let (mut entries, paths, skipped) = renegade::tree::scan_dir(Path::new(src))?;
    for s in &skipped {
        eprintln!("skipped (not a file, folder or symlink): {s}");
    }
    let map = match opts.get("--map") {
        Some(m) => renegade::hfsedit::parse_map(&fs::read_to_string(m)?)?,
        None => Default::default(),
    };
    let default_root = flags.iter().any(|f| f == "--default-root");
    if opts.contains_key("--map") || default_root {
        renegade::tree::apply_map(&mut entries, &map, default_root);
    }
    let o = renegade::hfswrite::Options {
        volume_name: opts.get("--name").cloned().unwrap_or("iOSRoot".into()),
        block_size: 4096,
        size: opts.get("--size").map(|s| parse_size(s)).transpose()?,
        date: opts.get("--date").map(|d| d.parse()).transpose()?.unwrap_or(0),
    };
    let f = File::create(out)?;
    let mut w = renegade::io::FileRw::open(out)?;
    drop(f);
    let mut buf = vec![0u8; 1 << 20];
    let st = renegade::hfswrite::build(&entries, &o, &mut w, &mut |source, sink| {
        let mut r = File::open(&paths[source])?;
        loop {
            let n = io::Read::read(&mut r, &mut buf)?;
            if n == 0 {
                return Ok(());
            }
            sink(&buf[..n])?;
        }
    })?;
    eprintln!(
        "{out}: {} folders, {} files ({} hard links to {} iNodes), {} of {} blocks free, {} catalog nodes",
        st.folders, st.files, st.hard_links, st.inodes, st.free_blocks, st.total_blocks, st.catalog_nodes
    );
    Ok(ExitCode::SUCCESS)
}

/// Rebuilds the tree under PREFIX of an existing root image as a new volume with the Rust writer.
fn cmd_rebuild(args: &[String]) -> Res<ExitCode> {
    let (pos, opts, _) = split(args, &["--prefix", "--size", "--name", "--date"]);
    let [src, out] = &pos[..] else { return Err("rebuild SRC.simg OUT.img [--prefix /usr] [--size N] [--name V] [--date UNIX]".into()) };
    let v = Volume::open(Sparse::open(FileAt::open(src)?)?)?;
    let entries = renegade::tree::from_volume(&v, opts.get("--prefix").map(String::as_str).unwrap_or("/"))?;
    // CNID -> catalog record of every file, to read its data
    let mut rec_of = std::collections::HashMap::new();
    let mut todo = vec![2u32];
    while let Some(c) = todo.pop() {
        for (_, e) in v.children(c) {
            if e.rt == FOLDER {
                todo.push(e.cnid);
            } else if let Some(d) = e.rec {
                rec_of.insert(e.cnid, d);
            }
        }
    }
    let o = renegade::hfswrite::Options {
        volume_name: opts.get("--name").cloned().unwrap_or("iOSRoot".into()),
        block_size: 4096,
        size: opts.get("--size").map(|s| parse_size(s)).transpose()?,
        date: opts.get("--date").map(|d| d.parse()).transpose()?.unwrap_or(0),
    };
    File::create(out)?;
    let mut w = renegade::io::FileRw::open(out)?;
    let mut buf = vec![0u8; 1 << 20];
    let st = renegade::hfswrite::build(&entries, &o, &mut w, &mut |cnid, sink| {
        let d = *rec_of.get(&(cnid as u32)).ok_or_else(|| io::Error::other(format!("no record for CNID {cnid}")))?;
        let f = v.file_at(cnid as u32, d);
        let mut off = 0;
        while off < f.size() {
            let k = (f.size() - off).min(buf.len() as u64) as usize;
            f.read_at(off, &mut buf[..k])?;
            sink(&buf[..k])?;
            off += k as u64;
        }
        Ok(())
    })?;
    eprintln!(
        "{out}: {} folders, {} files ({} hard links to {} iNodes), {} of {} blocks free, {} catalog nodes",
        st.folders, st.files, st.hard_links, st.inodes, st.free_blocks, st.total_blocks, st.catalog_nodes
    );
    Ok(ExitCode::SUCCESS)
}

/// img2simg that deallocates every 16 MiB of the raw image right after converting it (img2simg.py --consume):
/// the raw image and the .simg never need the disk twice. The raw image is gone afterwards.
fn img2simg_consume(raw: &Path, out: &Path) -> Res<renegade::sparse::Img2SimgStats> {
    struct Consume {
        f: File,
        pos: u64,
        punched: u64,
    }
    impl io::Read for Consume {
        fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
            // punch everything before the current position once 16 MiB have been read past the last punch
            if self.pos - self.punched >= renegade::sparse::PIECE as u64 {
                punch_hole(&self.f, self.punched, self.pos - self.punched)?;
                self.punched = self.pos;
            }
            let n = std::os::unix::fs::FileExt::read_at(&self.f, buf, self.pos)?;
            self.pos += n as u64;
            Ok(n)
        }
    }
    let size = fs::metadata(raw)?.len();
    let f = fs::OpenOptions::new().read(true).write(true).open(raw)?;
    let mut src = Consume { f, pos: 0, punched: 0 };
    let o = BufWriter::with_capacity(1 << 20, File::create(out)?);
    let st = img2simg(&mut src, size, o, 4096, |d, t| eprint!("\rimg2simg {}%", d * 100 / t))?;
    eprintln!();
    Ok(st)
}

/// The root build from an extracted root folder (the IPSW volumes merged: cryptexes first, OS volume on top):
/// copy-stage layout fixes, owner map, PAC strip of every Mach-O, HFSX image, sparse image.
fn cmd_root(args: &[String]) -> Res<ExitCode> {
    let (pos, opts, flags) = split(args, &["--map", "--size", "--name", "--date", "--raw", "--build", "--version", "--board", "--adt-target", "--netcfg", "--sweetreboot"]);
    let [src, out] = &pos[..] else {
        return Err("root SRC_DIR OUT.simg --build B --version V [--board N104 --adt-target N104] [--map owners.tsv] [--size 20g] [--raw RAW.img] [--keep-raw] [--no-tweaks] [--no-macho] [--quiet] [--netcfg FILE] [--sweetreboot FILE]".into());
    };
    let date: u32 = opts.get("--date").map(|d| d.parse()).transpose()?.unwrap_or(0);
    let (mut entries, paths, skipped) = renegade::tree::scan_dir(Path::new(src))?;
    eprintln!("{} entries, {} skipped (not file/folder/symlink)", entries.len(), skipped.len());
    renegade::tree::layout_fixes(&mut entries, date)?;
    let mut map = match opts.get("--map") {
        Some(m) => renegade::hfsedit::parse_map(&fs::read_to_string(m)?)?,
        None => Default::default(),
    };
    // tweaks on the tree (root_tweaks18.py on the mounted image); their chowns override the map like OWNER_EXTRA
    let base = paths.len();
    let read_src = |i: usize| fs::read(&paths[i]);
    let mut tfs = renegade::tweaks::TreeFs::new(entries, base, date, read_src);
    // SAFETY: getuid/getgid cannot fail
    tfs.skip_owner = Some(unsafe { (libc::getuid(), libc::getgid()) });
    if !flags.iter().any(|f| f == "--no-tweaks") {
        let read = |k: &str| opts.get(k).map(fs::read).transpose();
        let cfg = renegade::tweaks::Config {
            build: opts.get("--build").cloned().ok_or("--build is required (or --no-tweaks)")?,
            version: opts.get("--version").cloned().ok_or("--version is required (or --no-tweaks)")?,
            board: opts.get("--board").cloned().unwrap_or("N104".into()),
            adt_target: opts.get("--adt-target").cloned().unwrap_or("N104".into()),
            quiet: flags.iter().any(|f| f == "--quiet"),
            netcfg: read("--netcfg")?,
            sweetreboot: read("--sweetreboot")?,
            root_display: String::new(),
        };
        let mut log = Vec::new();
        renegade::tweaks::run(&mut tfs, &cfg, &mut log)?;
        for l in log {
            eprintln!("tweaks: {l}");
        }
        let recorded: Vec<(String, (u32, u32))> = renegade::tweaks::Fs::owners(&tfs).iter().map(|(k, v)| (k.clone(), *v)).collect();
        for (p, (u, g)) in recorded {
            let perm = renegade::tweaks::Fs::stat(&tfs, &p).map(|s| s.2).unwrap_or(0o644);
            use unicode_normalization::UnicodeNormalization;
            map.insert(p.nfd().collect(), (u, g, perm));
        }
    }
    // macho stage: strip, re-sign what changed (bundles sealed deepest first); CodeResources go into the tree
    let plan = if flags.iter().any(|f| f == "--no-macho") {
        renegade::machostage::Plan::default()
    } else {
        let p = renegade::machostage::plan(&mut tfs, renegade::tree::DYLD_DIR)?;
        eprintln!(
            "macho: {} Mach-Os, {} rewritten and re-signed ({} bundles sealed), {} unchanged: {}",
            p.machos,
            p.signed.len(),
            p.bundles_sealed,
            p.clean,
            Report { counts: p.counts.clone(), ..Default::default() }.summary()
        );
        p
    };
    let renegade::tweaks::TreeFs { mut entries, overlay, .. } = tfs;
    renegade::machostage::apply_sizes(&plan, &mut entries);
    let (mapped, defaulted) = renegade::tree::apply_map(&mut entries, &map, true);
    eprintln!("owners: {mapped} from the map, {defaulted} root:wheel");
    let o = renegade::hfswrite::Options {
        volume_name: opts.get("--name").cloned().unwrap_or("iOSRoot".into()),
        block_size: 4096,
        size: opts.get("--size").map(|s| parse_size(s)).transpose()?,
        date,
    };
    let raw = opts.get("--raw").map(Path::new).map(Path::to_path_buf).unwrap_or_else(|| Path::new(out).with_extension("img"));
    File::create(&raw)?;
    let mut w = renegade::io::FileRw::open(&raw)?;
    let st = renegade::hfswrite::build(&entries, &o, &mut w, &mut |source, sink| {
        if source >= base {
            return sink(&overlay[source - base]);
        }
        let data = renegade::machostage::final_bytes(&plan, source, fs::read(&paths[source])?)?;
        sink(&data)
    })?;
    eprintln!("{}: {} folders, {} files ({} hard links), {} of {} blocks free", raw.display(), st.folders, st.files, st.hard_links, st.free_blocks, st.total_blocks);
    drop(w);
    let keep = flags.iter().any(|f| f == "--keep-raw");
    let s = if keep {
        let o = BufWriter::new(File::create(out)?);
        img2simg(io::BufReader::new(File::open(&raw)?), fs::metadata(&raw)?.len(), o, 4096, |_, _| {})?
    } else {
        let s = img2simg_consume(&raw, Path::new(out))?;
        fs::remove_file(&raw)?;
        s
    };
    eprintln!("{out}: {} blocks, {} chunks", s.blocks, s.chunks);
    Ok(ExitCode::SUCCESS)
}

/// plistlib round trip: load IN (binary or XML), dump OUT as binary (default) or XML.
fn cmd_plist(args: &[String]) -> Res<ExitCode> {
    let (pos, opts, _) = split(args, &["--fmt"]);
    let [src, dst] = &pos[..] else { return Err("plist IN OUT [--fmt binary|xml]".into()) };
    let v = renegade::plist::parse(&fs::read(src)?)?;
    let out = match opts.get("--fmt").map(String::as_str) {
        Some("xml") => renegade::plist::to_xml(&v)?,
        _ => renegade::plist::to_binary(&v),
    };
    fs::write(dst, out)?;
    Ok(ExitCode::SUCCESS)
}

/// The ported tweaks on a root folder (what root_tweaks18.py does to the mounted image): prints the same lines,
/// then the recorded owners ("OWNER path uid gid").
fn cmd_tweaks(args: &[String]) -> Res<ExitCode> {
    let (pos, opts, flags) = split(args, &["--build", "--version", "--board", "--adt-target", "--netcfg", "--sweetreboot", "--display"]);
    let [root] = &pos[..] else { return Err("tweaks ROOT_DIR --build B --version V [--board N841 --adt-target D22] [--quiet] [--netcfg FILE] [--sweetreboot FILE] [--display PATH]".into()) };
    let read = |k: &str| opts.get(k).map(fs::read).transpose();
    let cfg = renegade::tweaks::Config {
        build: opts.get("--build").cloned().ok_or("--build is required")?,
        version: opts.get("--version").cloned().ok_or("--version is required")?,
        board: opts.get("--board").cloned().unwrap_or("N104".into()),
        adt_target: opts.get("--adt-target").cloned().unwrap_or("N104".into()),
        quiet: flags.iter().any(|f| f == "--quiet"),
        netcfg: read("--netcfg")?,
        sweetreboot: read("--sweetreboot")?,
        root_display: opts.get("--display").cloned().unwrap_or(root.clone()),
    };
    let mut f = renegade::tweaks::DirFs::new(root);
    let mut log = Vec::new();
    let r = renegade::tweaks::run(&mut f, &cfg, &mut log);
    for l in &log {
        println!("{l}");
    }
    r?;
    for (p, (u, g)) in renegade::tweaks::Fs::owners(&f) {
        println!("OWNER {p} {u} {g}");
    }
    Ok(ExitCode::SUCCESS)
}

/// A bundle executable's signing context: its bundle's Info.plist and CodeResources.
type BundleContext = (Option<Vec<u8>>, Option<Vec<u8>>);

/// When `exe` is the main executable of the bundle around it (Info.plist's CFBundleExecutable, else the folder's name), writes the
/// bundle's _CodeSignature/CodeResources as codesign does and returns (Info.plist, CodeResources).
fn seal_bundle_on_disk(exe: &Path) -> Res<BundleContext> {
    let dir = exe.parent().unwrap_or(Path::new("."));
    let name = exe.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let info = fs::read(dir.join("Info.plist")).ok();
    let dir_name = dir.canonicalize().ok().and_then(|d| d.file_name().map(|n| n.to_string_lossy().into_owned())).unwrap_or_default();
    if !renegade::bundle::is_main_executable(info.as_deref(), &dir_name, &name) {
        return Ok((None, None));
    }
    let mut items = Vec::new();
    let mut todo = vec![(dir.to_path_buf(), String::new())];
    while let Some((d, rel)) = todo.pop() {
        for e in fs::read_dir(&d)? {
            let e = e?;
            let nm = e.file_name().to_string_lossy().into_owned();
            let r = if rel.is_empty() { nm.clone() } else { format!("{rel}/{nm}") };
            if rel.is_empty() && (nm == "_CodeSignature" || nm == name) {
                continue;
            }
            let ft = e.file_type()?;
            if ft.is_dir() {
                todo.push((e.path(), r));
            } else if ft.is_symlink() {
                items.push((r, renegade::bundle::Item::Symlink(fs::read_link(e.path())?.to_string_lossy().into_owned())));
            } else {
                items.push((r, renegade::bundle::Item::file(&fs::read(e.path())?)));
            }
        }
    }
    let cr = renegade::bundle::code_resources(&items);
    fs::create_dir_all(dir.join("_CodeSignature"))?;
    fs::write(dir.join("_CodeSignature/CodeResources"), &cr)?;
    Ok((info, Some(cr)))
}

/// Re-signs ad hoc keeping identifier, options and entitlements (pacstrip.py's sign()). For a bundle's main
/// executable pass its Info.plist and _CodeSignature/CodeResources.
fn cmd_sign(args: &[String]) -> Res<ExitCode> {
    let (pos, opts, _) = split(args, &["-o", "--info", "--resources"]);
    let [src] = &pos[..] else { return Err("sign FILE [-o OUT] [--info Info.plist] [--resources CodeResources]".into()) };
    let data = fs::read(src)?;
    let (info, res) = if opts.contains_key("--info") || opts.contains_key("--resources") {
        (opts.get("--info").map(fs::read).transpose()?, opts.get("--resources").map(fs::read).transpose()?)
    } else {
        seal_bundle_on_disk(Path::new(opts.get("-o").unwrap_or(src)))?
    };
    let out = renegade::codesign::resign(&data, info, res)?;
    fs::write(opts.get("-o").unwrap_or(src), out)?;
    Ok(ExitCode::SUCCESS)
}

/// Re-signs every Mach-O of a root image in memory (identifier, options and entitlements from its own signature;
/// bundle executables with a freshly generated CodeResources) and compares with the image: what codesign wrote
/// must come out byte for byte.
fn cmd_resign_check(args: &[String]) -> Res<ExitCode> {
    let (pos, opts, _) = split(args, &["--prefix", "--show"]);
    let [img] = &pos[..] else { return Err("resign-check IMAGE.simg [--prefix /usr] [--show 10]".into()) };
    let show: usize = opts.get("--show").map(|s| s.parse()).transpose()?.unwrap_or(10);
    let v = Volume::open(Sparse::open(FileAt::open(img)?)?)?;
    let prefix = opts.get("--prefix").cloned().unwrap_or("/".into());
    let top = v.lookup(&prefix, true)?.filter(|e| e.rt == FOLDER).ok_or("prefix is not a folder")?;
    let read = |e: Entry| -> io::Result<Vec<u8>> { v.read_file(v.resolve_link(e).ok_or_else(|| io::Error::other("hard link without iNode"))?) };
    let mode = |e: Entry| v.resolve_link(e).and_then(|t| t.rec).map(|d| v.mode(d)).unwrap_or(0);
    // every file and symlink under a folder, paths relative to it (skip: the top _CodeSignature and `exe`)
    let bundle_items = |dir: u32, exe: &str| -> io::Result<Vec<(String, renegade::bundle::Item)>> {
        let mut out = Vec::new();
        let mut todo = vec![(dir, String::new())];
        while let Some((c, rel)) = todo.pop() {
            for (nm, e) in v.children(c) {
                let p = if rel.is_empty() { nm.clone() } else { format!("{rel}/{nm}") };
                if rel.is_empty() && (nm == "_CodeSignature" || nm == exe) {
                    continue;
                }
                if e.rt == FOLDER {
                    todo.push((e.cnid, p));
                } else if mode(*e) & 0o170000 == 0o120000 {
                    out.push((p, renegade::bundle::Item::Symlink(String::from_utf8_lossy(&read(*e)?).into_owned())));
                } else {
                    out.push((p, renegade::bundle::Item::file(&read(*e)?)));
                }
            }
        }
        Ok(out)
    };
    let (mut n, mut same, mut bundles, mut cr_same, mut cr_stale, mut apple, mut cr_sealed_ok) = (0u64, 0u64, 0u64, 0u64, 0u64, 0u64, 0u64);
    let mut own = 0u64;
    let mut bad: Vec<String> = Vec::new();
    let note = |bad: &mut Vec<String>, s: String| {
        if bad.len() < show {
            bad.push(s);
        }
    };
    let mut todo = vec![(top.cnid, prefix.trim_end_matches('/').to_string())];
    while let Some((cnid, p)) = todo.pop() {
        for (nm, e) in v.children(cnid) {
            let q = format!("{p}/{nm}");
            if e.rt == FOLDER {
                if !nm.starts_with("\0\0\0\0HFS+") {
                    todo.push((e.cnid, q));
                }
                continue;
            }
            if mode(*e) & 0o170000 != 0o100000 || q.starts_with("/System/Library/Caches/com.apple.dyld/") {
                continue;
            }
            let data = read(*e)?;
            if !looks_like_macho(&data) || renegade::codesign::identity(&data).is_none() {
                continue;
            }
            // a signature codesign did not write (Apple's own ad-hoc ones use 4 KiB pages): the Python build left
            // the file alone (pacstrip found nothing to rewrite)
            if renegade::codesign::page_shift(&data) != Some(14) {
                apple += 1;
                continue;
            }
            // entitlements not in `codesign -d --xml` form: signed by the build's own tools (codesign with the XML
            // as written), never re-signed by pacstrip.py, so not something resign reproduces
            if let Some(ents) = renegade::codesign::identity(&data).and_then(|i| i.entitlements)
                && renegade::codesign::codesign_xml(&ents).ok().as_deref() != Some(&ents[..])
            {
                own += 1;
                continue;
            }
            n += 1;
            let info = v.child(cnid, "Info.plist").map(read).transpose()?;
            let dir_name = p.rsplit('/').next().unwrap_or("");
            if renegade::bundle::is_main_executable(info.as_deref(), dir_name, nm) {
                bundles += 1;
                let items = bundle_items(cnid, nm)?;
                let cr = renegade::bundle::code_resources(&items);
                let old = v.child(cnid, "_CodeSignature").and_then(|c| v.child(c.cnid, "CodeResources")).map(read).transpose()?;
                // the binary's resource slot is the hash of the CodeResources codesign generated when it signed:
                // re-signed with ours, the binary must come out identical
                match renegade::codesign::resign(&data, info.clone(), Some(cr.clone())) {
                    Ok(out) if out == data => {
                        same += 1;
                        if old.as_deref() == Some(&cr[..]) {
                            cr_same += 1;
                        } else {
                            cr_sealed_ok += 1; // the CodeResources file in the image is not the one that was sealed
                        }
                    }
                    _ => match renegade::codesign::resign(&data, info, old.clone()) {
                        Ok(out) if out == data => {
                            same += 1;
                            let stale = old.as_deref().and_then(|o| renegade::bundle::stale_entries(o, &items)).unwrap_or_default();
                            if !stale.is_empty() {
                                cr_stale += 1;
                                note(&mut bad, format!("{q}: sealed with stale hashes (bundle signed before its nested code): {}", stale.join(", ")));
                            } else {
                                note(&mut bad, format!("{q}: sealed CodeResources differs from ours ({} vs {} bytes)", cr.len(), old.map(|o| o.len()).unwrap_or(0)));
                            }
                        }
                        Ok(out) => {
                            let at = out.iter().zip(&data).position(|(a, b)| a != b).unwrap_or(out.len().min(data.len()));
                            note(&mut bad, format!("{q}: bundle executable differs at byte {at} of {} (re-signed {} bytes)", data.len(), out.len()));
                        }
                        Err(err) => note(&mut bad, format!("{q}: {err}")),
                    },
                }
            } else {
                match renegade::codesign::resign(&data, None, None) {
                    Ok(out) if out == data => same += 1,
                    Ok(out) => {
                        let at = out.iter().zip(&data).position(|(a, b)| a != b).unwrap_or(out.len().min(data.len()));
                        note(&mut bad, format!("{q}: differs at byte {at} of {} (re-signed {} bytes)", data.len(), out.len()));
                    }
                    Err(err) => note(&mut bad, format!("{q}: {err}")),
                }
            }
            if n % 1000 == 0 {
                eprintln!("... {n} checked, {same} identical");
            }
        }
    }
    for b in &bad {
        println!("NOTE {b}");
    }
    println!(
        "{n} codesign-signed Mach-Os re-signed: {same} byte-identical ({apple} with Apple's untouched signature and {own} signed outside pacstrip skipped); \
         {bundles} bundle executables: our CodeResources is the sealed one for {}, ({cr_same} also equal to the file in the image, \
         {cr_sealed_ok} where the image holds another CodeResources than the sealed one), {cr_stale} sealed with stale hashes by the Python build",
        cr_same + cr_sealed_ok
    );
    Ok(if same == n { ExitCode::SUCCESS } else { ExitCode::FAILURE })
}

fn cmd_owners(args: &[String]) -> Res<ExitCode> {
    let (pos, opts, flags) = split(args, &["--map"]);
    let [img] = &pos[..] else { return Err("owners IMAGE [--map MAPFILE] [--default-root]".into()) };
    let map = match opts.get("--map") {
        Some(m) => renegade::hfsedit::parse_map(&fs::read_to_string(m)?)?,
        None => Default::default(),
    };
    let mut f = renegade::io::FileRw::open(img)?;
    let st = renegade::hfsedit::apply_owners(&mut f, &map, flags.iter().any(|f| f == "--default-root"))?;
    println!("{}", st.line());
    Ok(ExitCode::SUCCESS)
}

/// Deallocates a byte range of a file (macOS F_PUNCHHOLE, Linux fallocate PUNCH_HOLE): the range reads as zeros.
fn punch_hole(f: &File, off: u64, len: u64) -> io::Result<()> {
    use std::os::fd::AsRawFd;
    #[cfg(target_os = "macos")]
    {
        #[repr(C)]
        struct FPunchhole {
            fp_flags: u32,
            reserved: u32,
            fp_offset: libc::off_t,
            fp_length: libc::off_t,
        }
        let arg = FPunchhole { fp_flags: 0, reserved: 0, fp_offset: off as libc::off_t, fp_length: len as libc::off_t };
        // SAFETY: F_PUNCHHOLE (99) takes a pointer to struct fpunchhole, which outlives the call
        if unsafe { libc::fcntl(f.as_raw_fd(), 99, &arg) } != 0 {
            return Err(io::Error::last_os_error());
        }
    }
    #[cfg(target_os = "linux")]
    {
        // SAFETY: plain syscall on an open descriptor
        if unsafe { libc::fallocate(f.as_raw_fd(), libc::FALLOC_FL_KEEP_SIZE | libc::FALLOC_FL_PUNCH_HOLE, off as libc::off_t, len as libc::off_t) } != 0 {
            return Err(io::Error::last_os_error());
        }
    }
    Ok(())
}

fn cmd_trim(args: &[String]) -> Res<ExitCode> {
    let (pos, _, _) = split(args, &[]);
    let [img] = &pos[..] else { return Err("trim IMAGE".into()) };
    let f = renegade::io::FileRw::open(img)?;
    let (total, bsize, runs) = renegade::hfsedit::free_runs(&f)?;
    let mut freed = 0u64;
    for &(off, len) in &runs {
        punch_hole(f.file(), off, len)?;
        freed += len;
    }
    println!("{img}: {total} blocks of {bsize}, punched {} free runs = {} MiB", runs.len(), freed >> 20);
    Ok(ExitCode::SUCCESS)
}

/// Positional arguments and `--flag value` options.
fn split(args: &[String], with_value: &[&str]) -> (Vec<String>, BTreeMap<String, String>, Vec<String>) {
    let (mut pos, mut opts, mut flags) = (Vec::new(), BTreeMap::new(), Vec::new());
    let mut i = 0;
    while i < args.len() {
        let a = &args[i];
        if with_value.contains(&a.as_str()) && i + 1 < args.len() {
            opts.insert(a.clone(), args[i + 1].clone());
            i += 2;
            continue;
        }
        if a.starts_with('-') && a.len() > 1 {
            flags.push(a.clone());
        } else {
            pos.push(a.clone());
        }
        i += 1;
    }
    (pos, opts, flags)
}

fn cmd_img2simg(args: &[String]) -> Res<ExitCode> {
    let (pos, opts, _) = split(args, &["--block"]);
    let [src, dst] = &pos[..] else { return Err("img2simg RAW OUT [--block N]".into()) };
    let bs: u32 = opts.get("--block").map(|v| v.parse()).transpose()?.unwrap_or(4096);
    let size = fs::metadata(src)?.len();
    let input = io::BufReader::with_capacity(1 << 20, File::open(src)?);
    let out = BufWriter::with_capacity(1 << 20, File::create(dst)?);
    let st = img2simg(input, size, out, bs, |d, t| eprint!("\r{}%", d * 100 / t))?;
    eprintln!("\r{dst}: {} blocks, {} chunks, {} MiB", st.blocks, st.chunks, fs::metadata(dst)?.len() >> 20);
    Ok(ExitCode::SUCCESS)
}

fn cmd_simg2img(args: &[String]) -> Res<ExitCode> {
    let (pos, _, _) = split(args, &[]);
    let [src, dst] = &pos[..] else { return Err("simg2img IN OUT".into()) };
    let img = Sparse::open(FileAt::open(src)?)?;
    let out = File::create(dst)?;
    out.set_len(img.size())?;
    simg2img(&img, |off, data| std::os::unix::fs::FileExt::write_all_at(&out, data, off))?;
    eprintln!("{dst}: {} blocks", img.total_blocks);
    Ok(ExitCode::SUCCESS)
}

fn copy_out(f: &dyn ReadAt, out: &Path) -> io::Result<()> {
    let mut w = BufWriter::new(File::create(out)?);
    let mut buf = vec![0u8; 1 << 24];
    let mut o = 0;
    while o < f.size() {
        let k = (f.size() - o).min(buf.len() as u64) as usize;
        f.read_at(o, &mut buf[..k])?;
        w.write_all(&buf[..k])?;
        o += k as u64;
    }
    w.flush()
}

/// Python repr of hfsx.py's lookup tuple: `(2, 123, 4567)` / `(1, 2, None)`.
fn entry_repr(e: Option<Entry>) -> String {
    match e {
        None => "None".into(),
        Some(e) => format!("({}, {}, {})", e.rt, e.cnid, e.rec.map(|d| d.to_string()).unwrap_or("None".into())),
    }
}

fn cmd_hfs(args: &[String]) -> Res<ExitCode> {
    let [img, cmd, rest @ ..] = args else { return Err("hfs SIMG CMD ARGS".into()) };
    let v = Volume::open(Sparse::open(FileAt::open(img)?)?)?;
    let stdout = io::stdout();
    let mut o = BufWriter::new(stdout.lock());
    let arg = |i: usize| rest.get(i).map(String::as_str).ok_or("missing argument");
    match cmd.as_str() {
        "ls" => {
            let e = v.lookup(arg(0)?, true)?.ok_or("no such path")?;
            let mut kids: Vec<&(String, Entry)> = v.children(e.cnid).iter().collect();
            kids.sort_by(|a, b| a.0.cmp(&b.0));
            for (nm, c) in kids {
                if c.rt == FOLDER {
                    writeln!(o, "d {nm}")?;
                } else {
                    writeln!(o, "f {nm}  {}", v.fork_of(c.rec.unwrap()).0)?;
                }
            }
        }
        "cat" => {
            let f = v.open_file(arg(0)?)?;
            o.write_all(&f.read_vec(0, f.size() as usize)?)?;
        }
        "get" => copy_out(&v.open_file(arg(0)?)?, Path::new(arg(1)?))?,
        "stat" => {
            let e = v.lookup(arg(0)?, false)?;
            writeln!(o, "{}", entry_repr(e))?;
            if let Some(Entry { rt: FILE, rec: Some(d), .. }) = e {
                let (uid, gid) = v.owner(d);
                writeln!(o, "uid,gid ({uid}, {gid}) mode {:o} size {}", v.mode(d), v.fork_of(d).0)?;
            }
        }
        "find" => {
            let sub = arg(0)?;
            fn walk<R: ReadAt>(v: &Volume<R>, cnid: u32, p: &str, sub: &str, o: &mut dyn Write) -> io::Result<()> {
                for (nm, c) in v.children(cnid) {
                    let q = format!("{p}/{nm}");
                    if nm.contains(sub) {
                        writeln!(o, "{q}")?;
                    }
                    if c.rt == FOLDER {
                        walk(v, c.cnid, &q, sub, o)?;
                    }
                }
                Ok(())
            }
            walk(&v, 2, "", sub, &mut o)?;
        }
        "getdir" => {
            let src = arg(0)?.trim_end_matches('/');
            let dst = Path::new(arg(1)?);
            fn cp<R: ReadAt>(v: &Volume<R>, e: Entry, out: &Path) -> Res<()> {
                if e.rt == FOLDER {
                    fs::create_dir_all(out)?;
                    let mut kids: Vec<&(String, Entry)> = v.children(e.cnid).iter().collect();
                    kids.sort_by(|a, b| a.0.cmp(&b.0));
                    for (nm, c) in kids {
                        cp(v, *c, &out.join(nm))?;
                    }
                    return Ok(());
                }
                let e = v.resolve_link(e).ok_or("hard link without iNode")?;
                let d = e.rec.unwrap();
                let mode = v.mode(d);
                let data = v.read_file(e)?;
                if mode & 0o170000 == 0o120000 {
                    let _ = fs::remove_file(out);
                    symlink(String::from_utf8_lossy(&data).as_ref(), out)?;
                } else {
                    fs::write(out, &data)?;
                    fs::set_permissions(out, fs::Permissions::from_mode((mode & 0o7777) as u32))?;
                }
                Ok(())
            }
            let e = v.lookup(src, false)?.ok_or(format!("{src}: not found"))?;
            cp(&v, e, dst)?;
        }
        "dsc" => {
            let d = "/System/Library/Caches/com.apple.dyld";
            let e = v.lookup(d, true)?.ok_or("no dyld cache directory")?;
            let out = Path::new(arg(0)?);
            fs::create_dir_all(out)?;
            let mut kids: Vec<&(String, Entry)> = v.children(e.cnid).iter().collect();
            kids.sort_by(|a, b| a.0.cmp(&b.0));
            for (nm, c) in kids {
                if c.rt != FILE || nm.ends_with(".symbols") {
                    continue;
                }
                copy_out(&v.open_file(&format!("{d}/{nm}"))?, &out.join(nm))?;
                writeln!(o, "{nm}")?;
            }
        }
        other => return Err(format!("unknown hfs command {other}").into()),
    }
    o.flush()?;
    Ok(ExitCode::SUCCESS)
}

fn cmd_strip(args: &[String]) -> Res<ExitCode> {
    let (inputs, opts, flags) = split(args, &["-o", "--output", "--dylinker", "--subtype"]);
    let verbose = flags.iter().any(|f| f == "-v" || f == "--verbose");
    let scan = flags.iter().any(|f| f == "--scan");
    let do_sign = flags.iter().any(|f| f == "--sign");
    let output = opts.get("-o").or(opts.get("--output"));
    if output.is_some() && inputs.len() != 1 {
        return Err("-o needs exactly one input".into());
    }
    let o = Options { write: !scan, dylinker: opts.get("--dylinker").cloned(), subtype_arm64: opts.get("--subtype").map(String::as_str) == Some("arm64") };
    let mut total: BTreeMap<String, u64> = BTreeMap::new();
    for path in &inputs {
        let mut buf = fs::read(path)?;
        let rep = strip(&mut buf, &o)?;
        let name = Path::new(path).file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        if verbose {
            for (cls, off) in &rep.left {
                eprintln!("  {name}: {cls} at file+0x{off:x} left as is");
            }
        }
        println!("{path}: {}", rep.summary());
        for (sec, off) in rep.fjcvtzs.iter().take(20) {
            println!("  FJCVTZS at file+0x{off:x} ({sec})");
        }
        for (k, v) in &rep.counts {
            *total.entry(k.clone()).or_default() += v;
        }
        if !scan {
            let dst = output.unwrap_or(path);
            if do_sign {
                // pacstrip.py writes, then sign(out): codesign seals the bundle when `out` is its main executable
                let (info, cr) = seal_bundle_on_disk(Path::new(dst))?;
                buf = renegade::codesign::resign(&buf, info, cr)?;
            }
            fs::write(dst, &buf)?;
        }
    }
    if inputs.len() > 1 {
        let r = Report { counts: total, ..Default::default() };
        println!("TOTAL: {}", if r.counts.is_empty() { String::new() } else { r.summary() });
    }
    Ok(ExitCode::SUCCESS)
}

fn cmd_fixupcheck(args: &[String]) -> Res<ExitCode> {
    let (pos, opts, flags) = split(args, &["--prefix"]);
    let quiet = flags.iter().any(|f| f == "--quiet");
    let prefix = opts.get("--prefix").cloned().unwrap_or("/".into());
    let [src] = &pos[..] else { return Err("fixupcheck ROOT_DIR | IMAGE.simg [--prefix P] [--quiet]".into()) };
    let (mut n, mut bad) = (0u64, 0u64);
    let mut each = |name: &str, data: &[u8]| {
        n += 1;
        let probs = check_bytes(data, name);
        if !probs.is_empty() {
            bad += 1;
            for p in probs.iter().take(5) {
                println!("BAD {p}");
            }
        }
        if !quiet && n % 500 == 0 {
            eprintln!("... {n} Mach-Os checked, {bad} bad");
        }
    };
    if src.ends_with(".simg") {
        let v = Volume::open(Sparse::open(FileAt::open(src)?)?)?;
        let e = v.lookup(&prefix, true)?.filter(|e| e.rt == FOLDER).ok_or(format!("{prefix}: not a directory in {src}"))?;
        let mut todo = vec![(e.cnid, prefix.trim_end_matches('/').to_string())];
        while let Some((cnid, p)) = todo.pop() {
            for (nm, c) in v.children(cnid) {
                let q = format!("{p}/{nm}");
                if c.rt == FOLDER {
                    todo.push((c.cnid, q));
                    continue;
                }
                let Some(c) = v.resolve_link(*c) else { continue };
                let d = c.rec.unwrap();
                if v.mode(d) & 0o170000 != 0o100000 || v.fork_of(d).0 < 32 {
                    continue;
                }
                let (l, ext) = v.file_extents(c.cnid, d);
                if !looks_like_macho(&v.read_extents(&ext, 4)?) {
                    continue;
                }
                each(&q, &v.read_extents(&ext, l)?);
            }
        }
    } else {
        let root = Path::new(src);
        let top = root.join(prefix.trim_start_matches('/'));
        fn walk(dir: &Path, root: &Path, each: &mut dyn FnMut(&str, &[u8])) -> io::Result<()> {
            let mut files = Vec::new();
            let mut dirs = Vec::new();
            for ent in fs::read_dir(dir)? {
                let ent = ent?;
                let ft = ent.file_type()?;
                if ft.is_dir() {
                    dirs.push(ent.path());
                } else if ft.is_file() {
                    files.push(ent.path());
                }
            }
            for p in files {
                let data = fs::read(&p)?;
                if !looks_like_macho(&data) {
                    continue;
                }
                let rel = format!("/{}", p.strip_prefix(root).unwrap().display());
                each(&rel, &data);
            }
            for d in dirs {
                walk(&d, root, each)?;
            }
            Ok(())
        }
        walk(&top, root, &mut each)?;
    }
    println!("{n} Mach-O files checked, {bad} with fixup chains that would fail at page-in");
    Ok(if bad > 0 { ExitCode::FAILURE } else { ExitCode::SUCCESS })
}
