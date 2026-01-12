/// Download operations for CloudNexus
/// Handles streaming file downloads with optional decryption and progress reporting
use std::fs::File;
use std::io::{Write, BufWriter};
use std::path::PathBuf;
use std::sync::atomic::AtomicBool;
use std::ffi::{c_char, c_void, CStr};
use std::ptr;
use std::slice;

use crate::file_io::{ProgressThrottler, ERROR_NULL_POINTER, ERROR_FILE_NOT_FOUND,
                     ERROR_PERMISSION_DENIED, ERROR_IO_FAILED, ERROR_CANCELLED,
                     ERROR_INVALID_PATH, ERROR_DISK_FULL, SUCCESS, c_str_to_path, is_cancelled};
use crate::{DecryptionContext, decrypt_chunk, decrypt_file_init, decrypt_file_finalize};

/// Progress callback for download operations
pub type DownloadProgressCallback = extern "C" fn(bytes_written: usize, total_bytes: usize, user_data: *mut c_void);

/// Download context for streaming operations
#[repr(C)]
pub struct DownloadContext {
    output_file: *mut BufWriter<File>,
    file_path: PathBuf,
    decryption_context: Option<*mut DecryptionContext>,
    master_key: Vec<u8>,
    bytes_written: usize,
    total_bytes: usize,
    should_decrypt: bool,
    cancel_flag: *const AtomicBool,
    progress_throttler: ProgressThrottler,
    is_finalized: bool,
    header_written: bool,
}

impl DownloadContext {
    pub fn new(file_path: PathBuf, total_bytes: usize, should_decrypt: bool,
               master_key: Vec<u8>, cancel_flag: *const AtomicBool) -> Self {
        Self {
            output_file: ptr::null_mut(),
            file_path,
            decryption_context: None,
            master_key,
            bytes_written: 0,
            total_bytes,
            should_decrypt,
            cancel_flag,
            progress_throttler: ProgressThrottler::new(500),
            is_finalized: false,
            header_written: false,
        }
    }
}

/// Initialize download context
///
/// # Arguments
/// * `local_file_path` - Path where the downloaded file will be saved
/// * `master_key` - Pointer to 32-byte master decryption key (can be null for no decryption)
/// * `master_key_len` - Length of master key (must be 0 or 32)
/// * `should_decrypt` - 1 if decryption should be used, 0 otherwise
/// * `progress_callback` - Optional progress callback
/// * `cancel_flag` - Pointer to atomic bool for cancellation
/// * `user_data` - User data pointer passed to callbacks
///
/// # Returns
/// Pointer to DownloadContext, or null on error
#[no_mangle]
pub extern "C" fn download_init(
    local_file_path: *const c_char,
    master_key: *const u8,
    master_key_len: usize,
    should_decrypt: i32,
    progress_callback: Option<DownloadProgressCallback>,
    cancel_flag: *const AtomicBool,
    user_data: *mut c_void,
) -> *mut DownloadContext {
    if local_file_path.is_null() {
        return ptr::null_mut();
    }

    // Convert path
    let path = match unsafe { c_str_to_path(local_file_path) } {
        Ok(p) => p,
        Err(e) => return ptr::null_mut(),
    };

    // Create output file
    let file = match File::create(&path) {
        Ok(f) => f,
        Err(_) => return ptr::null_mut(),
    };

    // Get master key
    let key = if !master_key.is_null() && master_key_len == 32 {
        unsafe { slice::from_raw_parts(master_key, 32).to_vec() }
    } else {
        Vec::new()
    };

    // Create context
    let context = Box::new(DownloadContext::new(
        path,
        0, // Unknown total bytes initially
        should_decrypt == 1,
        key,
        cancel_flag,
    ));

    Box::leak(context) as *mut DownloadContext
}

/// Initialize download with known total size
#[no_mangle]
pub extern "C" fn download_init_with_size(
    local_file_path: *const c_char,
    total_bytes: usize,
    master_key: *const u8,
    master_key_len: usize,
    should_decrypt: i32,
    progress_callback: Option<DownloadProgressCallback>,
    cancel_flag: *const AtomicBool,
    user_data: *mut c_void,
) -> *mut DownloadContext {
    let context = download_init(
        local_file_path,
        master_key,
        master_key_len,
        should_decrypt,
        progress_callback,
        cancel_flag,
        user_data,
    );

    if !context.is_null() {
        unsafe { (&mut *context).total_bytes = total_bytes; }
    }

    context
}

