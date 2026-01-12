use aes_gcm::{
    aead::{Aead, KeyInit, OsRng},
    Aes256Gcm, Nonce,
};
use pbkdf2::pbkdf2_hmac;
use rand::RngCore;
use sha2::Sha256;
use std::ffi::{c_char, c_void, CStr};
use std::os::raw::c_int;
use std::ptr;
use std::slice;

// Include the encryption module (re-export for consistency)
mod encryption;
pub use encryption::*;

// Include the folder scanning module
mod scan;
pub use scan::*;

// Include the search module (Phase 1)
mod search;
pub use search::*;

// Include file I/O module
mod file_io;
pub use file_io::*;

// Include upload module
mod upload;
pub use upload::*;

// Include download module
mod download;
pub use download::*;

// Include copy modules
mod copy;
pub use copy::*;

// Include unified copy module (replaces individual copy modules)
mod unified_copy;
pub use unified_copy::*;

// Constants
const MAGIC: u32 = 0x434E4552; // "CNER"
const VERSION: u8 = 1;
const NONCE_SIZE: usize = 12;
const MAC_SIZE: usize = 16;
const KEY_SIZE: usize = 32;
const HEADER_SIZE: usize = 4 + 1 + 3 + 4; // magic + version + reserved + fek_length
const CHUNK_HEADER_SIZE: usize = 4 + 4 + 12 + 16; // index + size + nonce + mac
const DEFAULT_CHUNK_SIZE: usize = 1024 * 1024; // 1MB chunks

// Error codes
const SUCCESS: c_int = 0;
const ERROR_NULL_POINTER: c_int = -1;
const ERROR_INVALID_KEY_SIZE: c_int = -2;
const ERROR_ENCRYPTION_FAILED: c_int = -3;
const ERROR_DECRYPTION_FAILED: c_int = -4;
const ERROR_INVALID_FORMAT: c_int = -5;
const ERROR_ALLOCATION_FAILED: c_int = -6;

// ============================================================================
// TRUE STREAMING ENCRYPTION CONTEXTS
// ============================================================================

/// Encryption context for streaming encryption
/// Holds the FEK and wrapped FEK for chunk-by-chunk encryption
#[repr(C)]
pub struct EncryptionContext {
    fek: [u8; KEY_SIZE],
    wrapped_fek: Vec<u8>,
    header: [u8; HEADER_SIZE],
    chunk_index: u32,
}

/// Decryption context for streaming decryption
/// Holds the FEK for chunk-by-chunk decryption
#[repr(C)]
pub struct DecryptionContext {
    fek: Vec<u8>,
    chunk_index: u32,
}

/// Encrypt data with AES-256-GCM
/// 
/// # Arguments
/// * `data` - Pointer to data to encrypt
/// * `data_len` - Length of data
/// * `key` - Pointer to 32-byte encryption key
/// * `key_len` - Length of key (must be 32)
/// * `output_len` - Pointer to store output length
/// 
/// # Returns
/// Pointer to encrypted data (caller must free with free_buffer)
/// Output format: [nonce 12 bytes] + [ciphertext] + [mac 16 bytes]
#[no_mangle]
pub extern "C" fn encrypt_data(
    data: *const u8,
    data_len: usize,
    key: *const u8,
    key_len: usize,
    output_len: *mut usize,
) -> *mut u8 {
    if data.is_null() || key.is_null() || output_len.is_null() {
        return ptr::null_mut();
    }

    if key_len != KEY_SIZE {
        return ptr::null_mut();
    }

    let data_slice = unsafe { slice::from_raw_parts(data, data_len) };
    let key_slice = unsafe { slice::from_raw_parts(key, key_len) };

    // Create cipher
    let cipher = Aes256Gcm::new_from_slice(key_slice).unwrap();

    // Generate nonce
    let mut nonce_bytes = [0u8; NONCE_SIZE];
    OsRng.fill_bytes(&mut nonce_bytes);
    let nonce = Nonce::from_slice(&nonce_bytes);

    // Encrypt
    let ciphertext = match cipher.encrypt(nonce, data_slice.as_ref()) {
        Ok(ct) => ct,
        Err(_) => return ptr::null_mut(),
    };

    // Allocate output buffer: nonce + ciphertext
    let output_size = NONCE_SIZE + ciphertext.len();
    let output = unsafe {
        let ptr = libc::malloc(output_size) as *mut u8;
        if ptr.is_null() {
            return ptr::null_mut();
        }
        ptr
    };

    // Copy nonce and ciphertext
    unsafe {
        ptr::copy_nonoverlapping(nonce_bytes.as_ptr(), output, NONCE_SIZE);
        ptr::copy_nonoverlapping(ciphertext.as_ptr(), output.add(NONCE_SIZE), ciphertext.len());
    }

    unsafe {
        *output_len = output_size;
    }

    output
}

