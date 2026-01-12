/// Upload operations for CloudNexus
/// Handles streaming file uploads with optional encryption and progress reporting
use std::fs::File;
use std::io::{Read, Write, BufReader, BufWriter};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::ffi::{c_char, c_void, CStr};
use std::ptr;
use std::slice;

use crate::file_io::{ProgressThrottler, ERROR_NULL_POINTER, ERROR_FILE_NOT_FOUND,
                     ERROR_PERMISSION_DENIED, ERROR_IO_FAILED, ERROR_CANCELLED,
                     ERROR_INVALID_PATH, SUCCESS, c_str_to_path, is_cancelled, string_to_c_char};
use crate::{EncryptionContext, encrypt_chunk, encrypt_file_init,
                        encrypt_file_get_wrapped_fek, encrypt_file_finalize, MAGIC, VERSION};

/// Progress callback for upload operations
pub type UploadProgressCallback = extern "C" fn(bytes_processed: usize, total_bytes: usize, user_data: *mut c_void);

/// Data callback for providing encrypted chunks to Dart
/// Parameters: encrypted_data pointer, data length, chunk index, user_data pointer
pub type UploadDataCallback = extern "C" fn(data: *const u8, data_len: usize, chunk_index: u32, user_data: *mut c_void);

/// Upload context for streaming operations
#[repr(C)]
pub struct UploadContext {
    input_file: *mut BufReader<File>,
    file_path: PathBuf,
    encryption_context: Option<*mut EncryptionContext>,
    master_key: Vec<u8>,
    bytes_read: usize,
    total_bytes: usize,
    chunk_index: u32,
    should_encrypt: bool,
    cancel_flag: *const AtomicBool,
    progress_throttler: ProgressThrottler,
    is_finalized: bool,
}

impl UploadContext {
    pub fn new(file_path: PathBuf, total_bytes: usize, should_encrypt: bool, 
               master_key: Vec<u8>, cancel_flag: *const AtomicBool) -> Self {
        Self {
            input_file: ptr::null_mut(),
            file_path,
            encryption_context: None,
            master_key,
            bytes_read: 0,
            total_bytes,
            chunk_index: 0,
            should_encrypt,
            cancel_flag,
            progress_throttler: ProgressThrottler::new(500), // 500ms interval
            is_finalized: false,
        }
    }
}

/// Initialize upload context
///
/// # Arguments
/// * `local_file_path` - Path to the local file to upload
/// * `master_key` - Pointer to 32-byte master encryption key (can be null for no encryption)
/// * `master_key_len` - Length of master key (must be 0 or 32)
/// * `chunk_size` - Size of chunks in bytes
/// * `should_encrypt` - 1 if encryption should be used, 0 otherwise
/// * `progress_callback` - Optional progress callback
/// * `data_callback` - Callback for receiving encrypted data chunks
/// * `cancel_flag` - Pointer to atomic bool for cancellation
/// * `user_data` - User data pointer passed to callbacks
///
/// # Returns
/// Pointer to UploadContext, or null on error
#[no_mangle]
pub extern "C" fn upload_init(
    local_file_path: *const c_char,
    master_key: *const u8,
    master_key_len: usize,
    chunk_size: usize,
    should_encrypt: i32,
    progress_callback: Option<UploadProgressCallback>,
    data_callback: Option<UploadDataCallback>,
    cancel_flag: *const AtomicBool,
    user_data: *mut c_void,
) -> *mut UploadContext {
    if local_file_path.is_null() {
        return ptr::null_mut();
    }

    // Convert path
    let path = match unsafe { c_str_to_path(local_file_path) } {
        Ok(p) => p,
        Err(e) => return ptr::null_mut(),
    };

    // Open file
    let file = match File::open(&path) {
        Ok(f) => f,
        Err(_) => return ptr::null_mut(),
    };

    // Get file size
    let metadata = match file.metadata() {
        Ok(m) => m,
        Err(_) => return ptr::null_mut(),
    };
    let total_bytes = metadata.len() as usize;

    // Get master key
    let key = if !master_key.is_null() && master_key_len == 32 {
        unsafe { slice::from_raw_parts(master_key, 32).to_vec() }
    } else {
        Vec::new()
    };

    // Create context
    let context = Box::new(UploadContext::new(
        path,
        total_bytes,
        should_encrypt == 1,
        key,
        cancel_flag,
    ));

    Box::leak(context) as *mut UploadContext
}