/// Append encrypted chunk to download stream
/// Decrypts if needed and writes to file
///
/// # Arguments
/// * `context` - Pointer to DownloadContext
/// * `encrypted_data` - Pointer to encrypted chunk data
/// * `data_len` - Length of encrypted data
/// * `progress_callback` - Progress callback
/// * `user_data` - User data
///
/// # Returns
/// 0 on success, error code on failure
#[no_mangle]
pub extern "C" fn download_append_chunk(
    context: *mut DownloadContext,
    encrypted_data: *const u8,
    data_len: usize,
    progress_callback: Option<DownloadProgressCallback>,
    user_data: *mut c_void,
) -> i32 {
    if context.is_null() {
        return ERROR_NULL_POINTER;
    }

    let ctx = unsafe { &mut *context };

    // Check cancellation
    if unsafe { is_cancelled(ctx.cancel_flag) } {
        return ERROR_CANCELLED;
    }

    // Open file on first call
    if ctx.output_file.is_null() {
        let file = match File::create(&ctx.file_path) {
            Ok(f) => f,
            Err(_) => return ERROR_PERMISSION_DENIED,
        };
        ctx.output_file = Box::into_raw(Box::new(BufWriter::new(file)));
    }

    let encrypted_slice = unsafe { slice::from_raw_parts(encrypted_data, data_len) };

    // Initialize decryption on first chunk if needed
    if ctx.should_decrypt && ctx.decryption_context.is_none() && !ctx.master_key.is_empty() {
        // First chunk should contain header + wrapped FEK + first encrypted chunk
        // We need at least 12 bytes for header + wrapped FEK length
        if data_len < 12 {
            return ERROR_INVALID_PATH;
        }

        // Parse header to get wrapped FEK length
        let fek_len = u32::from_le_bytes([
            encrypted_slice[8],
            encrypted_slice[9],
            encrypted_slice[10],
            encrypted_slice[11],
        ]) as usize;

        // We need header + wrapped FEK for decryption init
        if data_len < 12 + fek_len {
            return ERROR_INVALID_PATH;
        }

        // Initialize decryption with header + wrapped FEK
        let dec_ctx = unsafe {
            decrypt_file_init(
                encrypted_data,
                12 + fek_len,
                ctx.master_key.as_ptr(),
                ctx.master_key.len(),
            )
        };

        if dec_ctx.is_null() {
            return ERROR_IO_FAILED;
        }

        ctx.decryption_context = Some(dec_ctx);

        // Write header and wrapped FEK to file
        let writer = unsafe { &mut *ctx.output_file };
        let header_and_fek = unsafe { slice::from_raw_parts(encrypted_data, 12 + fek_len) };
        if let Err(_) = writer.write_all(header_and_fek) {
            return ERROR_IO_FAILED;
        }

        ctx.header_written = true;
        ctx.bytes_written = 12 + fek_len;

        // Decrypt and write the first data chunk if present
        let data_start = 12 + fek_len;
        if data_len > data_start {
            let first_chunk = &encrypted_slice[data_start..];
            let decrypted = unsafe {
                decrypt_chunk(
                    dec_ctx,
                    first_chunk.as_ptr(),
                    first_chunk.len(),
                    &data_len as *const usize as *mut usize,
                )
            };

            if decrypted.is_null() {
                return ERROR_IO_FAILED;
            }

            let decrypted_size = unsafe { *(&data_len as *const usize as *const usize) };
            let writer = unsafe { &mut *ctx.output_file };
            let decrypted_data = unsafe { slice::from_raw_parts(decrypted, decrypted_size) };
            if let Err(_) = writer.write_all(decrypted_data) {
                unsafe { libc::free(decrypted as *mut c_void); }
                return ERROR_IO_FAILED;
            }
    
            unsafe { libc::free(decrypted as *mut c_void); }
            ctx.bytes_written += decrypted_size;
        }

        // Progress callback
        if let Some(cb) = progress_callback {
            if ctx.progress_throttler.should_update(ctx.bytes_written, ctx.total_bytes) {
                cb(ctx.bytes_written, ctx.total_bytes, user_data);
            }
        }

        return SUCCESS;
    }

    // Normal chunk processing (not first chunk, or no decryption)
    if ctx.should_decrypt && ctx.decryption_context.is_some() {
        // Decrypt chunk
        let dec_ctx = ctx.decryption_context.unwrap();
        let output_len: usize = 0;
        let decrypted = unsafe {
            decrypt_chunk(
                dec_ctx,
                encrypted_data,
                data_len,
                &output_len as *const usize as *mut usize,
            )
        };

        if decrypted.is_null() {
            return ERROR_IO_FAILED;
        }

        let decrypted_size = unsafe { *(&output_len as *const usize as *const usize) };

        // Write to file
        let writer = unsafe { &mut *ctx.output_file };
        let decrypted_slice = unsafe { std::slice::from_raw_parts(decrypted, decrypted_size) };
        if let Err(_) = writer.write_all(decrypted_slice) {
            unsafe { libc::free(decrypted as *mut c_void); }
            return ERROR_IO_FAILED;
        }

        unsafe { libc::free(decrypted as *mut c_void); }
        ctx.bytes_written += decrypted_size;
    } else {
        // No decryption - write raw data
        let writer = unsafe { &mut *ctx.output_file };
        if let Err(_) = writer.write_all(encrypted_slice) {
            return ERROR_IO_FAILED;
        }
        ctx.bytes_written += data_len;
    }

    // Progress callback
    if let Some(cb) = progress_callback {
        if ctx.progress_throttler.should_update(ctx.bytes_written, ctx.total_bytes) {
            cb(ctx.bytes_written, ctx.total_bytes, user_data);
        }
    }

    SUCCESS
}

