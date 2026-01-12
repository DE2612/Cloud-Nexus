/// Unified Cloud Copy Operations for CloudNexus
/// 
/// This module provides a single unified method for all cloud-to-cloud copy operations:
/// - GDrive → GDrive
/// - GDrive → OneDrive
/// - OneDrive → GDrive
/// - OneDrive → OneDrive
/// 
/// The architecture uses in-memory chunking:
/// 1. Download chunk from source (via Dart callback)
/// 2. Upload chunk to destination (via Dart callback)
/// 3. Clear RAM buffer (automatic on next iteration)
/// 4. Repeat until EOF

use std::sync::atomic::{AtomicBool, Ordering};
use std::ffi::{c_char, c_void};
use std::ptr;

/// Progress callback type for copy operations
/// Parameters: bytes_copied, total_bytes, files_processed, total_files, user_data
pub type UnifiedProgressCallback = extern "C" fn(
    bytes_copied: u64,
    total_bytes: u64,
    files_processed: u32,
    total_files: u32,
    user_data: *mut c_void,
);

/// Read callback: Dart downloads chunk from source cloud into buffer
/// Returns: number of bytes read (0 for EOF, negative for error)
pub type UnifiedReadCallback = extern "C" fn(
    buffer: *mut u8,           // RAM buffer to fill with downloaded data
    buffer_size: usize,        // Size of buffer
    offset: u64,               // File offset to read from
    user_data: *mut c_void,    // User data
) -> isize;

/// Write callback: Dart uploads chunk from buffer to destination cloud
/// Returns: 0 on success, negative on error
pub type UnifiedWriteCallback = extern "C" fn(
    data: *const u8,           // Pointer to chunk data in RAM
    data_len: usize,           // Length of data
    offset: u64,               // File offset to write to
    user_data: *mut c_void,    // User data
) -> i32;

/// Error codes
const SUCCESS: i32 = 0;
const ERROR_NULL_POINTER: i32 = -1;
const ERROR_CANCELLED: i32 = -10;

/// Unified copy context - works for ANY source/destination combination
#[repr(C)]
pub struct UnifiedCopyContext {
    /// Total bytes to copy
    total_bytes: u64,
    /// Bytes copied so far
    bytes_copied: u64,
    /// Size of each chunk in bytes
    chunk_size: usize,
    /// Number of files processed
    files_processed: u32,
    /// Total number of files
    total_files: u32,
    /// Cancellation flag pointer
    cancel_flag: *const AtomicBool,
    /// Current file offset
    file_offset: u64,
}

impl UnifiedCopyContext {
    /// Create a new unified copy context
    pub fn new(
        total_bytes: u64,
        total_files: u32,
        chunk_size: usize,
        cancel_flag: *const AtomicBool,
    ) -> Self {
        Self {
            total_bytes,
            bytes_copied: 0,
            chunk_size,
            files_processed: 0,
            total_files,
            cancel_flag,
            file_offset: 0,
        }
    }
    
    /// Check if operation is cancelled
    pub fn is_cancelled(&self) -> bool {
        if self.cancel_flag.is_null() {
            return false;
        }
        unsafe { (*self.cancel_flag).load(Ordering::SeqCst) }
    }
}

/// Initialize unified copy context
///
/// # Arguments
/// * `total_bytes` - Total bytes to copy across all files
/// * `total_files` - Total number of files to copy
/// * `chunk_size` - Size of chunks in bytes (64KB minimum, 10MB maximum)
/// * `cancel_flag` - Pointer to AtomicBool for cancellation (can be null)
///
/// # Returns
/// Pointer to UnifiedCopyContext, or null on error
#[no_mangle]
pub extern "C" fn unified_copy_init(
    total_bytes: u64,
    total_files: u32,
    chunk_size: usize,
    cancel_flag: *const AtomicBool,
) -> *mut UnifiedCopyContext {
    // Validate chunk size: 64KB minimum, 10MB maximum
    let chunk_size = chunk_size.max(64 * 1024).min(10 * 1024 * 1024);
    
    let context = Box::new(UnifiedCopyContext::new(
        total_bytes,
        total_files,
        chunk_size,
        cancel_flag,
    ));
    
    // Leak the box and return the pointer (caller must free with unified_copy_free)
    Box::leak(context) as *mut UnifiedCopyContext
}

