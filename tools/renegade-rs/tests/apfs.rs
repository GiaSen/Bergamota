//! The APFS reader against ground truth: a real Apple container (RENEGADE_TEST_APFS, skipped when
//! unset; Apple's file, never copied anywhere) and synthetic volumes made with hdiutil (macOS only),
//! each compared with what the OS shows when it mounts the same image: lstat of every name (mode,
//! owner, size, mtime, nlink, inode), symlink targets and the bytes of every file.

use renegade::apfs::*;
use renegade::io::{FileAt, ReadAt};

#[cfg(target_os = "macos")]
mod mac {
    use super::*;
    use std::collections::{BTreeMap, HashMap};
    use std::os::unix::fs::{FileExt, MetadataExt};
    use std::path::{Path, PathBuf};
    use std::process::Command;

    pub fn have_hdiutil() -> bool {
        Command::new("hdiutil").arg("help").output().is_ok()
    }

    /// A mount of an image, detached on drop.
    pub struct Mounted {
        pub dir: PathBuf,
        dev: String,
    }

    impl Mounted {
        pub fn attach(img: &Path, mountpoint: &Path, readonly: bool) -> Option<Mounted> {
            std::fs::create_dir_all(mountpoint).ok()?;
            for raw in [false, true] {
                let mut c = Command::new("hdiutil");
                c.args(["attach", "-nobrowse", "-noverify", "-owners", "on", "-mountpoint"]).arg(mountpoint);
                if readonly {
                    c.arg("-readonly");
                }
                if raw {
                    c.args(["-imagekey", "diskimage-class=CRawDiskImage"]);
                }
                c.arg(img);
                let o = c.output().ok()?;
                if o.status.success() {
                    let out = String::from_utf8_lossy(&o.stdout).to_string();
                    let dev = out.lines().next()?.split_whitespace().next()?.to_string();
                    return Some(Mounted { dir: mountpoint.to_path_buf(), dev });
                }
            }
            None
        }
    }

    impl Drop for Mounted {
        fn drop(&mut self) {
            for _ in 0..5 {
                if Command::new("hdiutil").args(["detach", "-force"]).arg(&self.dev).output().map(|o| o.status.success()).unwrap_or(false) {
                    break;
                }
                std::thread::sleep(std::time::Duration::from_millis(500));
            }
            let _ = std::fs::remove_dir(&self.dir);
        }
    }

    #[derive(Default, Debug)]
    pub struct Report {
        pub names: usize,
        pub files: usize,
        pub bytes: u64,
        pub mismatches: Vec<String>,
        pub unreadable: usize,
        pub hardlink_groups: usize,
        pub compressed: BTreeMap<u32, usize>,
    }

    fn walk_mount(root: &Path, rel: &str, out: &mut Vec<String>) {
        let Ok(rd) = std::fs::read_dir(root.join(rel)) else { return };
        for e in rd.flatten() {
            let name = e.file_name().to_string_lossy().to_string();
            let p = if rel.is_empty() { name } else { format!("{rel}/{name}") };
            let is_dir = e.file_type().map(|t| t.is_dir()).unwrap_or(false);
            out.push(p.clone());
            if is_dir {
                walk_mount(root, &p, out);
            }
        }
    }

    /// Compares the reader's view of `image` with the OS's view of a mount of it.
    pub fn compare(image: &Path, work: &Path, tag: &str, check_data: bool) -> Report {
        let m = Mounted::attach(image, &work.join(format!("mnt-{tag}")), true).expect("attach");
        let c = Container::open(FileAt::open(image).unwrap()).unwrap();
        let vol = c.volume(0).unwrap();
        let mut rep = Report::default();
        let mut mine: HashMap<String, ()> = HashMap::new();
        let mut inodes: HashMap<u64, u32> = HashMap::new();
        let mut files: Vec<(String, u64, u64)> = Vec::new();
        vol.walk(&mut |n| {
            rep.names += 1;
            if !n.path.is_empty() {
                mine.insert(n.path.to_string(), ());
            }
            let md = match std::fs::symlink_metadata(m.dir.join(n.path)) {
                Ok(md) => md,
                Err(e) => {
                    rep.mismatches.push(format!("{}: not on the mount ({e})", n.path));
                    return Ok(());
                }
            };
            let mut diff = |what: &str, a: String, b: String| {
                if a != b && rep.mismatches.len() < 50 {
                    rep.mismatches.push(format!("{}: {what}: reader {a}, mount {b}", n.path));
                }
            };
            let fmt = md.mode() & 0o170000;
            let kind = match n.kind {
                Kind::Dir => 0o040000,
                Kind::File => 0o100000,
                Kind::Symlink => 0o120000,
                Kind::Other(m) => m as u32,
            };
            diff("type", format!("{kind:o}"), format!("{fmt:o}"));
            diff("mode", format!("{:o}", n.mode), format!("{:o}", md.mode() & 0o7777));
            diff("uid", n.uid.to_string(), md.uid().to_string());
            diff("gid", n.gid.to_string(), md.gid().to_string());
            diff("mtime", n.mtime.to_string(), md.mtime().to_string());
            diff("ino", n.ino.to_string(), md.ino().to_string());
            diff("nlink", n.nlink.to_string(), md.nlink().to_string());
            match n.kind {
                Kind::File => {
                    diff("size", n.size.to_string(), md.size().to_string());
                    files.push((n.path.to_string(), n.ino, n.size));
                    if n.compression != 0 {
                        *rep.compressed.entry(n.compression).or_default() += 1;
                    }
                }
                Kind::Symlink => {
                    let t = std::fs::read_link(m.dir.join(n.path)).map(|p| p.to_string_lossy().to_string()).unwrap_or_default();
                    diff("target", n.target.unwrap_or("<none>").to_string(), t);
                    diff("size", n.size.to_string(), md.size().to_string());
                }
                _ => {}
            }
            if n.kind != Kind::Dir && md.nlink() > 1 {
                *inodes.entry(n.ino).or_default() += 1;
            }
            Ok(())
        })
        .unwrap();
        rep.hardlink_groups = inodes.values().filter(|&&c| c > 1).count();
        // names on the mount that the reader did not list
        let mut theirs = Vec::new();
        walk_mount(&m.dir, "", &mut theirs);
        for p in &theirs {
            if !mine.contains_key(p) && rep.mismatches.len() < 50 {
                rep.mismatches.push(format!("{p}: on the mount, not listed by the reader"));
            }
        }
        if theirs.len() != mine.len() && rep.mismatches.len() < 50 {
            rep.mismatches.push(format!("name count: reader {}, mount {}", mine.len(), theirs.len()));
        }
        // file contents
        if check_data {
            for (path, ino, size) in &files {
                let f = vol.open_file(*ino).unwrap_or_else(|e| panic!("{path}: open: {e}"));
                assert_eq!(f.size(), *size);
                let Ok(real) = std::fs::File::open(m.dir.join(path)) else {
                    rep.unreadable += 1;
                    continue;
                };
                let mut off = 0u64;
                let mut a = vec![0u8; 1 << 20];
                let mut b = vec![0u8; 1 << 20];
                let mut ok = true;
                while off < *size {
                    let n = ((*size - off) as usize).min(a.len());
                    if real.read_exact_at(&mut b[..n], off).is_err() {
                        rep.unreadable += 1;
                        ok = false;
                        break;
                    }
                    f.read_at(off, &mut a[..n]).unwrap_or_else(|e| panic!("{path}: read at {off}: {e}"));
                    if a[..n] != b[..n] {
                        rep.mismatches.push(format!("{path}: content differs near byte {off}"));
                        ok = false;
                        break;
                    }
                    off += n as u64;
                }
                if ok {
                    rep.files += 1;
                    rep.bytes += size;
                }
            }
        }
        rep
    }