/// Decrypt data with AES-256-GCM
/// 
/// # Arguments
/// * `encrypted_data` - Pointer to encrypted data
/// * `encrypted_len` - Length of encrypted data
/// * `key` - Pointer to 32-byte decryption key
/// * `key_len` - Length of key (must be 32)
/// * `output_len` - Pointer to store output length
/// 
/// # Returns
/// Pointer to decrypted data (caller must free with free_buffer)
#[no_mangle]
pub extern "C" fn decrypt_data(
    encrypted_data: *const u8,
    encrypted_len: usize,
    key: *const u8,
    key_len: usize,
    output_len: *mut usize,
) -> *mut u8 {
    if encrypted_data.is_null() || key.is_null() || output_len.is_null() {
        return ptr::null_mut();
    }

    if key_len != KEY_SIZE {
        return ptr::null_mut();
    }

    if encrypted_len < NONCE_SIZE + MAC_SIZE {
        return ptr::null_mut();
    }

    let encrypted_slice = unsafe { slice::from_raw_parts(encrypted_data, encrypted_len) };
    let key_slice = unsafe { slice::from_raw_parts(key, key_len) };

    // Extract nonce
    let nonce = Nonce::from_slice(&encrypted_slice[..NONCE_SIZE]);

    // Extract ciphertext (nonce + ciphertext)
    let ciphertext = &encrypted_slice[NONCE_SIZE..];

    // Create cipher
    let cipher = Aes256Gcm::new_from_slice(key_slice).unwrap();

    // Decrypt
    let plaintext = match cipher.decrypt(nonce, ciphertext.as_ref()) {
        Ok(pt) => pt,
        Err(_) => return ptr::null_mut(),
    };

    // Allocate output buffer
    let output = unsafe {
        let ptr = libc::malloc(plaintext.len()) as *mut u8;
        if ptr.is_null() {
            return ptr::null_mut();
        }
        ptr
    };

    // Copy plaintext
    unsafe {
        ptr::copy_nonoverlapping(plaintext.as_ptr(), output, plaintext.len());
        *output_len = plaintext.len();
    }

    output
}

/// Encrypt file with embedded FEK (Approach 1)
/// 
/// # Arguments
/// * `file_data` - Pointer to file data to encrypt
/// * `file_len` - Length of file data
/// * `fek` - Pointer to 32-byte File Encryption Key
/// * `fek_len` - Length of FEK (must be 32)
/// * `master_key` - Pointer to 32-byte Master Key
/// * `master_key_len` - Length of master key (must be 32)
/// * `output_len` - Pointer to store output length
/// 
/// # Returns
/// Pointer to encrypted file data (caller must free with free_buffer)
/// Format: [Header 60 bytes] + [Encrypted Data] + [MAC 16 bytes]
#[no_mangle]
pub extern "C" fn encrypt_file_with_fek(
    file_data: *const u8,
    file_len: usize,
    fek: *const u8,
    fek_len: usize,
    master_key: *const u8,
    master_key_len: usize,
    output_len: *mut usize,
) -> *mut u8 {
    if file_data.is_null() || fek.is_null() || master_key.is_null() || output_len.is_null() {
        return ptr::null_mut();
    }

    if fek_len != KEY_SIZE || master_key_len != KEY_SIZE {
        return ptr::null_mut();
    }

    let file_slice = unsafe { slice::from_raw_parts(file_data, file_len) };
    let fek_slice = unsafe { slice::from_raw_parts(fek, fek_len) };
    let master_key_slice = unsafe { slice::from_raw_parts(master_key, master_key_len) };

    // Wrap FEK with master key
    let wrapped_fek = wrap_key(fek_slice, master_key_slice);
    if wrapped_fek.is_empty() {
        return ptr::null_mut();
    }

    // Encrypt file content with FEK
    let cipher = Aes256Gcm::new_from_slice(fek_slice).unwrap();
    let mut nonce_bytes = [0u8; NONCE_SIZE];
    OsRng.fill_bytes(&mut nonce_bytes);
    let nonce = Nonce::from_slice(&nonce_bytes);

    let encrypted_content = match cipher.encrypt(nonce, file_slice.as_ref()) {
        Ok(ct) => ct,
        Err(_) => return ptr::null_mut(),
    };

    // Build header
    let header = build_header(wrapped_fek.len() as u32);

    // Calculate total size
    let total_size = HEADER_SIZE + wrapped_fek.len() + NONCE_SIZE + encrypted_content.len();

    // Allocate output buffer
    let output = unsafe {
        let ptr = libc::malloc(total_size) as *mut u8;
        if ptr.is_null() {
            return ptr::null_mut();
        }
        ptr
    };

    // Copy all parts
    let mut offset = 0;
    unsafe {
        // Header
        ptr::copy_nonoverlapping(header.as_ptr(), output.add(offset), HEADER_SIZE);
        offset += HEADER_SIZE;

        // Wrapped FEK
        ptr::copy_nonoverlapping(wrapped_fek.as_ptr(), output.add(offset), wrapped_fek.len());
        offset += wrapped_fek.len();

        // Nonce
        ptr::copy_nonoverlapping(nonce_bytes.as_ptr(), output.add(offset), NONCE_SIZE);
        offset += NONCE_SIZE;

        // Encrypted content
        ptr::copy_nonoverlapping(encrypted_content.as_ptr(), output.add(offset), encrypted_content.len());
    }

    unsafe {
        *output_len = total_size;
    }

    output
}

