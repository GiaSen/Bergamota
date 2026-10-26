//! File data: data-stream extents (with holes) and transparent decmpfs decompression.

use super::btree::{Cursor, Space, Tree};
use super::fs::*;
use super::obj::*;
use super::VolCore;
use crate::io::{bad, short, ReadAt};
use std::cell::RefCell;
use std::cmp::Ordering;
use std::io::Result;
use std::rc::Rc;

/// decmpfs chunk size of the resource-fork types.
const CHUNK: u64 = 65536;
/// Compressed chunks are never much larger than the 64 KiB they hold.
const MAX_CHUNK_RAW: u64 = CHUNK + 4096;
/// Whole-file decompression of the inline (xattr) types is bounded.
const MAX_INLINE: u64 = 64 << 20;
const CACHED_CHUNKS: usize = 8;

#[derive(Clone, Copy)]
struct Ext {
    logical: u64,
    len: u64,
    /// Physical block number; 0 is a hole.
    phys: u64,
}

struct Stream {
    exts: Vec<Ext>,
}

impl Stream {
    fn read<R: ReadAt>(&self, sh: &Shared<R>, off: u64, buf: &mut [u8]) -> Result<()> {
        let bs = sh.bs as u64;
        let end = off + buf.len() as u64;
        let mut pos = off;
        while pos < end {
            let idx = self.exts.partition_point(|e| e.logical <= pos);
            let mut src = None;
            let n;
            match idx.checked_sub(1).map(|i| self.exts[i]) {
                Some(e) if pos < e.logical.saturating_add(e.len) => {
                    n = (end - pos).min(e.logical + e.len - pos);
                    if e.phys != 0 {
                        let base = e.phys.checked_mul(bs).ok_or_else(|| bad("extent address overflows"))?;
                        src = Some(base.checked_add(pos - e.logical).ok_or_else(|| bad("extent address overflows"))?);
                    }
                }
                _ => {
                    let next = self.exts.get(idx).map_or(u64::MAX, |e| e.logical);
                    n = (end - pos).min(next - pos);
                }
            }
            let dst = &mut buf[(pos - off) as usize..][..n as usize];
            match src {
                Some(o) => sh.read_bytes(o, dst)?,
                None => dst.fill(0),
            }
            pos += n;
        }
        Ok(())
    }
}

enum Rsrc {
    Embedded(Vec<u8>),
    Stream(Stream, u64),
}

impl Rsrc {
    fn size(&self) -> u64 {
        match self {
            Rsrc::Embedded(v) => v.len() as u64,
            Rsrc::Stream(_, n) => *n,
        }
    }
    fn read<R: ReadAt>(&self, sh: &Shared<R>, off: u64, len: usize) -> Result<Vec<u8>> {
        let end = off.checked_add(len as u64).ok_or_else(|| short(off))?;
        if end > self.size() {
            return Err(bad("resource fork read past its end"));
        }
        match self {
            Rsrc::Embedded(v) => Ok(v[off as usize..end as usize].to_vec()),
            Rsrc::Stream(s, _) => {
                let mut b = vec![0; len];
                s.read(sh, off, &mut b)?;
                Ok(b)
            }
        }
    }
}

enum Body {
    Stream(Stream),
    /// decmpfs data in the attribute itself, decoded on first use.
    Inline { ty: u32, raw: Vec<u8>, decoded: RefCell<Option<Rc<Vec<u8>>>> },
    /// 64 KiB chunks in the resource fork: (offset in the fork, compressed length) of each.
    Chunked { ty: u32, rsrc: Rsrc, blocks: Vec<(u64, u32)>, cache: RefCell<Vec<(usize, Rc<Vec<u8>>)>> },
}

/// A regular file's content, random access: [`ReadAt`] over the decompressed bytes.
pub struct File<R: ReadAt> {
    vol: Rc<VolCore<R>>,
    size: u64,
    compression: u32,
    body: Body,
}

impl<R: ReadAt> File<R> {
    /// The decmpfs type the file is stored with (0: not compressed).
    pub fn compression(&self) -> u32 {
        self.compression
    }
}

