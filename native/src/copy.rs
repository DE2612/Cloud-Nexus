/// Copy operations for CloudNexus
/// Handles streaming file and folder copies with progress reporting and cancellation
use std::fs::{self, File, DirBuilder};
use std::io::{Read, Write, BufReader, BufWriter};
use std::path::{Path, PathBuf};
use std::sync::atomic::AtomicBool;
use std::ffi::{c_char, c_void};
use std::ptr;
use std::slice;

use crate::file_io::{ProgressThrottler, ERROR_NULL_POINTER, ERROR_FILE_NOT_FOUND, 
                     ERROR_PERMISSION_DENIED, ERROR_IO_FAILED, ERROR_CANCELLED, 
                     ERROR_INVALID_PATH, SUCCESS, c_str_to_path, is_cancelled};

/// Progress callback for copy operations
/// For files: bytes_copied, total_bytes, user_data
/// For folders: bytes_copied, total_bytes, files_processed, total_files, user_data
pub type CopyProgressCallback = extern "C" fn(bytes_copied: usize, total_bytes: usize, files_processed: usize, total_files: usize, user_data: *mut c_void);

/// Data callback type for chunked streaming copy
/// Returns the number of bytes read (0 for EOF, negative for error)
pub type CopyDataCallback = extern "C" fn(data: *mut u8, data_len: usize, user_data: *mut c_void) -> isize;

/// Copy context for folder copy operations
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
            progress_throttler: ProgressThrottler::new(500),
            is_folder,
        }
    }
}

/// Copy a single file with streaming
///
/// # Arguments
/// * `source_path` - Source file path
/// * `dest_path` - Destination file path
/// * `chunk_size` - Size of chunks in bytes
/// * `progress_callback` - Progress callback
/// * `cancel_flag` - Cancellation flag
/// * `user_data` - User data
///
/// # Returns
/// 0 on success, error code on failure
#[no_mangle]
pub extern "C" fn copy_file_streaming(
    source_path: *const c_char,
    dest_path: *const c_char,
    chunk_size: usize,
    progress_callback: Option<CopyProgressCallback>,
    cancel_flag: *const AtomicBool,
    user_data: *mut c_void,
) -> i32 {
    if source_path.is_null() || dest_path.is_null() {
        return ERROR_NULL_POINTER;
    }

    let src = match unsafe { c_str_to_path(source_path) } {
        Ok(p) => p,
        Err(_) => return ERROR_INVALID_PATH,
    };

    let dst = match unsafe { c_str_to_path(dest_path) } {
        Ok(p) => p,
        Err(_) => return ERROR_INVALID_PATH,
    };

    // Get source file size
    let metadata = match src.metadata() {
        Ok(m) => m,
        Err(_) => return ERROR_FILE_NOT_FOUND,
    };

    if !metadata.is_file() {
        return ERROR_INVALID_PATH;
    }

    let total_bytes = metadata.len() as usize;
    let mut throttler = ProgressThrottler::new(500);
    let mut bytes_copied = 0;

    // Open source file
    let src_file = match File::open(&src) {
        Ok(f) => f,
        Err(_) => return ERROR_FILE_NOT_FOUND,
    };

    // Create destination file
    let dst_file = match File::create(&dst) {
        Ok(f) => f,
        Err(_) => return ERROR_PERMISSION_DENIED,
    };

    let mut reader = BufReader::new(src_file);
    let mut writer = BufWriter::new(dst_file);
    let chunk_size = chunk_size.max(64 * 1024).min(10 * 1024 * 1024); // 64KB to 10MB

    let mut buffer = vec![0u8; chunk_size];
    
    loop {
        // Check cancellation
        if unsafe { is_cancelled(cancel_flag) } {
            return ERROR_CANCELLED;
        }

        // Read chunk
        let bytes_read = match reader.read(&mut buffer) {
            Ok(0) => break, // EOF
            Ok(n) => n,
            Err(_) => return ERROR_IO_FAILED,
        };

        // Write chunk
        if let Err(_) = writer.write_all(&buffer[..bytes_read]) {
            return ERROR_IO_FAILED;
        }

        bytes_copied += bytes_read;

        // Progress callback (files_processed=1, total_files=1 for single file)
        if let Some(cb) = progress_callback {
            if throttler.should_update(bytes_copied, total_bytes) {
                cb(bytes_copied, total_bytes, 1, 1, user_data);
            }
        }
    }

    // Final progress update
    if let Some(cb) = progress_callback {
        cb(total_bytes, total_bytes, 1, 1, user_data);
    }

    // Flush writer
    if let Err(_) = writer.flush() {
        return ERROR_IO_FAILED;
    }

    SUCCESS
}

