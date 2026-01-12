/// Encryption operations for CloudNexus
/// AES-256-GCM encryption with streaming support
use aes_gcm::{
    aead::{Aead, KeyInit, OsRng},
    Aes256Gcm, Nonce,
};
use rand::RngCore;
use std::ffi::c_void;
use std::slice;
use std::ptr;

// Constants
pub const MAGIC: u32 = 0x434E4552; // "CNER"
pub const VERSION: u8 = 1;
pub const NONCE_SIZE: usize = 12;
pub const MAC_SIZE: usize = 16;
pub const KEY_SIZE: usize = 32;
pub const HEADER_SIZE: usize = 4 + 1 + 3 + 4; // magic + version + reserved + fek_length
pub const CHUNK_HEADER_SIZE: usize = 4 + 4 + 12 + 16; // index + size + nonce + mac
pub const DEFAULT_CHUNK_SIZE: usize = 1024 * 1024; // 1MB chunks

// ============================================================================
// TRUE STREAMING ENCRYPTION CONTEXTS
// ============================================================================

/// Encryption context for streaming encryption
/// Holds the FEK and wrapped FEK for chunk-by-chunk encryption
#[repr(C)]
pub struct EncryptionContext {
    pub fek: [u8; KEY_SIZE],
    pub wrapped_fek: Vec<u8>,
    pub header: [u8; HEADER_SIZE],
    pub chunk_index: u32,
}

/// Decryption context for streaming decryption
/// Holds the FEK for chunk-by-chunk decryption
#[repr(C)]
pub struct DecryptionContext {
    pub fek: Vec<u8>,
    pub chunk_index: u32,
}

// Helper functions

pub fn wrap_key(key: &[u8], master_key: &[u8]) -> Vec<u8> {
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

pub fn unwrap_key(wrapped_key: &[u8], master_key: &[u8]) -> Result<Vec<u8>, ()> {
    if wrapped_key.len() < NONCE_SIZE + MAC_SIZE {
        return Err(());
    }

    let nonce = Nonce::from_slice(&wrapped_key[..NONCE_SIZE]);
    let ciphertext = &wrapped_key[NONCE_SIZE..];

    let cipher = Aes256Gcm::new_from_slice(master_key).unwrap();
    cipher.decrypt(nonce, ciphertext.as_ref()).map_err(|_| ())
}

pub fn build_header(fek_length: u32) -> [u8; HEADER_SIZE] {
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

pub fn parse_header(header: &[u8]) -> Result<(u32, u8, usize), ()> {
    if header.len() < HEADER_SIZE {
        return Err(());
    }

    let magic = u32::from_le_bytes([header[0], header[1], header[2], header[3]]);
    let version = header[4];
    let fek_length = u32::from_le_bytes([header[8], header[9], header[10], header[11]]) as usize;

    Ok((magic, version, fek_length))
}

// ============================================================================
// CHUNK ENCRYPTION/DECRYPTION
// ============================================================================

pub fn encrypt_chunk_impl(data: &[u8], fek: &[u8], chunk_index: u32) -> Option<Vec<u8>> {
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
    chunk.extend_from_slice(&(ciphertext.len() as u32).to_le_bytes());
    
    // Nonce
    chunk.extend_from_slice(&nonce_bytes);
    
    // Encrypted data (ciphertext which includes MAC tag)
    chunk.extend_from_slice(&ciphertext);

    Some(chunk)
}

pub fn decrypt_chunk_impl(encrypted_data: &[u8], fek: &[u8]) -> Option<(Vec<u8>, usize)> {
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

    // Calculate total chunk length
    let chunk_len = 20 + encrypted_content.len();

    Some((plaintext, chunk_len))
}