fn load_extents<R: ReadAt>(vol: &VolCore<R>, tree: &Tree<'_, R>, id: u64) -> Result<Stream> {
    let mut exts: Vec<Ext> = Vec::new();
    fn add(exts: &mut Vec<Ext>, id: u64, logical: u64, v: &[u8]) -> Result<()> {
        let len = le64(v, 0)? & 0x00ff_ffff_ffff_ffff;
        let phys = le64(v, 8)?;
        if len == 0 || exts.last().is_some_and(|l| l.logical.saturating_add(l.len) > logical) {
            return Err(bad(format!("file extents of object {id:#x} are empty or overlap")));
        }
        exts.push(Ext { logical, len, phys });
        Ok(())
    }
    vol.for_records(tree, id, T_FILE_EXTENT, &mut |r| {
        add(&mut exts, id, le64(r.key(), 8)?, r.val())?;
        Ok(true)
    })?;
    if exts.is_empty() && vol.info.fext_tree_oid != 0 {
        // sealed volumes keep the extents in a separate physical tree keyed by (private id, logical address)
        let ft = Tree::open(&vol.sh, Space::Phys, vol.info.fext_tree_oid)?;
        let mut c = Cursor::seek(&ft, &|k| match (le64(k, 0), le64(k, 8)) {
            (Ok(a), Ok(b)) => (a, b).cmp(&(id, 0)),
            _ => Ordering::Less,
        })?;
        while let Some(r) = c.next()? {
            if le64(r.key(), 0)? != id {
                break;
            }
            add(&mut exts, id, le64(r.key(), 8)?, r.val())?;
        }
    }
    Ok(Stream { exts })
}

pub(crate) fn open<R: ReadAt>(vol: &Rc<VolCore<R>>, ino: u64) -> Result<File<R>> {
    let tree = vol.fs_tree()?;
    let r = vol.find_inode(&tree, ino)?.ok_or_else(|| bad(format!("no inode {ino}")))?;
    if r.mode & S_IFMT != S_IFREG {
        return Err(bad(format!("inode {ino} is not a regular file")));
    }
    if r.bsd_flags & SF_DATALESS != 0 {
        return Err(bad(format!("inode {ino} is a dataless file (its data is not on the volume)")));
    }
    if r.bsd_flags & UF_COMPRESSED != 0 {
        if let Some((fl, attr)) = vol.xattr(&tree, ino, XA_DECMPFS)? {
            if fl & XATTR_DATA_EMBEDDED == 0 {
                return Err(bad("decmpfs attribute is not embedded"));
            }
            return open_compressed(vol, &tree, ino, &attr);
        }
    }
    let size = r.dstream_size.unwrap_or(0);
    let s = load_extents(vol, &tree, r.private_id)?;
    Ok(File { vol: vol.clone(), size, compression: 0, body: Body::Stream(s) })
}

fn open_compressed<R: ReadAt>(vol: &Rc<VolCore<R>>, tree: &Tree<'_, R>, ino: u64, attr: &[u8]) -> Result<File<R>> {
    let (ty, size) = decmpfs_header(attr).ok_or_else(|| bad(format!("inode {ino}: malformed decmpfs attribute")))?;
    let mk = |body| File { vol: vol.clone(), size, compression: ty, body };
    match ty {
        1 | 3 | 7 | 9 | 11 | 13 => {
            if size > MAX_INLINE {
                return Err(bad(format!("inode {ino}: inline compressed data claims {size} bytes")));
            }
            Ok(mk(Body::Inline { ty, raw: attr[16..].to_vec(), decoded: RefCell::new(None) }))
        }
        4 | 8 | 10 | 12 | 14 => {
            let (fl, d) = vol.xattr(tree, ino, XA_RSRC)?.ok_or_else(|| bad(format!("inode {ino}: compressed file without a resource fork")))?;
            let rsrc = if fl & XATTR_DATA_EMBEDDED != 0 {
                Rsrc::Embedded(d)
            } else if fl & XATTR_DATA_STREAM != 0 {
                let id = le64(&d, 0)?;
                let sz = le64(&d, 8)?;
                Rsrc::Stream(load_extents(vol, tree, id)?, sz)
            } else {
                return Err(bad("resource fork attribute has no data"));
            };
            let blocks = chunk_table(vol, ty, &rsrc, size)?;
            Ok(mk(Body::Chunked { ty, rsrc, blocks, cache: RefCell::new(Vec::new()) }))
        }
        5 => Err(bad(format!("inode {ino}: decmpfs type 5 (dataless / sparse compressed file) is not supported"))),
        0x8000_0001 => Err(bad(format!("inode {ino}: decmpfs faulting file (data not on the volume)"))),
        _ => Err(bad(format!("inode {ino}: unknown decmpfs type {ty}"))),
    }
}