/// Alias for copy_file_streaming for FFI compatibility
#[no_mangle]
pub extern "C" fn copy_file(
    source_path: *const c_char,
    dest_path: *const c_char,
    chunk_size: usize,
    progress_callback: Option<CopyProgressCallback>,
    cancel_flag: *const AtomicBool,
    user_data: *mut c_void,
) -> i32 {
    copy_file_streaming(
        source_path,
        dest_path,
        chunk_size,
        progress_callback,
        cancel_flag,
        user_data,
    )
}

/// Copy context for folder copy
#[repr(C)]
pub struct FolderCopyContext {
    source_root: PathBuf,
    dest_root: PathBuf,
    bytes_copied: usize,
    total_bytes: usize,
    files_processed: usize,
    total_files: usize,
    cancel_flag: *const AtomicBool,
    progress_throttler: ProgressThrottler,
}

impl FolderCopyContext {
    pub fn new(source_root: PathBuf, dest_root: PathBuf, total_bytes: usize, 
               total_files: usize, cancel_flag: *const AtomicBool) -> Self {
        Self {
            source_root,
            dest_root,
            bytes_copied: 0,
            total_bytes,
            files_processed: 0,
            total_files,
            cancel_flag,
            progress_throttler: ProgressThrottler::new(500),
        }
    }
}

/// Initialize folder copy context
///
/// # Arguments
/// * `source_folder` - Source folder path
/// * `dest_folder` - Destination folder path
/// * `cancel_flag` - Cancellation flag
///
/// # Returns
/// Pointer to FolderCopyContext, or null on error
#[no_mangle]
pub extern "C" fn folder_copy_init(
    source_folder: *const c_char,
    dest_folder: *const c_char,
    cancel_flag: *const AtomicBool,
) -> *mut FolderCopyContext {
    if source_folder.is_null() || dest_folder.is_null() {
        return ptr::null_mut();
    }

    let src = match unsafe { c_str_to_path(source_folder) } {
        Ok(p) => p,
        Err(_) => return ptr::null_mut(),
    };

    let dst = match unsafe { c_str_to_path(dest_folder) } {
        Ok(p) => p,
        Err(_) => return ptr::null_mut(),
    };

    // Create destination folder if it doesn't exist
    if let Err(_) = DirBuilder::new().create(&dst) {
        return ptr::null_mut();
    }

    // Count files and total size
    let (total_files, total_bytes) = match count_files_and_size(&src) {
        Ok(result) => result,
        Err(_) => return ptr::null_mut(),
    };

    let context = Box::new(FolderCopyContext::new(
        src, dst, total_bytes, total_files, cancel_flag,
    ));

    Box::leak(context) as *mut FolderCopyContext
}

/// Count files and total size in a folder
fn count_files_and_size(path: &Path) -> Result<(usize, usize), std::io::Error> {
    let mut file_count = 0;
    let mut total_size = 0;

    if path.is_file() {
        return Ok((1, path.metadata()?.len() as usize));
    }

    for entry in fs::read_dir(path)? {
        let entry = entry?;
        let entry_path = entry.path();
        
        if entry_path.is_file() {
            file_count += 1;
            total_size += entry_path.metadata()?.len() as usize;
        } else if entry_path.is_dir() {
            let (count, size) = count_files_and_size(&entry_path)?;
            file_count += count;
            total_size += size;
        }
    }

    Ok((file_count, total_size))
}