    pub fn work_dir(name: &str) -> PathBuf {
        let base = std::env::var("RENEGADE_TEST_TMP").map(PathBuf::from).unwrap_or_else(|_| std::env::temp_dir());
        let d = base.join(format!("renegade-apfs-{name}-{}", std::process::id()));
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    /// Creates an empty APFS image of `mb` MB (a raw container at offset 0), fills it with `populate`
    /// while mounted writable, detaches it and returns its path.
    pub fn make_image(work: &Path, tag: &str, case_sensitive: bool, mb: u32, populate: &dyn Fn(&Path)) -> Option<PathBuf> {
        let img = work.join(format!("{tag}.dmg"));
        let fs = if case_sensitive { "Case-sensitive APFS" } else { "APFS" };
        let o = Command::new("hdiutil").args(["create", "-size", &format!("{mb}m"), "-layout", "NONE", "-fs", fs, "-volname", "T", "-type", "UDIF"]).arg(&img).output().ok()?;
        if !o.status.success() {
            return None;
        }
        {
            let m = Mounted::attach(&img, &work.join(format!("w-{tag}")), false)?;
            populate(&m.dir);
            let _ = Command::new("sync").status();
        }
        // a raw container has "NXSB" at byte 0x20
        let head = std::fs::read(&img).ok()?;
        if head.get(32..36) != Some(b"NXSB") {
            let cdr = work.join(format!("{tag}.cdr"));
            let o = Command::new("hdiutil").args(["convert", "-format", "UDTO", "-o"]).arg(&cdr).arg(&img).output().ok()?;
            if !o.status.success() {
                return None;
            }
            std::fs::rename(&cdr, &img).ok()?;
        }
        Some(img)
    }

    pub fn sh(cmd: &str) {
        let o = Command::new("sh").arg("-c").arg(cmd).output().unwrap();
        assert!(o.status.success(), "{cmd}: {}", String::from_utf8_lossy(&o.stderr));
    }
}

fn real_image() -> Option<String> {
    std::env::var("RENEGADE_TEST_APFS").ok().filter(|p| std::path::Path::new(p).exists())
}

/// The real iOS 26 AppOS cryptex container: sealed volume, hashed fs-tree, file extents in the fext
/// tree, LZBITMAP (type 14) and raw (type 9) compressed files; compared with a read-only mount.
#[cfg(target_os = "macos")]
#[test]
fn real_container_matches_mount() {
    let Some(p) = real_image() else { return };
    if !mac::have_hdiutil() {
        return;
    }
    let work = mac::work_dir("real");
    let rep = mac::compare(std::path::Path::new(&p), &work, "real", true);
    println!("{rep:#?}");
    assert!(rep.mismatches.is_empty(), "{:#?}", rep.mismatches);
    assert!(rep.names > 1000);
    assert!(rep.compressed.get(&14).copied().unwrap_or(0) > 100, "expected LZBITMAP files");
    assert_eq!(rep.unreadable, 0);
    let _ = std::fs::remove_dir_all(work);
}

#[test]
fn real_container_stats_are_consistent() {
    let Some(p) = real_image() else { return };
    let c = Container::open(FileAt::open(&p).unwrap()).unwrap();
    let vols = c.volumes().unwrap();
    assert!(!vols.is_empty());
    let v = c.volume(vols[0].index).unwrap();
    let s = v.fsck_stats().unwrap();
    println!("{s}");
    assert!(s.consistent(), "{s}");
    assert!(v.info().sealed);
}