/// (offset, length) of each 64 KiB chunk in the resource fork.
fn chunk_table<R: ReadAt>(vol: &VolCore<R>, ty: u32, rsrc: &Rsrc, size: u64) -> Result<Vec<(u64, u32)>> {
    let n = size.div_ceil(CHUNK);
    let fsz = rsrc.size();
    let mut out = Vec::new();
    if n == 0 {
        return Ok(out);
    }
    if ty == 4 {
        // 0x100: data length (BE), 0x104: chunk count (LE), then (offset from 0x104, length) pairs (LE)
        let need = 0x108u64.checked_add(n.checked_mul(8).unwrap_or(u64::MAX)).unwrap_or(u64::MAX);
        if need > fsz {
            return Err(bad("zlib resource fork is too small for its chunk table"));
        }
        let t = rsrc.read(&vol.sh, 0x104, 4 + 8 * n as usize)?;
        if le32(&t, 0)? as u64 != n {
            return Err(bad("zlib resource fork: chunk count does not match the file size"));
        }
        for i in 0..n as usize {
            let off = 0x104 + le32(&t, 4 + 8 * i)? as u64;
            let len = le32(&t, 8 + 8 * i)?;
            if len as u64 > MAX_CHUNK_RAW || off + len as u64 > fsz {
                return Err(bad("zlib resource fork: chunk outside the fork"));
            }
            out.push((off, len));
        }
    } else {
        // n + 1 little-endian offsets from the start of the fork
        if (n + 1) * 4 > fsz {
            return Err(bad("resource fork is too small for its chunk table"));
        }
        let t = rsrc.read(&vol.sh, 0, 4 * (n as usize + 1))?;
        let mut prev = le32(&t, 0)? as u64;
        if prev < 4 * (n + 1) {
            return Err(bad("resource fork: first chunk overlaps the chunk table"));
        }
        for i in 1..=n as usize {
            let next = le32(&t, 4 * i)? as u64;
            if next < prev || next - prev > MAX_CHUNK_RAW || next > fsz {
                return Err(bad("resource fork: chunk table is not monotonic or points outside the fork"));
            }
            out.push((prev, (next - prev) as u32));
            prev = next;
        }
    }
    Ok(out)
}

struct Bounded {
    v: Vec<u8>,
    max: usize,
}