/// Copy next file in folder copy operation
/// Returns 0 when done, 1 when more files to copy, negative on error
///
/// # Arguments
/// * `context` - Pointer to FolderCopyContext
/// * `progress_callback` - Progress callback
/// * `user_data` - User data
///
/// # Returns
/// 1 if more files to copy, 0 if done, negative error code
#[no_mangle]
pub extern "C" fn folder_copy_next_file(
    context: *mut FolderCopyContext,
    progress_callback: Option<CopyProgressCallback>,
    user_data: *mut c_void,
) -> i32 {
    if context.is_null() {
        return ERROR_NULL_POINTER;
    }

    let ctx = unsafe { &mut *context };

    // Check if all files processed
    if ctx.files_processed >= ctx.total_files {
        return 0;
    }

    // Check cancellation
    if unsafe { is_cancelled(ctx.cancel_flag) } {
        return ERROR_CANCELLED;
    }

    // Find and copy the next file
    let mut files_copied_in_call = 0;
    
    // Use a simple approach: iterate through source directory
    let result = copy_next_file_impl(ctx, progress_callback, user_data, &mut files_copied_in_call);
    
    result
}

fn copy_next_file_impl(
    ctx: &mut FolderCopyContext,
    progress_callback: Option<CopyProgressCallback>,
    user_data: *mut c_void,
    files_copied_in_call: &mut usize,
) -> i32 {
    let mut entries: Vec<_> = match fs::read_dir(&ctx.source_root) {
        Ok(e) => e.filter_map(|e| e.ok()).collect(),
        Err(_) => return ERROR_IO_FAILED,
    };

    // Sort to maintain consistent order
    entries.sort_by_key(|e| e.file_name());

    for entry in entries {
        // Check cancellation
        if unsafe { is_cancelled(ctx.cancel_flag) } {
            return ERROR_CANCELLED;
        }

        let src_path = entry.path();
        let file_name = entry.file_name();
        let dest_path = ctx.dest_root.join(&file_name);

        if src_path.is_file() {
            // Copy file
            if let Err(_) = copy_single_file(&src_path, &dest_path) {
                return ERROR_IO_FAILED;
            }

            let metadata = src_path.metadata().unwrap();
            let file_size = metadata.len() as usize;

            ctx.bytes_copied += file_size;
            ctx.files_processed += 1;
            *files_copied_in_call += 1;

            // Progress callback
            if let Some(cb) = progress_callback {
                if ctx.progress_throttler.should_update(ctx.bytes_copied, ctx.total_bytes) {
                    cb(ctx.bytes_copied, ctx.total_bytes, ctx.files_processed, ctx.total_files, user_data);
                }
            }

            // Return 1 to indicate more files may need to be copied
            return 1;
        } else if src_path.is_dir() {
            // Create subdirectory
            if let Err(_) = DirBuilder::new().create(&dest_path) {
                return ERROR_PERMISSION_DENIED;
            }

            // Save current state
            let prev_source_root = ctx.source_root.clone();
            let prev_dest_root = ctx.dest_root.clone();

            // Update state for recursive copy
            ctx.source_root = src_path.clone();
            ctx.dest_root = dest_path;

            // Recursively copy subdirectory
            let result = copy_next_file_impl(ctx, progress_callback, user_data, files_copied_in_call);

            // Restore state
            ctx.source_root = prev_source_root;
            ctx.dest_root = prev_dest_root;

            if result < 0 {
                return result; // Error
            }

            // If result is 1, we copied something in subdirectory
            // Continue to find more files
        }
    }

    // No more files in this directory
    0
}

fn copy_single_file(src: &Path, dst: &Path) -> Result<(), std::io::Error> {
    let src_file = File::open(src)?;
    let dst_file = File::create(dst)?;

    let mut reader = BufReader::new(src_file);
    let mut writer = BufWriter::new(dst_file);
    let mut buffer = vec![0u8; 1024 * 1024]; // 1MB chunks

    loop {
        let bytes_read = reader.read(&mut buffer)?;
        if bytes_read == 0 {
            break;
        }
        writer.write_all(&buffer[..bytes_read])?;
    }

    writer.flush()?;
    Ok(())
}