/// Process one file copy operation
///
/// This function orchestrates the download→upload→clear loop:
/// 1. Download chunk from source (via read_callback)
/// 2. Chunk is now in RAM buffer
/// 3. Upload chunk to destination (via write_callback)
/// 4. Clear RAM buffer (automatic - buffer reused for next chunk)
/// 5. Repeat until EOF
///
/// # Arguments
/// * `context` - Pointer to UnifiedCopyContext
/// * `read_buffer` - Pre-allocated RAM buffer for chunk data
/// * `buffer_size` - Size of the buffer (should match chunk_size)
/// * `file_size` - Size of the file being copied
/// * `read_callback` - Callback to download chunk from source
/// * `write_callback` - Callback to upload chunk to destination
/// * `progress_callback` - Optional progress callback
/// * `user_data` - User data for callbacks
///
/// # Returns
/// 1 if more files to process, 0 if done, negative error code on failure
#[no_mangle]
pub extern "C" fn unified_copy_file(
    context: *mut UnifiedCopyContext,
    read_buffer: *mut u8,
    buffer_size: usize,
    file_size: u64,
    read_callback: Option<UnifiedReadCallback>,
    write_callback: Option<UnifiedWriteCallback>,
    progress_callback: Option<UnifiedProgressCallback>,
    user_data: *mut c_void,
) -> i32 {
    // Validate inputs
    if context.is_null() {
        return ERROR_NULL_POINTER;
    }
    
    if read_buffer.is_null() {
        return ERROR_NULL_POINTER;
    }
    
    let ctx = unsafe { &mut *context };
    
    // Validate callbacks
    let read_cb = match read_callback {
        Some(cb) => cb,
        None => return ERROR_NULL_POINTER,
    };
    
    let write_cb = match write_callback {
        Some(cb) => cb,
        None => return ERROR_NULL_POINTER,
    };
    
    // Initialize file offset
    let mut file_offset = 0u64;
    let mut bytes_copied_this_file = 0u64;
    
    // Download → Upload → Clear loop
    // This loop processes the file in chunks, keeping memory usage constant
    while bytes_copied_this_file < file_size {
        // Check cancellation at start of each iteration
        if ctx.is_cancelled() {
            return ERROR_CANCELLED;
        }
        
        // Calculate bytes to read for this chunk
        let bytes_to_read = ((file_size - bytes_copied_this_file) as usize)
            .min(ctx.chunk_size)
            .min(buffer_size);
        
        // === STEP 1: Download chunk from source into RAM ===
        // Dart reads from cloud API (e.g., GET with Range header)
        // The buffer is filled with downloaded data
        let bytes_read = read_cb(
            read_buffer,
            bytes_to_read,
            file_offset,
            user_data,
        );
        
        if bytes_read < 0 {
            // Error from read callback
            return bytes_read as i32;
        }
        
        if bytes_read == 0 {
            // EOF - file copy complete
            break;
        }
        
        // === CHUNK NOW IN RAM ===
        // read_buffer contains [bytes_read] bytes of data
        // This is the only time the buffer contains data
        
        // === STEP 2: Upload chunk from RAM to destination ===
        // Dart uploads to cloud API (e.g., PATCH with Content-Range)
        let write_result = write_cb(
            read_buffer,
            bytes_read as usize,
            file_offset,
            user_data,
        );
        
        if write_result < 0 {
            // Error from write callback
            return write_result;
        }
        
        // === STEP 3: Clear RAM buffer (automatic) ===
        // The buffer will be overwritten in the next iteration
        // No explicit clear needed - this is the key memory optimization
        
        // Update progress
        file_offset += bytes_read as u64;
        bytes_copied_this_file += bytes_read as u64;
        ctx.bytes_copied += bytes_read as u64;
        
        // Progress callback (throttled by Dart if needed)
        if let Some(cb) = progress_callback {
            cb(
                ctx.bytes_copied,
                ctx.total_bytes,
                ctx.files_processed + 1,
                ctx.total_files,
                user_data,
            );
        }
    }
    
    // Mark file as processed
    ctx.files_processed += 1;
    ctx.file_offset = 0;
    
    // Return 1 if more files to copy, 0 if done
    if ctx.files_processed < ctx.total_files {
        1
    } else {
        0
    }
}