/// Decrypt file with embedded FEK (Approach 1)
/// 
/// # Arguments
/// * `encrypted_data` - Pointer to encrypted file data
/// * `encrypted_len` - Length of encrypted data
/// * `master_key` - Pointer to 32-byte Master Key
/// * `master_key_len` - Length of master key (must be 32)
/// * `output_len` - Pointer to store output length
/// 
/// # Returns
/// Pointer to decrypted file data (caller must free with free_buffer)
#[no_mangle]
pub extern "C" fn decrypt_file_with_fek(
    encrypted_data: *const u8,
    encrypted_len: usize,
    master_key: *const u8,
    master_key_len: usize,
    output_len: *mut usize,
) -> *mut u8 {
    if encrypted_data.is_null() || master_key.is_null() || output_len.is_null() {
        return ptr::null_mut();
    }

    if master_key_len != KEY_SIZE {
        return ptr::null_mut();
    }

    if encrypted_len < HEADER_SIZE + NONCE_SIZE + MAC_SIZE {
        return ptr::null_mut();
    }

    let encrypted_slice = unsafe { slice::from_raw_parts(encrypted_data, encrypted_len) };
    let master_key_slice = unsafe { slice::from_raw_parts(master_key, master_key_len) };

    // Parse header
    let (magic, version, fek_length) = match parse_header(&encrypted_slice[..HEADER_SIZE]) {
        Ok(result) => result,
        Err(_) => return ptr::null_mut(),
    };

    // Validate magic and version
    if magic != MAGIC || version != VERSION {
        return ptr::null_mut();
    }

    // Validate total size
    let expected_min_size = HEADER_SIZE + fek_length + NONCE_SIZE + MAC_SIZE;
    if encrypted_len < expected_min_size {
        return ptr::null_mut();
    }

    // Extract wrapped FEK
    let wrapped_fek = &encrypted_slice[HEADER_SIZE..HEADER_SIZE + fek_length];

    // Unwrap FEK
    let fek = match unwrap_key(wrapped_fek, master_key_slice) {
        Ok(key) => key,
        Err(_) => return ptr::null_mut(),
    };

    // Extract nonce
    let nonce_start = HEADER_SIZE + fek_length;
    let nonce = Nonce::from_slice(&encrypted_slice[nonce_start..nonce_start + NONCE_SIZE]);

    // Extract encrypted content
    let content_start = nonce_start + NONCE_SIZE;
    let encrypted_content = &encrypted_slice[content_start..];

    // Decrypt with FEK
    let cipher = Aes256Gcm::new_from_slice(&fek).unwrap();
    let plaintext = match cipher.decrypt(nonce, encrypted_content.as_ref()) {
        Ok(pt) => pt,
        Err(_) => return ptr::null_mut(),
    };

    // Allocate output buffer
    let output = unsafe {
        let ptr = libc::malloc(plaintext.len()) as *mut u8;
        if ptr.is_null() {
            return ptr::null_mut();
        }
        ptr
    };

    // Copy plaintext
    unsafe {
        ptr::copy_nonoverlapping(plaintext.as_ptr(), output, plaintext.len());
        *output_len = plaintext.len();
    }

    output
}

/// Derive key from password using PBKDF2
/// 
/// # Arguments
/// * `password` - Password string (null-terminated)
/// * `salt` - Pointer to salt
/// * `salt_len` - Length of salt
/// * `iterations` - Number of PBKDF2 iterations
/// * `output_key` - Pointer to store derived key (32 bytes)
/// 
/// # Returns
/// 0 on success, error code on failure
#[no_mangle]
pub extern "C" fn derive_key_from_password(
    password: *const c_char,
    salt: *const u8,
    salt_len: usize,
    iterations: u32,
    output_key: *mut u8,
) -> c_int {
    if password.is_null() || salt.is_null() || output_key.is_null() {
        return ERROR_NULL_POINTER;
    }

    let password_str = unsafe {
        match CStr::from_ptr(password).to_str() {
            Ok(s) => s,
            Err(_) => return ERROR_NULL_POINTER,
        }
    };

    let salt_slice = unsafe { slice::from_raw_parts(salt, salt_len) };
    let output_slice = unsafe { slice::from_raw_parts_mut(output_key, KEY_SIZE) };

    // Derive key using PBKDF2-HMAC-SHA256
    pbkdf2_hmac::<Sha256>(
        password_str.as_bytes(),
        salt_slice,
        iterations,
        output_slice,
    );

    SUCCESS
}

/// Free memory allocated by Rust
#[no_mangle]
pub extern "C" fn free_buffer(buffer: *mut u8) {
    if !buffer.is_null() {
        unsafe {
            libc::free(buffer as *mut c_void);
        }
    }
}

// Helper functions