/// Finalize folder copy
///
/// # Arguments
/// * `context` - Pointer to FolderCopyContext
/// * `progress_callback` - Progress callback
/// * `user_data` - User data
///
/// # Returns
/// 0 on success, error code on failure
#[no_mangle]
pub extern "C" fn folder_copy_finalize(
    context: *mut FolderCopyContext,
    progress_callback: Option<CopyProgressCallback>,
    user_data: *mut c_void,
) -> i32 {
    if context.is_null() {
        return ERROR_NULL_POINTER;
    }

    let ctx = unsafe { &mut *context };

    // Final progress update
    if let Some(cb) = progress_callback {
        cb(ctx.bytes_copied, ctx.total_bytes, ctx.files_processed, ctx.total_files, user_data);
    }

    SUCCESS
}

/// Free folder copy context
#[no_mangle]
pub extern "C" fn folder_copy_free(context: *mut FolderCopyContext) {
    if !context.is_null() {
        unsafe {
            let _ = Box::from_raw(context);
        }
    }
}

/// Get copy progress
///
/// # Arguments
/// * `context` - Pointer to CopyContext or FolderCopyContext
/// * `bytes_copied` - Pointer to store bytes copied
/// * `total_bytes` - Pointer to store total bytes
/// * `files_processed` - Pointer to store files processed
/// * `total_files` - Pointer to store total files
#[no_mangle]
pub extern "C" fn copy_get_progress(
    context: *mut CopyContext,
    bytes_copied: *mut usize,
    total_bytes: *mut usize,
    files_processed: *mut usize,
    total_files: *mut usize,
) {
    if context.is_null() {
        return;
    }

    let ctx = unsafe { &*context };
    
    if !bytes_copied.is_null() {
        unsafe { *bytes_copied = ctx.bytes_copied; }
    }
    if !total_bytes.is_null() {
        unsafe { *total_bytes = ctx.total_bytes; }
    }
    if !files_processed.is_null() {
        unsafe { *files_processed = ctx.files_processed; }
    }
    if !total_files.is_null() {
        unsafe { *total_files = ctx.total_files; }
    }
}

/// Create a directory recursively
///
/// # Arguments
/// * `path` - Path to create
///
/// # Returns
/// 0 on success, error code on failure
#[no_mangle]
pub extern "C" fn create_directory(path: *const c_char) -> i32 {
    if path.is_null() {
        return ERROR_NULL_POINTER;
    }

    let path = match unsafe { c_str_to_path(path) } {
        Ok(p) => p,
        Err(_) => return ERROR_INVALID_PATH,
    };

    if let Err(_) = DirBuilder::new().recursive(true).create(&path) {
        return ERROR_PERMISSION_DENIED;
    }

    SUCCESS
}

/// Check if path exists
///
/// # Arguments
/// * `path` - Path to check
///
/// # Returns
/// 1 if exists, 0 if not
#[no_mangle]
pub extern "C" fn path_exists(path: *const c_char) -> i32 {
    if path.is_null() {
        return 0;
    }

    let path = match unsafe { c_str_to_path(path) } {
        Ok(p) => p,
        Err(_) => return 0,
    };

    if path.exists() {
        return 1;
    } else {
        return 0;
    }
}

/// Get file size
///
/// # Arguments
/// * `path` - File path
///
/// # Returns
/// File size in bytes, or 0 if not found or not a file
#[no_mangle]
pub extern "C" fn get_file_size(path: *const c_char) -> usize {
    if path.is_null() {
        return 0;
    }

    let path = match unsafe { c_str_to_path(path) } {
        Ok(p) => p,
        Err(_) => return 0,
    };

    if path.is_file() {
        if let Ok(metadata) = path.metadata() {
            return metadata.len() as usize;
        }
    }

    0
}

// ============================================================================
// CHUNKED STREAMING COPY FOR CROSS-ACCOUNT TRANSFER
// ============================================================================

/// Chunked streaming copy context
#[repr(C)]
pub struct ChunkedCopyContext {
    source_file: Option<File>,
    dest_file: Option<File>,
    source_path: PathBuf,
    dest_path: PathBuf,
    chunk_size: usize,
    bytes_copied: usize,
    total_bytes: usize,
    cancel_flag: *const AtomicBool,
    progress_throttler: ProgressThrottler,
    is_open: bool,
}