/// Finalize copy operation and send final progress update
///
/// # Arguments
/// * `context` - Pointer to UnifiedCopyContext
/// * `progress_callback` - Optional final progress callback
/// * `user_data` - User data for callback
///
/// # Returns
/// 0 on success, error code on failure
#[no_mangle]
pub extern "C" fn unified_copy_finalize(
    context: *mut UnifiedCopyContext,
    progress_callback: Option<UnifiedProgressCallback>,
    user_data: *mut c_void,
) -> i32 {
    if context.is_null() {
        return ERROR_NULL_POINTER;
    }
    
    let ctx = unsafe { &*context };
    
    // Final progress update
    if let Some(cb) = progress_callback {
        cb(
            ctx.bytes_copied,
            ctx.total_bytes,
            ctx.files_processed,
            ctx.total_files,
            user_data,
        );
    }
    
    SUCCESS
}

/// Free unified copy context
///
/// # Arguments
/// * `context` - Pointer to UnifiedCopyContext to free
#[no_mangle]
pub extern "C" fn unified_copy_free(context: *mut UnifiedCopyContext) {
    if !context.is_null() {
        unsafe {
            // Convert back to Box and drop it
            let _ = Box::from_raw(context);
        }
    }
}

/// Get copy progress
///
/// # Arguments
/// * `context` - Pointer to UnifiedCopyContext
/// * `bytes_copied` - Pointer to store bytes copied
/// * `total_bytes` - Pointer to store total bytes
/// * `files_processed` - Pointer to store files processed
/// * `total_files` - Pointer to store total files
#[no_mangle]
pub extern "C" fn unified_copy_get_progress(
    context: *mut UnifiedCopyContext,
    bytes_copied: *mut u64,
    total_bytes: *mut u64,
    files_processed: *mut u32,
    total_files: *mut u32,
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

/// Get bytes copied so far (simple accessor)
///
/// # Arguments
/// * `context` - Pointer to UnifiedCopyContext
///
/// # Returns
/// Bytes copied, or 0 if invalid context
#[no_mangle]
pub extern "C" fn unified_copy_get_bytes_copied(context: *mut UnifiedCopyContext) -> u64 {
    if context.is_null() {
        return 0;
    }
    unsafe { (&*context).bytes_copied }
}

/// Get total bytes (simple accessor)
///
/// # Arguments
/// * `context` - Pointer to UnifiedCopyContext
///
/// # Returns
/// Total bytes, or 0 if invalid context
#[no_mangle]
pub extern "C" fn unified_copy_get_total_bytes(context: *mut UnifiedCopyContext) -> u64 {
    if context.is_null() {
        return 0;
    }
    unsafe { (&*context).total_bytes }
}

/// Get files processed (simple accessor)
///
/// # Arguments
/// * `context` - Pointer to UnifiedCopyContext
///
/// # Returns
/// Files processed, or 0 if invalid context
#[no_mangle]
pub extern "C" fn unified_copy_get_files_processed(context: *mut UnifiedCopyContext) -> u32 {
    if context.is_null() {
        return 0;
    }
    unsafe { (&*context).files_processed }
}

/// Get total files (simple accessor)
///
/// # Arguments
/// * `context` - Pointer to UnifiedCopyContext
///
/// # Returns
/// Total files, or 0 if invalid context
#[no_mangle]
pub extern "C" fn unified_copy_get_total_files(context: *mut UnifiedCopyContext) -> u32 {
    if context.is_null() {
        return 0;
    }
    unsafe { (&*context).total_files }
}