fn wrap_key(key: &[u8], master_key: &[u8]) -> Vec<u8> {
    let cipher = Aes256Gcm::new_from_slice(master_key).unwrap();
    let mut nonce_bytes = [0u8; NONCE_SIZE];
    OsRng.fill_bytes(&mut nonce_bytes);
    let nonce = Nonce::from_slice(&nonce_bytes);

    match cipher.encrypt(nonce, key.as_ref()) {
        Ok(ct) => {
            let mut result = Vec::with_capacity(NONCE_SIZE + ct.len());
            result.extend_from_slice(&nonce_bytes);
            result.extend_from_slice(&ct);
            result
        }
        Err(_) => Vec::new(),
    }
}

fn unwrap_key(wrapped_key: &[u8], master_key: &[u8]) -> Result<Vec<u8>, ()> {
    if wrapped_key.len() < NONCE_SIZE + MAC_SIZE {
        return Err(());
    }

    let nonce = Nonce::from_slice(&wrapped_key[..NONCE_SIZE]);
    let ciphertext = &wrapped_key[NONCE_SIZE..];

    let cipher = Aes256Gcm::new_from_slice(master_key).unwrap();
    cipher.decrypt(nonce, ciphertext.as_ref()).map_err(|_| ())
}

fn build_header(fek_length: u32) -> [u8; HEADER_SIZE] {
    let mut header = [0u8; HEADER_SIZE];
    
    // Magic bytes (little-endian)
    header[0..4].copy_from_slice(&MAGIC.to_le_bytes());
    
    // Version
    header[4] = VERSION;
    
    // Reserved bytes (5-7) - zero
    
    // FEK length (little-endian)
    header[8..12].copy_from_slice(&fek_length.to_le_bytes());
    
    header
}

fn parse_header(header: &[u8]) -> Result<(u32, u8, usize), ()> {
    if header.len() < HEADER_SIZE {
        return Err(());
    }

    let magic = u32::from_le_bytes([header[0], header[1], header[2], header[3]]);
    let version = header[4];
    let fek_length = u32::from_le_bytes([header[8], header[9], header[10], header[11]]) as usize;

    Ok((magic, version, fek_length))
}

// ============================================================================
// STREAMING ENCRYPTION (Option 2: Full Streaming with independent nonces)
// ============================================================================

/// Chunk header structure for encrypted files
///
/// Format per chunk:
/// - chunk_index (4 bytes, little-endian)
/// - chunk_size (4 bytes, little-endian, size of encrypted data excluding MAC)
/// - nonce (12 bytes)
/// - mac (16 bytes) - AES-GCM authentication tag
///
/// Total chunk overhead: 36 bytes

/// Progress callback type for encryption/decryption operations
///
/// # Arguments
/// * `bytes_processed` - Number of bytes processed so far
/// * `total_bytes` - Total number of bytes to process
/// * `user_data` - User-provided data pointer
pub type ProgressCallback = extern "C" fn(bytes_processed: usize, total_bytes: usize, user_data: *mut c_void);

/// Encrypt a file using streaming encryption (Option 2)
///
/// # Arguments
/// * `file_data` - Pointer to file data to encrypt
/// * `file_len` - Length of file data
/// * `master_key` - Pointer to 32-byte Master Key
/// * `master_key_len` - Length of master key (must be 32)
/// * `output_len` - Pointer to store output length
/// * `progress_callback` - Optional progress callback (can be null)
/// * `user_data` - User data to pass to progress callback
///
/// # Returns
/// Pointer to encrypted file data (caller must free with free_buffer)
///
/// Format:
/// [Main Header 12 bytes: magic 4 + version 1 + reserved 3 + fek_len 4] +
/// [Wrapped FEK] +
/// [Chunk Header 36 bytes] + [Chunk Data] +
/// [Chunk Header 36 bytes] + [Chunk Data] + ...
#[no_mangle]
pub extern "C" fn encrypt_file_streaming(
    file_data: *const u8,
    file_len: usize,
    master_key: *const u8,
    master_key_len: usize,
    output_len: *mut usize,
    progress_callback: Option<ProgressCallback>,
    user_data: *mut c_void,
) -> *mut u8 {
    if file_data.is_null() || master_key.is_null() || output_len.is_null() {
        return ptr::null_mut();
    }

    if master_key_len != KEY_SIZE {
        return ptr::null_mut();
    }

    let file_slice = unsafe { slice::from_raw_parts(file_data, file_len) };
    let master_key_slice = unsafe { slice::from_raw_parts(master_key, master_key_len) };

    // Generate and wrap File Encryption Key (FEK)
    let mut fek = [0u8; KEY_SIZE];
    OsRng.fill_bytes(&mut fek);
    let wrapped_fek = wrap_key(&fek, master_key_slice);
    if wrapped_fek.is_empty() {
        return ptr::null_mut();
    }

    // Build main header
    let main_header = build_header(wrapped_fek.len() as u32);

    // Encrypt file in chunks
    let mut chunks: Vec<Vec<u8>> = Vec::new();
    let mut total_encrypted_size = 0;
    let mut chunk_index: u32 = 0;

    let mut offset = 0;
    while offset < file_len {
        let chunk_end = std::cmp::min(offset + DEFAULT_CHUNK_SIZE, file_len);
        let chunk_data = &file_slice[offset..chunk_end];

        // Encrypt chunk with incrementing index
        match encrypt_chunk_impl(chunk_data, &fek, chunk_index) {
            Some(encrypted_chunk) => {
                total_encrypted_size += encrypted_chunk.len();
                chunks.push(encrypted_chunk);
            }
            None => return ptr::null_mut(),
        }

        // Call progress callback if provided
        if let Some(callback) = progress_callback {
            callback(chunk_end, file_len, user_data);
        }

        chunk_index += 1;
        offset = chunk_end;
    }

    // Calculate total output size
    let total_size = HEADER_SIZE + wrapped_fek.len() + total_encrypted_size;

    // Allocate output buffer
    let output = unsafe {
        let ptr = libc::malloc(total_size) as *mut u8;
        if ptr.is_null() {
            return ptr::null_mut();
        }
        ptr
    };

    // Copy main header
    let mut write_offset = 0;
    unsafe {
        ptr::copy_nonoverlapping(main_header.as_ptr(), output.add(write_offset), HEADER_SIZE);
        write_offset += HEADER_SIZE;

        // Copy wrapped FEK
        ptr::copy_nonoverlapping(wrapped_fek.as_ptr(), output.add(write_offset), wrapped_fek.len());
        write_offset += wrapped_fek.len();

        // Copy all chunks
        for chunk in &chunks {
            ptr::copy_nonoverlapping(chunk.as_ptr(), output.add(write_offset), chunk.len());
            write_offset += chunk.len();
        }
    }

    unsafe {
        *output_len = total_size;
    }

    output
}