impl std::io::Write for Bounded {
    fn write(&mut self, b: &[u8]) -> std::io::Result<usize> {
        if self.v.len() + b.len() > self.max {
            return Err(std::io::Error::other("LZFSE output larger than expected"));
        }
        self.v.extend_from_slice(b);
        Ok(b.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

/// Decodes one decmpfs block (a whole inline attribute or one 64 KiB chunk) to exactly `expect` bytes.
fn decode_block<R: ReadAt>(vol: &VolCore<R>, ty: u32, raw: &[u8], expect: usize) -> Result<Vec<u8>> {
    let first = *raw.first().ok_or_else(|| bad("empty compressed block"))?;
    let out = match ty {
        1 => raw.to_vec(),
        3 | 4 => {
            if first & 0x0f == 0x0f {
                raw[1..].to_vec()
            } else {
                miniz_oxide::inflate::decompress_to_vec_zlib_with_limit(raw, expect).map_err(|e| bad(format!("zlib block: {:?}", e.status)))?
            }
        }
        7 | 8 => {
            if first == 0x06 {
                raw[1..].to_vec()
            } else {
                super::lzvn::decode(raw, expect)?
            }
        }
        11 | 12 => {
            if first == 0xff {
                raw[1..].to_vec()
            } else {
                let mut slot = vol.lzfse.borrow_mut();
                let dec = slot.get_or_insert_with(Default::default);
                let mut w = Bounded { v: Vec::with_capacity(expect), max: expect };
                match dec.decode(&mut &raw[..], &mut w) {
                    Ok(_) => w.v,
                    Err(e) => {
                        *slot = None;
                        return Err(bad(format!("LZFSE block: {e}")));
                    }
                }
            }
        }
        13 | 14 => super::lzbitmap::decode(raw, expect)?,
        9 | 10 => {
            if raw.len() == expect {
                raw.to_vec()
            } else if first == 0xcc && raw.len() == expect + 1 {
                raw[1..].to_vec()
            } else {
                return Err(bad("raw decmpfs block has an unexpected size"));
            }
        }
        _ => return Err(bad(format!("unsupported decmpfs type {ty}"))),
    };
    if out.len() != expect {
        return Err(bad(format!("decompressed block has {} bytes, expected {expect}", out.len())));
    }
    Ok(out)
}

impl<R: ReadAt> File<R> {
    fn inline(&self) -> Result<Rc<Vec<u8>>> {
        let Body::Inline { ty, raw, decoded } = &self.body else { unreachable!() };
        if let Some(d) = decoded.borrow().as_ref() {
            return Ok(d.clone());
        }
        let d = if self.size == 0 { Vec::new() } else { decode_block(&self.vol, *ty, raw, self.size as usize)? };
        let d = Rc::new(d);
        *decoded.borrow_mut() = Some(d.clone());
        Ok(d)
    }

    fn chunk(&self, i: usize) -> Result<Rc<Vec<u8>>> {
        let Body::Chunked { ty, rsrc, blocks, cache } = &self.body else { unreachable!() };
        {
            let mut c = cache.borrow_mut();
            if let Some(p) = c.iter().position(|(k, _)| *k == i) {
                let e = c.remove(p);
                let v = e.1.clone();
                c.push(e);
                return Ok(v);
            }
        }
        let (off, len) = *blocks.get(i).ok_or_else(|| bad("chunk index out of range"))?;
        let raw = rsrc.read(&self.vol.sh, off, len as usize)?;
        let expect = (self.size - i as u64 * CHUNK).min(CHUNK) as usize;
        let out = Rc::new(decode_block(&self.vol, *ty, &raw, expect)?);
        let mut c = cache.borrow_mut();
        if c.len() >= CACHED_CHUNKS {
            c.remove(0);
        }
        c.push((i, out.clone()));
        Ok(out)
    }
}

impl<R: ReadAt> ReadAt for File<R> {
    fn size(&self) -> u64 {
        self.size
    }

    fn read_at(&self, off: u64, buf: &mut [u8]) -> Result<()> {
        let end = off.checked_add(buf.len() as u64).ok_or_else(|| short(off))?;
        if end > self.size {
            return Err(short(off));
        }
        if buf.is_empty() {
            return Ok(());
        }
        match &self.body {
            Body::Stream(s) => s.read(&self.vol.sh, off, buf),
            Body::Inline { .. } => {
                let d = self.inline()?;
                buf.copy_from_slice(&d[off as usize..end as usize]);
                Ok(())
            }
            Body::Chunked { .. } => {
                let mut pos = off;
                while pos < end {
                    let c = self.chunk((pos / CHUNK) as usize)?;
                    let co = (pos % CHUNK) as usize;
                    let n = (c.len() - co).min((end - pos) as usize);
                    buf[(pos - off) as usize..][..n].copy_from_slice(&c[co..co + n]);
                    pos += n as u64;
                }
                Ok(())
            }
        }
    }
}