/// Process next chunk of upload
/// Reads from file, optionally encrypts, and calls data callback
///
/// # Arguments
/// * `context` - Pointer to UploadContext
/// * `buffer` - Buffer to store encrypted chunk data
/// * `buffer_size` - Size of buffer
/// * `progress_callback` - Progress callback
/// * `data_callback` - Data callback
/// * `user_data` - User data
///
/// # Returns
/// Number of bytes in chunk (0 if done), or negative error code
#[no_mangle]
pub extern "C" fn upload_process_chunk(
    context: *mut UploadContext,
    buffer: *mut u8,
    buffer_size: usize,
    progress_callback: Option<UploadProgressCallback>,
    data_callback: Option<UploadDataCallback>,
    user_data: *mut c_void,
) -> isize {
    if context.is_null() {
        return ERROR_NULL_POINTER as isize;
    }

    let ctx = unsafe { &mut *context };

    // Check if already done
    if ctx.bytes_read >= ctx.total_bytes {
        return 0;
    }

    // Check cancellation
    if unsafe { is_cancelled(ctx.cancel_flag) } {
        return ERROR_CANCELLED as isize;
    }

    // Open file on first call
    if ctx.input_file.is_null() {
        let file = match File::open(&ctx.file_path) {
            Ok(f) => f,
            Err(_) => return ERROR_IO_FAILED as isize,
        };
        ctx.input_file = Box::into_raw(Box::new(BufReader::new(file)));
    }

    // Determine chunk size
    let chunk_size = (ctx.total_bytes - ctx.bytes_read).min(1024 * 1024); // 1MB default

    // Read chunk from file
    let mut chunk_data = vec![0u8; chunk_size];
    let reader = unsafe { &mut *ctx.input_file };
    
    match reader.read(&mut chunk_data) {
        Ok(0) => return 0, // EOF
        Ok(n) if n < chunk_size => {
            chunk_data.truncate(n);
        }
        Ok(_) => {}
        Err(_) => return ERROR_IO_FAILED as isize,
    }

    let actual_size = chunk_data.len();
    let mut encrypted_data = chunk_data;
    let mut chunk_index = ctx.chunk_index;

    // Encrypt if needed
    if ctx.should_encrypt && !ctx.master_key.is_empty() {
        // Initialize encryption on first chunk
        if ctx.encryption_context.is_none() {
            let output_len: usize = 0;
            let enc_ctx = unsafe { 
                encrypt_file_init(
                    ctx.master_key.as_ptr(),
                    ctx.master_key.len(),
                    &output_len as *const usize as *mut usize,
                )
            };
            
            if enc_ctx.is_null() {
                return ERROR_IO_FAILED as isize;
            }
            ctx.encryption_context = Some(enc_ctx);

            // Get wrapped FEK and write it first (not returned here, handled separately)
            let wrapped_fek_len: usize = 0;
            let wrapped_fek = unsafe { encrypt_file_get_wrapped_fek(enc_ctx, &wrapped_fek_len as *const usize as *mut usize) };
            
            // Write header + wrapped FEK to buffer first
            if wrapped_fek_len + 12 <= buffer_size {
                unsafe {
                    // Header will be written by the caller
                    ptr::copy_nonoverlapping(wrapped_fek, buffer.add(12), wrapped_fek_len);
                }
                unsafe { libc::free(wrapped_fek as *mut c_void); }
            }
        }

        // Encrypt chunk
        let enc_ctx = ctx.encryption_context.unwrap();
        let output_len: usize = 0;
        let encrypted = unsafe { 
            encrypt_chunk(
                enc_ctx,
                encrypted_data.as_ptr(),
                encrypted_data.len(),
                chunk_index,
                &output_len as *const usize as *mut usize,
            )
        };

        if encrypted.is_null() {
            return ERROR_IO_FAILED as isize;
        }

        // Get encrypted data size
        let encrypted_size = unsafe { *(&output_len as *const usize as *const usize) };
        
        // Copy to buffer
        if encrypted_size <= buffer_size {
            unsafe {
                ptr::copy_nonoverlapping(encrypted, buffer, encrypted_size);
            }
        }
        
        unsafe { libc::free(encrypted as *mut c_void); }
    } else {
        // No encryption - copy raw data
        if actual_size <= buffer_size {
            unsafe {
                ptr::copy_nonoverlapping(encrypted_data.as_ptr(), buffer, actual_size);
            }
        }
    }

    // Update progress
    ctx.bytes_read += actual_size;
    ctx.chunk_index += 1;

    // Call progress callback if throttled
    if let Some(cb) = progress_callback {
        if ctx.progress_throttler.should_update(ctx.bytes_read, ctx.total_bytes) {
            cb(ctx.bytes_read, ctx.total_bytes, user_data);
        }
    }

    actual_size as isize
}