/// Decrypt a file encrypted with streaming encryption (Option 2)
///
/// # Arguments
/// * `encrypted_data` - Pointer to encrypted file data
/// * `encrypted_len` - Length of encrypted data
/// * `master_key` - Pointer to 32-byte Master Key
/// * `master_key_len` - Length of master key (must be 32)
/// * `output_len` - Pointer to store output length
/// * `progress_callback` - Optional progress callback (can be null)
/// * `user_data` - User data to pass to progress callback
///
/// # Returns
/// Pointer to decrypted file data (caller must free with free_buffer)
#[no_mangle]
pub extern "C" fn decrypt_file_streaming(
    encrypted_data: *const u8,
    encrypted_len: usize,
    master_key: *const u8,
    master_key_len: usize,
    output_len: *mut usize,
    progress_callback: Option<ProgressCallback>,
    user_data: *mut c_void,
) -> *mut u8 {
    if encrypted_data.is_null() || master_key.is_null() || output_len.is_null() {
        return ptr::null_mut();
    }

    if master_key_len != KEY_SIZE {
        return ptr::null_mut();
    }

    if encrypted_len < HEADER_SIZE {
        return ptr::null_mut();
    }

    let encrypted_slice = unsafe { slice::from_raw_parts(encrypted_data, encrypted_len) };
    let master_key_slice = unsafe { slice::from_raw_parts(master_key, master_key_len) };

    // Parse main header
    let (magic, version, fek_length) = match parse_header(&encrypted_slice[..HEADER_SIZE]) {
        Ok(result) => result,
        Err(_) => return ptr::null_mut(),
    };

    // Validate magic and version
    if magic != MAGIC || version != VERSION {
        return ptr::null_mut();
    }

    // Validate total size
    if encrypted_len < HEADER_SIZE + fek_length {
        return ptr::null_mut();
    }

    // Extract wrapped FEK
    let wrapped_fek = &encrypted_slice[HEADER_SIZE..HEADER_SIZE + fek_length];

    // Unwrap FEK
    let fek = match unwrap_key(wrapped_fek, master_key_slice) {
        Ok(key) => key,
        Err(_) => return ptr::null_mut(),
    };

    // Decrypt chunks
    let mut plaintext_chunks: Vec<Vec<u8>> = Vec::new();
    let mut total_plaintext_size = 0;
    let mut offset = HEADER_SIZE + fek_length;
    let mut total_decrypted_bytes = 0;

    while offset < encrypted_len {
        // Check if we have enough data for chunk header
        if offset + 20 > encrypted_len {
            return ptr::null_mut();
        }

        // Read chunk header to get chunk size
        let chunk_size = u32::from_le_bytes([
            encrypted_slice[offset + 4],
            encrypted_slice[offset + 5],
            encrypted_slice[offset + 6],
            encrypted_slice[offset + 7],
        ]) as usize;

        // Check if we have enough data for the entire chunk
        if offset + 20 + chunk_size > encrypted_len {
            return ptr::null_mut();
        }

        // Pass only this chunk to decrypt_chunk_impl
        let chunk_data = &encrypted_slice[offset..offset + 20 + chunk_size];
        match decrypt_chunk_impl(chunk_data, &fek) {
            Some((plaintext, _chunk_len)) => {
                let plaintext_len = plaintext.len();
                total_plaintext_size += plaintext_len;
                plaintext_chunks.push(plaintext);
                offset += 20 + chunk_size;
                
                // Call progress callback if provided
                if let Some(callback) = progress_callback {
                    total_decrypted_bytes += plaintext_len;
                    callback(total_decrypted_bytes, total_plaintext_size, user_data);
                }
            }
            None => return ptr::null_mut(),
        }
    }

    // Allocate output buffer
    let output = unsafe {
        let ptr = libc::malloc(total_plaintext_size) as *mut u8;
        if ptr.is_null() {
            return ptr::null_mut();
        }
        ptr
    };

    // Copy all plaintext chunks
    let mut write_offset = 0;
    for chunk in &plaintext_chunks {
        unsafe {
            ptr::copy_nonoverlapping(chunk.as_ptr(), output.add(write_offset), chunk.len());
            write_offset += chunk.len();
        }
    }

    unsafe {
        *output_len = total_plaintext_size;
    }

    output
}

