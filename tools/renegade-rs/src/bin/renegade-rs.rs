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
    let (pos, opts, flags) = split(args, &["--map", "--size", "--name", "--date", "--raw"]);
    let [src, out] = &pos[..] else { return Err("root SRC_DIR OUT.simg --unsigned [--map owners.tsv] [--size 20g] [--raw RAW.img] [--keep-raw]".into()) };
    if !flags.iter().any(|f| f == "--unsigned") {
        return Err("the Rust root build cannot re-sign the rewritten Mach-Os yet (pacstrip.py --sign does, through codesign/ldid): pass --unsigned to build anyway (the phone refuses unsigned code)".into());
    }
    let date: u32 = opts.get("--date").map(|d| d.parse()).transpose()?.unwrap_or(0);
    let (mut entries, paths, skipped) = renegade::tree::scan_dir(Path::new(src))?;
    eprintln!("{} entries, {} skipped (not file/folder/symlink)", entries.len(), skipped.len());
    renegade::tree::layout_fixes(&mut entries, date)?;
    let map = match opts.get("--map") {
        Some(m) => renegade::hfsedit::parse_map(&fs::read_to_string(m)?)?,
        None => Default::default(),
    };
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
    let dyld = Path::new(src).join(renegade::tree::DYLD_DIR);
    let mut totals: BTreeMap<String, u64> = BTreeMap::new();
    let (mut rewritten, mut machos) = (0u64, 0u64);
    let st = renegade::hfswrite::build(&entries, &o, &mut w, &mut |source, sink| {
        let p = &paths[source];
        let mut data = fs::read(p)?;
        if !p.starts_with(&dyld) && looks_like_macho(&data) {
            machos += 1;
            let before = data.clone();
            let rep = strip(&mut data, &Options { write: true, ..Default::default() }).map_err(io::Error::other)?;
            if data != before {
                rewritten += 1;
            }
            for (k, v) in rep.counts {
                *totals.entry(k).or_default() += v;
            }
        }
        sink(&data)
    })?;
    eprintln!("{machos} Mach-Os, {rewritten} rewritten: {}", Report { counts: totals, ..Default::default() }.summary());
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
    if flags.iter().any(|f| f == "--sign") {
        return Err("--sign is not ported yet: sign with tools/renegade/pacstrip.py --sign (codesign / ldid)".into());
    }
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
            fs::write(output.unwrap_or(path), &buf)?;
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