impl ChunkedCopyContext {
    pub fn new(source_path: PathBuf, dest_path: PathBuf, chunk_size: usize, 
               total_bytes: usize, cancel_flag: *const AtomicBool) -> Self {
        Self {
            source_file: None,
            dest_file: None,
            source_path,
            dest_path,
            chunk_size,
            bytes_copied: 0,
            total_bytes,
            cancel_flag,
            progress_throttler: ProgressThrottler::new(500),
            is_open: false,
        }
    }
}

/// Initialize chunked streaming copy
///
/// # Arguments
/// * `source_path` - Source file path
/// * `dest_path` - Destination file path
/// * `chunk_size` - Size of chunks in bytes (10MB recommended for cross-account)
/// * `cancel_flag` - Cancellation flag
///
/// # Returns
/// Pointer to ChunkedCopyContext, or null on error
#[no_mangle]
pub extern "C" fn chunked_copy_init(
    source_path: *const c_char,
    dest_path: *const c_char,
    chunk_size: usize,
    cancel_flag: *const AtomicBool,
) -> *mut ChunkedCopyContext {
    eprintln!("[RUST] 🔧 chunked_copy_init: starting for source={:?}, dest={:?}, chunk_size={}",
        unsafe { c_str_to_path(source_path) }.ok().map(|p| p.to_string_lossy().to_string()),
        unsafe { c_str_to_path(dest_path) }.ok().map(|p| p.to_string_lossy().to_string()),
        chunk_size);

    if source_path.is_null() || dest_path.is_null() {
        eprintln!("[RUST] ❌ chunked_copy_init: null pointer provided");
        return ptr::null_mut();
    }

    let src = match unsafe { c_str_to_path(source_path) } {
        Ok(p) => p,
        Err(_) => return ptr::null_mut(),
    };

    let dst = match unsafe { c_str_to_path(dest_path) } {
        Ok(p) => p,
        Err(_) => return ptr::null_mut(),
    };

    // Get source file size
    let metadata = match src.metadata() {
        Ok(m) => m,
        Err(_) => return ptr::null_mut(),
    };

    if !metadata.is_file() {
        return ptr::null_mut();
    }

    let total_bytes = metadata.len() as usize;
    let chunk_size = chunk_size.max(64 * 1024).min(10 * 1024 * 1024);

    let context = Box::new(ChunkedCopyContext::new(
        src, dst, chunk_size, total_bytes, cancel_flag,
    ));

    Box::leak(context) as *mut ChunkedCopyContext
}

/// Open source file for chunked copy
///
/// # Arguments
/// * `context` - Pointer to ChunkedCopyContext
///
/// # Returns
/// 0 on success, negative error code on failure
#[no_mangle]
pub extern "C" fn chunked_copy_open_source(context: *mut ChunkedCopyContext) -> i32 {
    if context.is_null() {
        eprintln!("[RUST] ❌ chunked_copy_open_source: null context");
        return ERROR_NULL_POINTER;
    }

    let ctx = unsafe { &mut *context };

    let src_file = match File::open(&ctx.source_path) {
        Ok(f) => f,
        Err(e) => {
            eprintln!("[RUST] ❌ chunked_copy_open_source: failed to open source: {}", e);
            return ERROR_FILE_NOT_FOUND;
        }
    };

    ctx.source_file = Some(src_file);
    ctx.is_open = true;
    
    eprintln!("[RUST] 🔧 chunked_copy_open_source: opened source file successfully");

    SUCCESS
}