// Helper functions for streaming encryption

fn encrypt_chunk_impl(data: &[u8], fek: &[u8], chunk_index: u32) -> Option<Vec<u8>> {
    // Generate nonce for this chunk
    let mut nonce_bytes = [0u8; NONCE_SIZE];
    OsRng.fill_bytes(&mut nonce_bytes);
    let nonce = Nonce::from_slice(&nonce_bytes);

    // Encrypt chunk
    let cipher = Aes256Gcm::new_from_slice(fek).ok()?;
    let ciphertext = cipher.encrypt(nonce, data).ok()?;

    // Build chunk header: index (4) + size (4) + nonce (12)
    // Total header: 20 bytes
    let mut chunk = Vec::with_capacity(20 + ciphertext.len());

    // Chunk index (incrementing for each chunk)
    chunk.extend_from_slice(&chunk_index.to_le_bytes());
    
    // Chunk size (encrypted data INCLUDING MAC, as stored in encrypted_content)
    // encrypted_content is ciphertext + MAC tag from AES-GCM
    chunk.extend_from_slice(&(ciphertext.len() as u32).to_le_bytes());
    
    // Nonce
    chunk.extend_from_slice(&nonce_bytes);
    
    // Encrypted data (ciphertext which includes MAC tag)
    chunk.extend_from_slice(&ciphertext);

    Some(chunk)
}

fn decrypt_chunk_impl(encrypted_data: &[u8], fek: &[u8]) -> Option<(Vec<u8>, usize)> {
    if encrypted_data.len() < 20 {
        return None;
    }

    // Parse chunk header
    let _chunk_index = u32::from_le_bytes([
        encrypted_data[0], encrypted_data[1], encrypted_data[2], encrypted_data[3],
    ]);
    
    let _chunk_size = u32::from_le_bytes([
        encrypted_data[4], encrypted_data[5], encrypted_data[6], encrypted_data[7],
    ]) as usize;
    
    let nonce_bytes = &encrypted_data[8..20];
    
    // Encrypted data starts at position 20
    let encrypted_content = &encrypted_data[20..];
    
    // Validate chunk size
    if encrypted_content.len() < MAC_SIZE {
        return None;
    }

    // Extract nonce
    let nonce = Nonce::from_slice(nonce_bytes);

    // Decrypt
    let cipher = Aes256Gcm::new_from_slice(fek).ok()?;
    let plaintext = cipher.decrypt(nonce, encrypted_content.as_ref()).ok()?;

    // Calculate total chunk length (header 20 + encrypted_content which includes MAC)
    // This is the size of the chunk in the encrypted file
    let chunk_len = 20 + encrypted_content.len();

    Some((plaintext, chunk_len))
}

/// Simple wrapper for encrypting a file (backward compatible name)
/// Uses streaming encryption internally without progress callback
#[no_mangle]
pub extern "C" fn encrypt_file(
    file_data: *const u8,
    file_len: usize,
    master_key: *const u8,
    master_key_len: usize,
    output_len: *mut usize,
) -> *mut u8 {
    encrypt_file_streaming(file_data, file_len, master_key, master_key_len, output_len, None, ptr::null_mut())
}

/// Simple wrapper for decrypting a file (backward compatible name)
/// Uses streaming decryption internally without progress callback
#[no_mangle]
pub extern "C" fn decrypt_file(
    encrypted_data: *const u8,
    encrypted_len: usize,
    master_key: *const u8,
    master_key_len: usize,
    output_len: *mut usize,
) -> *mut u8 {
    decrypt_file_streaming(encrypted_data, encrypted_len, master_key, master_key_len, output_len, None, ptr::null_mut())
}

// ============================================================================
// TRUE STREAMING ENCRYPTION API (for low-memory chunk-by-chunk processing)
// ============================================================================