/// Get header and wrapped FEK for upload
/// Must be called before processing chunks if encryption is enabled
///
/// # Arguments
/// * `context` - Pointer to UploadContext
/// * `header_buffer` - Buffer to store header (minimum 12 bytes)
/// * `fek_buffer` - Buffer to store wrapped FEK
/// * `fek_buffer_size` - Size of FEK buffer
/// * `fek_len` - Pointer to store actual wrapped FEK length
///
/// # Returns
/// 0 on success, error code on failure
#[no_mangle]
pub extern "C" fn upload_get_header(
    context: *mut UploadContext,
    header_buffer: *mut u8,
    fek_buffer: *mut u8,
    fek_buffer_size: usize,
    fek_len: *mut usize,
) -> i32 {
    if context.is_null() || header_buffer.is_null() || fek_buffer.is_null() || fek_len.is_null() {
        return ERROR_NULL_POINTER;
    }

    let ctx = unsafe { &mut *context };

    if !ctx.should_encrypt || ctx.master_key.is_empty() {
        // No encryption - write empty header
        unsafe {
            ptr::write_bytes(header_buffer, 0, 12);
            *fek_len = 0;
        }
        return SUCCESS;
    }

    // Initialize encryption if not already done
    if ctx.encryption_context.is_none() {
        let output_len: usize = 0;
        let enc_ctx = unsafe { 
            encrypt_file_init(
                ctx.master_key.as_ptr(),
                ctx.master_key.len(),
                &output_len as *const usize as *mut usize,
            )
        };
        
        if enc_ctx.is_null() {
            return ERROR_IO_FAILED;
        }
        ctx.encryption_context = Some(enc_ctx);
    }

    // Get wrapped FEK
    let wrapped_fek_len: usize = 0;
    let wrapped_fek = unsafe { 
        encrypt_file_get_wrapped_fek(
            ctx.encryption_context.unwrap(),
            &wrapped_fek_len as *const usize as *mut usize,
        )
    };

    if wrapped_fek.is_null() {
        return ERROR_IO_FAILED;
    }

    unsafe {
        // Write header: magic (4) + version (1) + reserved (3) + fek_len (4)
        const MAGIC: u32 = 0x434E4552; // "CNER"
        const VERSION: u8 = 1;
        
        let magic_bytes = MAGIC.to_le_bytes();
        let fek_len_bytes = (wrapped_fek_len as u32).to_le_bytes();
        
        ptr::copy_nonoverlapping(magic_bytes.as_ptr(), header_buffer, 4);
        header_buffer.add(4).write(VERSION);
        header_buffer.add(5).write(0);
        header_buffer.add(6).write(0);
        header_buffer.add(7).write(0);
        ptr::copy_nonoverlapping(fek_len_bytes.as_ptr(), header_buffer.add(8), 4);

        // Copy wrapped FEK
        if wrapped_fek_len <= fek_buffer_size {
            ptr::copy_nonoverlapping(wrapped_fek, fek_buffer, wrapped_fek_len);
        }
        *fek_len = wrapped_fek_len;
    }

    unsafe { libc::free(wrapped_fek as *mut c_void); }

    SUCCESS
}

/// Finalize upload and clean up resources
///
/// # Arguments
/// * `context` - Pointer to UploadContext
///
/// # Returns
/// 0 on success, error code on failure
#[no_mangle]
pub extern "C" fn upload_finalize(context: *mut UploadContext) -> i32 {
    if context.is_null() {
        return ERROR_NULL_POINTER;
    }

    let ctx = unsafe { &mut *context };

    // Finalize encryption context
    if let Some(enc_ctx) = ctx.encryption_context {
        unsafe { encrypt_file_finalize(enc_ctx); }
    }

    // Close file
    if !ctx.input_file.is_null() {
        unsafe {
            let _ = Box::from_raw(ctx.input_file);
        }
        ctx.input_file = ptr::null_mut();
    }

    ctx.is_finalized = true;

    SUCCESS
}

/// Free upload context
///
/// # Arguments
/// * `context` - Pointer to UploadContext to free
#[no_mangle]
pub extern "C" fn upload_free(context: *mut UploadContext) {
    if !context.is_null() {
        unsafe {
            // Finalize first if not done
            if !context.is_null() {
                let ctx = &mut *context;
                if !ctx.is_finalized {
                    if let Some(enc_ctx) = ctx.encryption_context {
                        encrypt_file_finalize(enc_ctx);
                    }
                    if !ctx.input_file.is_null() {
                        let _ = Box::from_raw(ctx.input_file);
                    }
                }
            }
            let _ = Box::from_raw(context);
        }
    }
}

/// Get total bytes for upload
///
/// # Arguments
/// * `context` - Pointer to UploadContext
///
/// # Returns
/// Total bytes, or 0 if invalid
#[no_mangle]
pub extern "C" fn upload_get_total_bytes(context: *mut UploadContext) -> usize {
    if context.is_null() {
        return 0;
    }
    unsafe { (&*context).total_bytes }
}

/// Get bytes processed
///
/// # Arguments
/// * `context` - Pointer to UploadContext
///
/// # Returns
/// Bytes processed, or 0 if invalid
#[no_mangle]
pub extern "C" fn upload_get_bytes_processed(context: *mut UploadContext) -> usize {
    if context.is_null() {
        return 0;
    }
    unsafe { (&*context).bytes_read }
}