/// Read next chunk from source file
///
/// # Arguments
/// * `context` - Pointer to ChunkedCopyContext
/// * `buffer` - Buffer to write chunk data
/// * `buffer_size` - Size of buffer
/// * `data_callback` - Callback to receive chunk data (returns bytes written to buffer)
/// * `user_data` - User data for callback
///
/// # Returns
/// Number of bytes read (0 for EOF), negative error code on failure
#[no_mangle]
pub extern "C" fn chunked_copy_read_chunk(
    context: *mut ChunkedCopyContext,
    buffer: *mut u8,
    buffer_size: usize,
    data_callback: Option<CopyDataCallback>,
    user_data: *mut c_void,
) -> isize {
    if context.is_null() || buffer.is_null() {
        return ERROR_NULL_POINTER as isize;
    }

    let ctx = unsafe { &mut *context };

    // Check cancellation
    if unsafe { is_cancelled(ctx.cancel_flag) } {
        return ERROR_CANCELLED as isize;
    }

    let file = match &mut ctx.source_file {
        Some(f) => f,
        None => return ERROR_FILE_NOT_FOUND as isize,
    };

    // Read into buffer
    let buffer_slice = unsafe { slice::from_raw_parts_mut(buffer, buffer_size) };
    
    match file.read(buffer_slice) {
        Ok(0) => 0, // EOF
        Ok(n) => {
            ctx.bytes_copied += n;
            
            // Call data callback if provided
            if let Some(cb) = data_callback {
                let written = cb(buffer, n, user_data);
                if written < 0 {
                    return written; // Error from callback
                }
            }

            n as isize
        }
        Err(_) => ERROR_IO_FAILED as isize,
    }
}

/// Write chunk to destination file
///
/// # Arguments
/// * `context` - Pointer to ChunkedCopyContext
/// * `data` - Pointer to data to write
/// * `data_len` - Length of data
/// * `progress_callback` - Optional progress callback
/// * `user_data` - User data for callbacks
///
/// # Returns
/// 0 on success, negative error code on failure
#[no_mangle]
pub extern "C" fn chunked_copy_write_chunk(
    context: *mut ChunkedCopyContext,
    data: *const u8,
    data_len: usize,
    progress_callback: Option<CopyProgressCallback>,
    user_data: *mut c_void,
) -> i32 {
    if context.is_null() || data.is_null() {
        eprintln!("[RUST] ❌ chunked_copy_write_chunk: null pointer");
        return ERROR_NULL_POINTER;
    }

    let ctx = unsafe { &mut *context };

    // Check cancellation
    if unsafe { is_cancelled(ctx.cancel_flag) } {
        return ERROR_CANCELLED;
    }

    // Open destination file on first write
    if ctx.dest_file.is_none() {
        let dst_file = match File::create(&ctx.dest_path) {
            Ok(f) => f,
            Err(_) => return ERROR_PERMISSION_DENIED,
        };
        ctx.dest_file = Some(dst_file);
    }

    let file = ctx.dest_file.as_mut().unwrap();
    let data_slice = unsafe { slice::from_raw_parts(data, data_len) };

    match file.write_all(data_slice) {
        Ok(_) => {}
        Err(_) => return ERROR_IO_FAILED,
    }

    // Progress callback
    if let Some(cb) = progress_callback {
        if ctx.progress_throttler.should_update(ctx.bytes_copied, ctx.total_bytes) {
            cb(ctx.bytes_copied, ctx.total_bytes, 1, 1, user_data);
        }
    }

    SUCCESS
}

/// Flush destination file
///
/// # Arguments
/// * `context` - Pointer to ChunkedCopyContext
///
/// # Returns
/// 0 on success, negative error code on failure
#[no_mangle]
pub extern "C" fn chunked_copy_flush(context: *mut ChunkedCopyContext) -> i32 {
    if context.is_null() {
        return ERROR_NULL_POINTER;
    }

    let ctx = unsafe { &mut *context };

    if let Some(ref mut file) = ctx.dest_file {
        if let Err(_) = file.flush() {
            return ERROR_IO_FAILED;
        }
    }

    SUCCESS
}

/// Close and finalize chunked copy
///
/// # Arguments
/// * `context` - Pointer to ChunkedCopyContext
/// * `progress_callback` - Optional final progress callback
/// * `user_data` - User data for callback
///
/// # Returns
/// 0 on success, negative error code on failure
#[no_mangle]
pub extern "C" fn chunked_copy_finalize(
    context: *mut ChunkedCopyContext,
    progress_callback: Option<CopyProgressCallback>,
    user_data: *mut c_void,
) -> i32 {
    if context.is_null() {
        return ERROR_NULL_POINTER;
    }

    let ctx = unsafe { &mut *context };

    // Final progress update
    if let Some(cb) = progress_callback {
        cb(ctx.bytes_copied, ctx.total_bytes, 1, 1, user_data);
    }

    // Flush destination
    if let Some(ref mut file) = ctx.dest_file {
        if let Err(_) = file.flush() {
            return ERROR_IO_FAILED;
        }
    }

    ctx.is_open = false;
    SUCCESS
}