/// Initialize encryption context for streaming encryption
///
/// This function generates a File Encryption Key (FEK) and wraps it with the master key.
/// The returned context can be used for encrypting multiple chunks.
///
/// # Arguments
/// * `master_key` - Pointer to 32-byte Master Key
/// * `master_key_len` - Length of master key (must be 32)
/// * `output_len` - Pointer to store header size
///
/// # Returns
/// Pointer to EncryptionContext, or null on error
///
/// The caller is responsible for:
/// 1. Calling encrypt_chunk() for each chunk of data
/// 2. Calling encrypt_file_finalize() to free the context
///
/// The header bytes can be written to the output file followed by the wrapped FEK.
#[no_mangle]
pub extern "C" fn encrypt_file_init(
    master_key: *const u8,
    master_key_len: usize,
    output_len: *mut usize,
) -> *mut EncryptionContext {
    if master_key.is_null() || output_len.is_null() {
        return ptr::null_mut();
    }

    if master_key_len != KEY_SIZE {
        return ptr::null_mut();
    }

    let master_key_slice = unsafe { slice::from_raw_parts(master_key, master_key_len) };

    // Generate File Encryption Key (FEK)
    let mut fek = [0u8; KEY_SIZE];
    OsRng.fill_bytes(&mut fek);

    // Wrap FEK with master key
    let wrapped_fek = wrap_key(&fek, master_key_slice);
    let wrapped_fek_len = wrapped_fek.len();
    if wrapped_fek.is_empty() {
        return ptr::null_mut();
    }

    // Build header
    let header = build_header(wrapped_fek.len() as u32);

    // Create encryption context
    let context = Box::new(EncryptionContext {
        fek,
        wrapped_fek,
        header,
        chunk_index: 0,
    });

    // Return header size
    unsafe {
        *output_len = HEADER_SIZE + wrapped_fek_len;
    }

    // Leak the box and return the pointer (caller must free with encrypt_file_finalize)
    Box::leak(context) as *mut EncryptionContext
}

/// Encrypt a single chunk of data using the encryption context
///
/// This function encrypts one chunk at a time, allowing true streaming encryption
/// with minimal memory usage.
///
/// # Arguments
/// * `context` - Pointer to EncryptionContext from encrypt_file_init()
/// * `chunk_data` - Pointer to chunk data to encrypt
/// * `chunk_len` - Length of chunk data
/// * `chunk_index` - Index of this chunk (must increment for each chunk)
/// * `output_len` - Pointer to store output length
///
/// # Returns
/// Pointer to encrypted chunk (caller must free with free_buffer), or null on error
///
/// Format of returned data: [Chunk Header 20 bytes] + [Encrypted Data]
/// - Chunk Header: index (4) + size (4) + nonce (12)
/// - Encrypted Data: ciphertext + MAC tag
#[no_mangle]
pub extern "C" fn encrypt_chunk(
    context: *mut EncryptionContext,
    chunk_data: *const u8,
    chunk_len: usize,
    chunk_index: u32,
    output_len: *mut usize,
) -> *mut u8 {
    if context.is_null() || chunk_data.is_null() || output_len.is_null() {
        return ptr::null_mut();
    }

    let ctx = unsafe { &mut *context };
    let chunk_slice = unsafe { slice::from_raw_parts(chunk_data, chunk_len) };

    // Update chunk index in context
    ctx.chunk_index = chunk_index;

    // Encrypt chunk
    let encrypted = match encrypt_chunk_impl(chunk_slice, &ctx.fek, chunk_index) {
        Some(data) => data,
        None => return ptr::null_mut(),
    };

    let output_size = encrypted.len();

    // Allocate output buffer
    let output = unsafe {
        let ptr = libc::malloc(output_size) as *mut u8;
        if ptr.is_null() {
            return ptr::null_mut();
        }
        ptr
    };

    // Copy encrypted data
    unsafe {
        ptr::copy_nonoverlapping(encrypted.as_ptr(), output, output_size);
        *output_len = output_size;
    }

    output
}

/// Get the wrapped FEK bytes from the encryption context
///
/// This function retrieves the wrapped FEK that was generated during encrypt_file_init().
/// The wrapped FEK must be written to the output file after the header.
///
/// # Arguments
/// * `context` - Pointer to EncryptionContext from encrypt_file_init()
/// * `output_len` - Pointer to store wrapped FEK length
///
/// # Returns
/// Pointer to wrapped FEK bytes (caller must free with free_buffer), or null on error
#[no_mangle]
pub extern "C" fn encrypt_file_get_wrapped_fek(
    context: *mut EncryptionContext,
    output_len: *mut usize,
) -> *mut u8 {
    if context.is_null() || output_len.is_null() {
        return ptr::null_mut();
    }

    let ctx = unsafe { &*context };
    let wrapped_fek_len = ctx.wrapped_fek.len();

    // Allocate output buffer
    let output = unsafe {
        let ptr = libc::malloc(wrapped_fek_len) as *mut u8;
        if ptr.is_null() {
            return ptr::null_mut();
        }
        ptr
    };

    // Copy wrapped FEK bytes
    unsafe {
        ptr::copy_nonoverlapping(ctx.wrapped_fek.as_ptr(), output, wrapped_fek_len);
        *output_len = wrapped_fek_len;
    }

    output
}

