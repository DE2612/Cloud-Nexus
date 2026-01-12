/// File I/O operations for CloudNexus
/// Handles upload, download, and copy operations with progress tracking and cancellation support
use std::fs::{File, OpenOptions};
use std::io::{Read, Write, Seek, SeekFrom, BufReader, BufWriter};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Instant;
use std::ffi::{c_char, c_void, CStr};
use std::ptr;

use crate::encryption::{EncryptionContext, DecryptionContext};

// Error codes
pub const SUCCESS: i32 = 0;
pub const ERROR_NULL_POINTER: i32 = -1;
pub const ERROR_FILE_NOT_FOUND: i32 = -2;
pub const ERROR_PERMISSION_DENIED: i32 = -3;
pub const ERROR_DISK_FULL: i32 = -4;
pub const ERROR_INVALID_PATH: i32 = -5;
pub const ERROR_IO_FAILED: i32 = -6;
pub const ERROR_CANCELLED: i32 = -7;
pub const ERROR_BUFFER_ALLOC_FAILED: i32 = -8;

const DEFAULT_CHUNK_SIZE: usize = 1024 * 1024; // 1MB chunks
const PROGRESS_UPDATE_INTERVAL_MS: u64 = 500; // 500ms = 2 updates/second

/// Progress throttler to limit callback frequency
pub struct ProgressThrottler {
    last_update_time: Instant,
    update_interval_ms: u64,
    last_bytes_processed: usize,
    last_bytes_transferred: usize,
}

impl ProgressThrottler {
    pub fn new(interval_ms: u64) -> Self {
        Self {
            last_update_time: Instant::now(),
            update_interval_ms: interval_ms,
            last_bytes_processed: 0,
            last_bytes_transferred: 0,
        }
    }
    
    /// Check if progress should be reported
    /// Returns true if should update, and the bytes to report
    pub fn should_update(&mut self, bytes_processed: usize, bytes_transferred: usize) -> bool {
        let now = Instant::now();
        let elapsed = now.duration_since(self.last_update_time).as_millis();
        
        // Update on interval OR if operation complete
        let should_update = elapsed >= self.update_interval_ms as u128 ||
                            bytes_processed == 0 || // Force update on completion
                            self.last_bytes_processed != bytes_processed;
        
        if should_update {
            self.last_update_time = now;
            self.last_bytes_processed = bytes_processed;
            self.last_bytes_transferred = bytes_transferred;
        }
        
        should_update
    }
}

/// Upload context for streaming uploads
#[repr(C)]
pub struct UploadContext {
    input_file: *mut BufReader<File>,
    encryption_context: Option<*mut EncryptionContext>,
    bytes_read: usize,
    total_bytes: usize,
    chunk_index: u32,
    should_encrypt: bool,
    cancel_flag: *const AtomicBool,
    progress_throttler: ProgressThrottler,
}

impl UploadContext {
    pub fn new(total_bytes: usize, should_encrypt: bool, cancel_flag: *const AtomicBool) -> Self {
        Self {
            input_file: ptr::null_mut(),
            encryption_context: None,
            bytes_read: 0,
            total_bytes,
            chunk_index: 0,
            should_encrypt,
            cancel_flag,
            progress_throttler: ProgressThrottler::new(PROGRESS_UPDATE_INTERVAL_MS),
        }
    }
}

/// Download context for streaming downloads
#[repr(C)]
pub struct DownloadContext {
    output_file: *mut BufWriter<File>,
    decryption_context: Option<*mut DecryptionContext>,
    bytes_written: usize,
    total_bytes: usize,
    cancel_flag: *const AtomicBool,
    progress_throttler: ProgressThrottler,
}

impl DownloadContext {
    pub fn new(total_bytes: usize, cancel_flag: *const AtomicBool) -> Self {
        Self {
            output_file: ptr::null_mut(),
            decryption_context: None,
            bytes_written: 0,
            total_bytes,
            cancel_flag,
            progress_throttler: ProgressThrottler::new(PROGRESS_UPDATE_INTERVAL_MS),
        }
    }
}

/// Copy context for file/folder copy operations
#[repr(C)]
pub struct CopyContext {
    bytes_copied: usize,
    total_bytes: usize,
    files_processed: usize,
    total_files: usize,
    cancel_flag: *const AtomicBool,
    progress_throttler: ProgressThrottler,
    is_folder: bool,
}

impl CopyContext {
    pub fn new(total_bytes: usize, total_files: usize, cancel_flag: *const AtomicBool, is_folder: bool) -> Self {
        Self {
            bytes_copied: 0,
            total_bytes,
            files_processed: 0,
            total_files,
            cancel_flag,
            progress_throttler: ProgressThrottler::new(PROGRESS_UPDATE_INTERVAL_MS),
            is_folder,
        }
    }
}

/// Helper function to convert C string to Path
pub unsafe fn c_str_to_path(path: *const c_char) -> Result<PathBuf, i32> {
    if path.is_null() {
        return Err(ERROR_NULL_POINTER);
    }
    
    let c_str = match CStr::from_ptr(path).to_str() {
        Ok(s) => s,
        Err(_) => return Err(ERROR_INVALID_PATH),
    };
    
    Ok(PathBuf::from(c_str))
}

/// Helper function to check if cancellation is requested
pub unsafe fn is_cancelled(cancel_flag: *const AtomicBool) -> bool {
    if cancel_flag.is_null() {
        return false;
    }
    (*cancel_flag).load(Ordering::Relaxed)
}

/// Convert string path to native char pointer
pub unsafe fn string_to_c_char(s: &str) -> *mut c_char {
    // Allocate with null terminator
    let bytes = s.as_bytes();
    let len = bytes.len();
    let ptr = libc::malloc(len + 1) as *mut u8;
    if ptr.is_null() {
        return ptr::null_mut() as *mut c_char;
    }
    
    // Copy bytes and add null terminator
    for (i, &byte) in bytes.iter().enumerate() {
        ptr.add(i).write(byte);
    }
    ptr.add(len).write(0);
    
    ptr as *mut c_char
}