/// Free chunked copy context
///
/// # Arguments
/// * `context` - Pointer to ChunkedCopyContext
#[no_mangle]
pub extern "C" fn chunked_copy_free(context: *mut ChunkedCopyContext) {
    if !context.is_null() {
        unsafe {
            let _ = Box::from_raw(context);
        }
    }
}

/// Get chunked copy progress
///
/// # Arguments
/// * `context` - Pointer to ChunkedCopyContext
/// * `bytes_copied` - Pointer to store bytes copied
/// * `total_bytes` - Pointer to store total bytes
#[no_mangle]
pub extern "C" fn chunked_copy_get_progress(
    context: *mut ChunkedCopyContext,
    bytes_copied: *mut usize,
    total_bytes: *mut usize,
) {
    if context.is_null() {
        return;
    }

    let ctx = unsafe { &*context };
    
    if !bytes_copied.is_null() {
        unsafe { *bytes_copied = ctx.bytes_copied; }
    }
    if !total_bytes.is_null() {
        unsafe { *total_bytes = ctx.total_bytes; }
    }
}

// ============================================================================
// CLOUD-TO-CLOUD STREAMING COPY (Rust-orchestrated)
// ============================================================================

/// Context for cloud-to-cloud streaming copy
#[repr(C)]
pub struct CloudCopyContext {
    chunk_size: usize,
    bytes_copied: usize,
    total_bytes: usize,
    cancel_flag: *const AtomicBool,
    progress_throttler: ProgressThrottler,
}

impl CloudCopyContext {
    pub fn new(chunk_size: usize, total_bytes: usize, cancel_flag: *const AtomicBool) -> Self {
        Self {
            chunk_size,
            bytes_copied: 0,
            total_bytes,
            cancel_flag,
            progress_throttler: ProgressThrottler::new(500),
        }
    }
}

/// Initialize cloud-to-cloud streaming copy context
///
/// This function creates a context for Rust-orchestrated cloud copy operations.
/// Dart provides read/write callbacks, Rust handles the streaming loop.
///
/// # Arguments
/// * `chunk_size` - Size of chunks in bytes (10MB recommended)
/// * `total_bytes` - Total bytes to transfer (0 if unknown)
/// * `cancel_flag` - Cancellation flag
///
/// # Returns
/// Pointer to CloudCopyContext, or null on error
#[no_mangle]
pub extern "C" fn cloud_copy_init(
    chunk_size: usize,
    total_bytes: usize,
    cancel_flag: *const AtomicBool,
) -> *mut CloudCopyContext {
    eprintln!("[RUST] 🔧 cloud_copy_init: chunk_size={}, total_bytes={}", chunk_size, total_bytes);
    
    if cancel_flag.is_null() {
        return ptr::null_mut();
    }
    
    let chunk_size = chunk_size.max(64 * 1024).min(10 * 1024 * 1024);
    
    let context = Box::new(CloudCopyContext::new(
        chunk_size,
        total_bytes,
        cancel_flag,
    ));
    
    Box::leak(context) as *mut CloudCopyContext
}

/// Read callback type for cloud copy
pub type CloudCopyReadCallback = extern "C" fn(buffer: *mut u8, buffer_size: usize, user_data: *mut c_void) -> isize;

/// Write callback type for cloud copy
pub type CloudCopyWriteCallback = extern "C" fn(data: *const u8, data_len: usize, user_data: *mut c_void) -> i32;