/// Finalize encryption context and free memory
///
/// # Arguments
/// * `context` - Pointer to EncryptionContext from encrypt_file_init()
#[no_mangle]
pub extern "C" fn encrypt_file_finalize(context: *mut EncryptionContext) {
    if !context.is_null() {
        unsafe {
            // Convert back to Box and drop it
            let _ = Box::from_raw(context);
        }
    }
}

/// Initialize decryption context for streaming decryption
///
/// This function parses the encrypted file header and unwraps the FEK.
/// The returned context can be used for decrypting multiple chunks.
///
/// # Arguments
/// * `encrypted_data` - Pointer to encrypted file data (must include header and wrapped FEK)
/// * `encrypted_len` - Length of encrypted data (must be at least header + wrapped FEK)
/// * `master_key` - Pointer to 32-byte Master Key
/// * `master_key_len` - Length of master key (must be 32)
///
/// # Returns
/// Pointer to DecryptionContext, or null on error
///
/// The caller is responsible for:
/// 1. Calling decrypt_chunk() for each chunk of encrypted data
/// 2. Calling decrypt_file_finalize() to free the context
#[no_mangle]
pub extern "C" fn decrypt_file_init(
    encrypted_data: *const u8,
    encrypted_len: usize,
    master_key: *const u8,
    master_key_len: usize,
) -> *mut DecryptionContext {
    if encrypted_data.is_null() || master_key.is_null() {
        return ptr::null_mut();
    }

    if master_key_len != KEY_SIZE {
        return ptr::null_mut();
    }

    if encrypted_len < HEADER_SIZE {
        return ptr::null_mut();
    }

    let encrypted_slice = unsafe { slice::from_raw_parts(encrypted_data, encrypted_len) };
    let master_key_slice = unsafe { slice::from_raw_parts(master_key, master_key_len) };

    // Parse header
    let (magic, version, fek_length) = match parse_header(&encrypted_slice[..HEADER_SIZE]) {
        Ok(result) => result,
        Err(_) => return ptr::null_mut(),
    };

    // Validate magic and version
    if magic != MAGIC || version != VERSION {
        return ptr::null_mut();
    }

    // Validate total size
    if encrypted_len < HEADER_SIZE + fek_length {
        return ptr::null_mut();
    }

    // Extract wrapped FEK
    let wrapped_fek = &encrypted_slice[HEADER_SIZE..HEADER_SIZE + fek_length];

    // Unwrap FEK
    let fek = match unwrap_key(wrapped_fek, master_key_slice) {
        Ok(key) => key,
        Err(_) => return ptr::null_mut(),
    };

    // Create decryption context
    let context = Box::new(DecryptionContext {
        fek,
        chunk_index: 0,
    });

    // Leak the box and return the pointer
    Box::leak(context) as *mut DecryptionContext
}

/// Decrypt a single chunk of encrypted data using the decryption context
///
/// This function decrypts one chunk at a time, allowing true streaming decryption
/// with minimal memory usage.
///
/// # Arguments
/// * `context` - Pointer to DecryptionContext from decrypt_file_init()
/// * `encrypted_chunk` - Pointer to encrypted chunk data (must include chunk header)
/// * `chunk_len` - Length of encrypted chunk data
/// * `output_len` - Pointer to store output length
///
/// # Returns
/// Pointer to decrypted chunk (caller must free with free_buffer), or null on error
#[no_mangle]
pub extern "C" fn decrypt_chunk(
    context: *mut DecryptionContext,
    encrypted_chunk: *const u8,
    chunk_len: usize,
    output_len: *mut usize,
) -> *mut u8 {
    if context.is_null() || encrypted_chunk.is_null() || output_len.is_null() {
        return ptr::null_mut();
    }

    let ctx = unsafe { &mut *context };
    let encrypted_slice = unsafe { slice::from_raw_parts(encrypted_chunk, chunk_len) };

    // Decrypt chunk
    let (plaintext, _chunk_len) = match decrypt_chunk_impl(encrypted_slice, &ctx.fek) {
        Some(result) => result,
        None => return ptr::null_mut(),
    };

    let output_size = plaintext.len();

    // Allocate output buffer
    let output = unsafe {
        let ptr = libc::malloc(output_size) as *mut u8;
        if ptr.is_null() {
            return ptr::null_mut();
        }
        ptr
    };

    // Copy plaintext data
    unsafe {
        ptr::copy_nonoverlapping(plaintext.as_ptr(), output, output_size);
        *output_len = output_size;
    }

    output
}

/// Finalize decryption context and free memory
///
/// # Arguments
/// * `context` - Pointer to DecryptionContext from decrypt_file_init()
#[no_mangle]
pub extern "C" fn decrypt_file_finalize(context: *mut DecryptionContext) {
    if !context.is_null() {
        unsafe {
            // Convert back to Box and drop it
            let _ = Box::from_raw(context);
        }
    }
}

// ============================================================================
// FOLDER SCANNING MODULE EXPORTS
// ============================================================================

// Re-export all folder scanning FFI functions
// These are defined in scan.rs and made available for FFI calls