/// Append decrypted data directly (bypasses decryption in Rust)
/// Use this when decryption is handled elsewhere
///
/// # Arguments
/// * `context` - Pointer to DownloadContext
/// * `data` - Pointer to data
/// * `data_len` - Length of data
/// * `progress_callback` - Progress callback
/// * `user_data` - User data
///
/// # Returns
/// 0 on success, error code on failure
#[no_mangle]
pub extern "C" fn download_append_decrypted(
    context: *mut DownloadContext,
    data: *const u8,
    data_len: usize,
    progress_callback: Option<DownloadProgressCallback>,
    user_data: *mut c_void,
) -> i32 {
    if context.is_null() {
        return ERROR_NULL_POINTER;
    }

    let ctx = unsafe { &mut *context };

    // Check cancellation
    if unsafe { is_cancelled(ctx.cancel_flag) } {
        return ERROR_CANCELLED;
    }

    // Open file on first call
    if ctx.output_file.is_null() {
        let file = match File::create(&ctx.file_path) {
            Ok(f) => f,
            Err(_) => return ERROR_PERMISSION_DENIED,
        };
        ctx.output_file = Box::into_raw(Box::new(BufWriter::new(file)));
    }

    let data_slice = unsafe { slice::from_raw_parts(data, data_len) };

    // Write to file
    let writer = unsafe { &mut *ctx.output_file };
    if let Err(_) = writer.write_all(data_slice) {
        return ERROR_IO_FAILED;
    }

    ctx.bytes_written += data_len;

    // Progress callback
    if let Some(cb) = progress_callback {
        if ctx.progress_throttler.should_update(ctx.bytes_written, ctx.total_bytes) {
            cb(ctx.bytes_written, ctx.total_bytes, user_data);
        }
    }

    SUCCESS
}

/// Finalize download and clean up resources
///
/// # Arguments
/// * `context` - Pointer to DownloadContext
///
/// # Returns
/// 0 on success, error code on failure
#[no_mangle]
pub extern "C" fn download_finalize(context: *mut DownloadContext) -> i32 {
    if context.is_null() {
        return ERROR_NULL_POINTER;
    }

    let ctx = unsafe { &mut *context };

    // Finalize decryption context
    if let Some(dec_ctx) = ctx.decryption_context {
        unsafe { decrypt_file_finalize(dec_ctx); }
    }

    // Close and flush file
    if !ctx.output_file.is_null() {
        let writer = unsafe { &mut *ctx.output_file };
        if let Err(_) = writer.flush() {
            return ERROR_IO_FAILED;
        }
        unsafe {
            let _ = Box::from_raw(ctx.output_file);
        }
        ctx.output_file = ptr::null_mut();
    }

    ctx.is_finalized = true;

    SUCCESS
}

/// Free download context
///
/// # Arguments
/// * `context` - Pointer to DownloadContext to free
#[no_mangle]
pub extern "C" fn download_free(context: *mut DownloadContext) {
    if !context.is_null() {
        unsafe {
            // Finalize first if not done
            if !context.is_null() {
                let ctx = &mut *context;
                if !ctx.is_finalized {
                    if let Some(dec_ctx) = ctx.decryption_context {
                        decrypt_file_finalize(dec_ctx);
                    }
                    if !ctx.output_file.is_null() {
                        let writer = &mut *ctx.output_file;
                        let _ = writer.flush();
                        let _ = Box::from_raw(ctx.output_file);
                    }
                }
            }
            let _ = Box::from_raw(context);
        }
    }
}

/// Get bytes written for download
///
/// # Arguments
/// * `context` - Pointer to DownloadContext
///
/// # Returns
/// Bytes written, or 0 if invalid
#[no_mangle]
pub extern "C" fn download_get_bytes_written(context: *mut DownloadContext) -> usize {
    if context.is_null() {
        return 0;
    }
    unsafe { (&*context).bytes_written }
}

/// Get total bytes for download
///
/// # Arguments
/// * `context` - Pointer to DownloadContext
///
/// # Returns
/// Total bytes, or 0 if unknown
#[no_mangle]
pub extern "C" fn download_get_total_bytes(context: *mut DownloadContext) -> usize {
    if context.is_null() {
        return 0;
    }
    unsafe { (&*context).total_bytes }
}

/// Set total bytes for download (for progress tracking)
///
/// # Arguments
/// * `context` - Pointer to DownloadContext
/// * `total_bytes` - Total bytes expected
#[no_mangle]
pub extern "C" fn download_set_total_bytes(context: *mut DownloadContext, total_bytes: usize) {
    if !context.is_null() {
        unsafe { (&mut *context).total_bytes = total_bytes; }
    }
}