/// Execute one chunk of cloud-to-cloud copy
///
/// Rust orchestrates: read from source → write to dest
///
/// # Arguments
/// * `context` - Pointer to CloudCopyContext
/// * `read_buffer` - Buffer for read operation
/// * `buffer_size` - Size of read buffer
/// * `read_callback` - Callback to read data from source
/// * `write_callback` - Callback to write data to destination
/// * `user_data` - User data for callbacks
///
/// # Returns
/// Number of bytes processed (0 for EOF), negative error code on failure
#[no_mangle]
pub extern "C" fn cloud_copy_process_chunk(
    context: *mut CloudCopyContext,
    read_buffer: *mut u8,
    buffer_size: usize,
    read_callback: Option<CloudCopyReadCallback>,
    write_callback: Option<CloudCopyWriteCallback>,
    user_data: *mut c_void,
) -> isize {
    if context.is_null() || read_buffer.is_null() {
        eprintln!("[RUST] ❌ cloud_copy_process_chunk: null pointer");
        return ERROR_NULL_POINTER as isize;
    }
    
    let ctx = unsafe { &mut *context };
    
    // Check cancellation
    if unsafe { is_cancelled(ctx.cancel_flag) } {
        eprintln!("[RUST] ❌ cloud_copy_process_chunk: cancelled");
        return ERROR_CANCELLED as isize;
    }
    
    let read_cb = match read_callback {
        Some(cb) => cb,
        None => return ERROR_NULL_POINTER as isize,
    };
    
    let write_cb = match write_callback {
        Some(cb) => cb,
        None => return ERROR_NULL_POINTER as isize,
    };
    
    // Read chunk from source
    let bytes_read = read_cb(read_buffer, buffer_size, user_data);
    
    if bytes_read < 0 {
        eprintln!("[RUST] ❌ cloud_copy_process_chunk: read error {}", bytes_read);
        return bytes_read; // Error from read callback
    }
    
    if bytes_read == 0 {
        // EOF - return 0 to indicate done
        eprintln!("[RUST] 📊 cloud_copy_process_chunk: EOF reached, bytes_copied={}", ctx.bytes_copied);
        return 0;
    }
    
    // Write chunk to destination
    let write_result = write_cb(read_buffer, bytes_read as usize, user_data);
    
    if write_result < 0 {
        eprintln!("[RUST] ❌ cloud_copy_process_chunk: write error {}", write_result);
        return write_result as isize;
    }
    
    ctx.bytes_copied += bytes_read as usize;
    
    // Progress callback via stderr (Dart handles UI updates separately)
    if ctx.progress_throttler.should_update(ctx.bytes_copied, ctx.total_bytes.max(ctx.bytes_copied)) {
        eprintln!("[RUST] 📊 cloud_copy_progress: {}/{} bytes ({:.1}%)",
            ctx.bytes_copied,
            ctx.total_bytes.max(ctx.bytes_copied),
            if ctx.total_bytes > 0 { (ctx.bytes_copied as f64 / ctx.total_bytes as f64 * 100.0).min(100.0) } else { 0.0 });
    }
    
    bytes_read
}

/// Finalize cloud-to-cloud copy
///
/// # Arguments
/// * `context` - Pointer to CloudCopyContext
///
/// # Returns
/// 0 on success, error code on failure
#[no_mangle]
pub extern "C" fn cloud_copy_finalize(context: *mut CloudCopyContext) -> i32 {
    if context.is_null() {
        return ERROR_NULL_POINTER;
    }
    
    let ctx = unsafe { &mut *context };
    
    eprintln!("[RUST] ✅ cloud_copy_finalize: total bytes copied={}", ctx.bytes_copied);
    
    SUCCESS
}

/// Free cloud copy context
#[no_mangle]
pub extern "C" fn cloud_copy_free(context: *mut CloudCopyContext) {
    if !context.is_null() {
        eprintln!("[RUST] 🗑️ cloud_copy_free: freeing context");
        unsafe {
            let _ = Box::from_raw(context);
        }
    }
}

/// Get cloud copy progress
#[no_mangle]
pub extern "C" fn cloud_copy_get_progress(
    context: *mut CloudCopyContext,
    bytes_copied: *mut usize,
    total_bytes: *mut usize,
) {
    if context.is_null() {
        return;
    }
    
    let ctx = unsafe { &*context };
    
    if !bytes_copied.is_null() {
        unsafe { *bytes_copied = ctx.bytes_copied; }
    }
    if !total_bytes.is_null() {
        unsafe { *total_bytes = ctx.total_bytes; }
    }
}