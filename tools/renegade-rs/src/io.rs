//! Positioned reads: a file, a buffer, a sparse image or a file inside an HFS+ volume all look the same.

use std::io::{Error, ErrorKind, Result};

pub trait ReadAt {
    fn size(&self) -> u64;
    /// Fills `buf` from `off`; an error if that runs past the end.
    fn read_at(&self, off: u64, buf: &mut [u8]) -> Result<()>;

    fn read_vec(&self, off: u64, len: usize) -> Result<Vec<u8>> {
        let mut v = vec![0; len];
        self.read_at(off, &mut v)?;
        Ok(v)
    }
}

impl ReadAt for [u8] {
    fn size(&self) -> u64 {
        self.len() as u64
    }
    fn read_at(&self, off: u64, buf: &mut [u8]) -> Result<()> {
        let o = usize::try_from(off).map_err(|_| short(off))?;
        let src = self.get(o..o + buf.len()).ok_or_else(|| short(off))?;
        buf.copy_from_slice(src);
        Ok(())
    }
}

impl ReadAt for Vec<u8> {
    fn size(&self) -> u64 {
        self.len() as u64
    }
    fn read_at(&self, off: u64, buf: &mut [u8]) -> Result<()> {
        self.as_slice().read_at(off, buf)
    }
}

impl<T: ReadAt + ?Sized> ReadAt for &T {
    fn size(&self) -> u64 {
        (**self).size()
    }
    fn read_at(&self, off: u64, buf: &mut [u8]) -> Result<()> {
        (**self).read_at(off, buf)
    }
}

pub(crate) fn short(off: u64) -> Error {
    Error::new(ErrorKind::UnexpectedEof, format!("read past the end at byte {off}"))
}

pub(crate) fn bad(msg: impl Into<String>) -> Error {
    Error::new(ErrorKind::InvalidData, msg.into())
}

/// A file on disk (native builds).
#[cfg(not(target_family = "wasm"))]
pub struct FileAt {
    file: std::fs::File,
    size: u64,
}

#[cfg(not(target_family = "wasm"))]
impl FileAt {
    pub fn open(path: impl AsRef<std::path::Path>) -> Result<Self> {
        let file = std::fs::File::open(path)?;
        let size = file.metadata()?.len();
        Ok(Self { file, size })
    }
}

#[cfg(not(target_family = "wasm"))]
impl ReadAt for FileAt {
    fn size(&self) -> u64 {
        self.size
    }
    fn read_at(&self, off: u64, buf: &mut [u8]) -> Result<()> {
        if off + buf.len() as u64 > self.size {
            return Err(short(off));
        }
        #[cfg(unix)]
        {
            std::os::unix::fs::FileExt::read_exact_at(&self.file, buf, off)
        }
        #[cfg(windows)]
        {
            let mut done = 0;
            while done < buf.len() {
                let n = std::os::windows::fs::FileExt::seek_read(&self.file, &mut buf[done..], off + done as u64)?;
                if n == 0 {
                    return Err(short(off + done as u64));
                }
                done += n;
            }
            Ok(())
        }
    }
}
