#ifndef CLOUD_NEXUS_ENCRYPTION_H
#define CLOUD_NEXUS_ENCRYPTION_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Error codes
#define SUCCESS 0
#define ERROR_NULL_POINTER -1
#define ERROR_INVALID_KEY_SIZE -2
#define ERROR_ENCRYPTION_FAILED -3
#define ERROR_DECRYPTION_FAILED -4
#define ERROR_INVALID_FORMAT -5
#define ERROR_ALLOCATION_FAILED -6

// Constants
#define KEY_SIZE 32
#define NONCE_SIZE 12
#define MAC_SIZE 16

/**
 * Encrypt data with AES-256-GCM
 * 
 * @param data Pointer to data to encrypt
 * @param data_len Length of data
 * @param key Pointer to 32-byte encryption key
 * @param key_len Length of key (must be 32)
 * @param output_len Pointer to store output length
 * @return Pointer to encrypted data (caller must free with free_buffer)
 * 
 * Output format: [nonce 12 bytes] + [ciphertext] + [mac 16 bytes]
 */
uint8_t* encrypt_data(
    const uint8_t* data,
    size_t data_len,
    const uint8_t* key,
    size_t key_len,
    size_t* output_len
);

/**
 * Decrypt data with AES-256-GCM
 * 
 * @param encrypted_data Pointer to encrypted data
 * @param encrypted_len Length of encrypted data
 * @param key Pointer to 32-byte decryption key
 * @param key_len Length of key (must be 32)
 * @param output_len Pointer to store output length
 * @return Pointer to decrypted data (caller must free with free_buffer)
 */
uint8_t* decrypt_data(
    const uint8_t* encrypted_data,
    size_t encrypted_len,
    const uint8_t* key,
    size_t key_len,
    size_t* output_len
);

/**
 * Encrypt file with embedded FEK (Approach 1)
 * 
 * @param file_data Pointer to file data to encrypt
 * @param file_len Length of file data
 * @param fek Pointer to 32-byte File Encryption Key
 * @param fek_len Length of FEK (must be 32)
 * @param master_key Pointer to 32-byte Master Key
 * @param master_key_len Length of master key (must be 32)
 * @param output_len Pointer to store output length
 * @return Pointer to encrypted file data (caller must free with free_buffer)
 * 
 * Format: [Header 60 bytes] + [Encrypted Data] + [MAC 16 bytes]
 * Header: [Magic 4 bytes] + [Version 1 byte] + [Reserved 3 bytes] + [FEK Length 4 bytes] + [Wrapped FEK] + [Nonce 12 bytes]
 */
uint8_t* encrypt_file_with_fek(
    const uint8_t* file_data,
    size_t file_len,
    const uint8_t* fek,
    size_t fek_len,
    const uint8_t* master_key,
    size_t master_key_len,
    size_t* output_len
);

/**
 * Decrypt file with embedded FEK (Approach 1)
 * 
 * @param encrypted_data Pointer to encrypted file data
 * @param encrypted_len Length of encrypted data
 * @param master_key Pointer to 32-byte Master Key
 * @param master_key_len Length of master key (must be 32)
 * @param output_len Pointer to store output length
 * @return Pointer to decrypted file data (caller must free with free_buffer)
 */
uint8_t* decrypt_file_with_fek(
    const uint8_t* encrypted_data,
    size_t encrypted_len,
    const uint8_t* master_key,
    size_t master_key_len,
    size_t* output_len
);

/**
 * Progress callback type for encryption/decryption operations
 *
 * @param bytes_processed Number of bytes processed so far
 * @param total_bytes Total number of bytes to process
 * @param user_data User-provided data pointer
 */
typedef void (*ProgressCallback)(size_t bytes_processed, size_t total_bytes, void* user_data);

/**
 * Encrypt file using streaming encryption (Option 2)
 *
 * @param file_data Pointer to file data to encrypt
 * @param file_len Length of file data
 * @param master_key Pointer to 32-byte Master Key
 * @param master_key_len Length of master key (must be 32)
 * @param output_len Pointer to store output length
 * @param progress_callback Optional progress callback (can be NULL)
 * @param user_data User data to pass to progress callback
 * @return Pointer to encrypted file data (caller must free with free_buffer)
 *
 * Format:
 * [Main Header 12 bytes: magic 4 + version 1 + reserved 3 + fek_len 4] +
 * [Wrapped FEK] +
 * [Chunk Header 36 bytes] + [Chunk Data] +
 * [Chunk Header 36 bytes] + [Chunk Data] + ...
 *
 * Chunk Header: [index 4] + [size 4] + [nonce 12] + [mac 16]
 */
uint8_t* encrypt_file_streaming(
    const uint8_t* file_data,
    size_t file_len,
    const uint8_t* master_key,
    size_t master_key_len,
    size_t* output_len,
    ProgressCallback progress_callback,
    void* user_data
);

/**
 * Decrypt file encrypted with streaming encryption (Option 2)
 *
 * @param encrypted_data Pointer to encrypted file data
 * @param encrypted_len Length of encrypted data
 * @param master_key Pointer to 32-byte Master Key
 * @param master_key_len Length of master key (must be 32)
 * @param output_len Pointer to store output length
 * @param progress_callback Optional progress callback (can be NULL)
 * @param user_data User data to pass to progress callback
 * @return Pointer to decrypted file data (caller must free with free_buffer)
 */
uint8_t* decrypt_file_streaming(
    const uint8_t* encrypted_data,
    size_t encrypted_len,
    const uint8_t* master_key,
    size_t master_key_len,
    size_t* output_len,
    ProgressCallback progress_callback,
    void* user_data
);

/**
 * Simple wrapper for encrypting a file (backward compatible)
 * Uses streaming encryption internally
 *
 * @param file_data Pointer to file data to encrypt
 * @param file_len Length of file data
 * @param master_key Pointer to 32-byte Master Key
 * @param master_key_len Length of master key (must be 32)
 * @param output_len Pointer to store output length
 * @return Pointer to encrypted file data (caller must free with free_buffer)
 */
uint8_t* encrypt_file(
    const uint8_t* file_data,
    size_t file_len,
    const uint8_t* master_key,
    size_t master_key_len,
    size_t* output_len
);

/**
 * Simple wrapper for decrypting a file (backward compatible)
 * Uses streaming decryption internally
 *
 * @param encrypted_data Pointer to encrypted file data
 * @param encrypted_len Length of encrypted data
 * @param master_key Pointer to 32-byte Master Key
 * @param master_key_len Length of master key (must be 32)
 * @param output_len Pointer to store output length
 * @return Pointer to decrypted file data (caller must free with free_buffer)
 */
uint8_t* decrypt_file(
    const uint8_t* encrypted_data,
    size_t encrypted_len,
    const uint8_t* master_key,
    size_t master_key_len,
    size_t* output_len
);

/**
 * Derive key from password using PBKDF2-HMAC-SHA256
 * 
 * @param password Password string (null-terminated)
 * @param salt Pointer to salt
 * @param salt_len Length of salt
 * @param iterations Number of PBKDF2 iterations
 * @param output_key Pointer to store derived key (32 bytes)
 * @return 0 on success, error code on failure
 */
int derive_key_from_password(
    const char* password,
    const uint8_t* salt,
    size_t salt_len,
    uint32_t iterations,
    uint8_t* output_key
);

/**
 * Free memory allocated by Rust
 *
 * @param buffer Pointer to buffer to free
 */
void free_buffer(uint8_t* buffer);

// ============================================================================
// TRUE STREAMING ENCRYPTION API (for low-memory chunk-by-chunk processing)
// ============================================================================

/**
 * Opaque context for streaming encryption
 */
typedef struct EncryptionContext EncryptionContext;

/**
 * Opaque context for streaming decryption
 */
typedef struct DecryptionContext DecryptionContext;

/**
 * Initialize encryption context for streaming encryption
 *
 * This function generates a File Encryption Key (FEK) and wraps it with the master key.
 * The returned context can be used for encrypting multiple chunks.
 *
 * @param master_key Pointer to 32-byte Master Key
 * @param master_key_len Length of master key (must be 32)
 * @param output_len Pointer to store header size (HEADER_SIZE + wrapped_fek_len)
 * @return Pointer to EncryptionContext, or NULL on error
 *
 * The caller is responsible for:
 * 1. Calling encrypt_chunk() for each chunk of data
 * 2. Calling encrypt_file_finalize() to free the context
 *
 * The header bytes can be written to the output file followed by the wrapped FEK.
 */
EncryptionContext* encrypt_file_init(
    const uint8_t* master_key,
    size_t master_key_len,
    size_t* output_len
);

/**
 * Get the wrapped FEK bytes from the encryption context
 *
 * This function retrieves the wrapped FEK that was generated during encrypt_file_init().
 * The wrapped FEK must be written to the output file after the header.
 *
 * @param context Pointer to EncryptionContext from encrypt_file_init()
 * @param output_len Pointer to store wrapped FEK length
 * @return Pointer to wrapped FEK bytes (caller must free with free_buffer), or NULL on error
 */
uint8_t* encrypt_file_get_wrapped_fek(
    EncryptionContext* context,
    size_t* output_len
);

/**
 * Encrypt a single chunk of data using the encryption context
 *
 * This function encrypts one chunk at a time, allowing true streaming encryption
 * with minimal memory usage.
 *
 * @param context Pointer to EncryptionContext from encrypt_file_init()
 * @param chunk_data Pointer to chunk data to encrypt
 * @param chunk_len Length of chunk data
 * @param chunk_index Index of this chunk (must increment for each chunk)
 * @param output_len Pointer to store output length
 * @return Pointer to encrypted chunk (caller must free with free_buffer), or NULL on error
 *
 * Format of returned data: [Chunk Header 20 bytes] + [Encrypted Data]
 * - Chunk Header: index (4) + size (4) + nonce (12)
 * - Encrypted Data: ciphertext + MAC tag
 */
uint8_t* encrypt_chunk(
    EncryptionContext* context,
    const uint8_t* chunk_data,
    size_t chunk_len,
    uint32_t chunk_index,
    size_t* output_len
);

/**
 * Finalize encryption context and free memory
 *
 * @param context Pointer to EncryptionContext from encrypt_file_init()
 */
void encrypt_file_finalize(EncryptionContext* context);

/**
 * Initialize decryption context for streaming decryption
 *
 * This function parses the encrypted file header and unwraps the FEK.
 * The returned context can be used for decrypting multiple chunks.
 *
 * @param encrypted_data Pointer to encrypted file data (must include header and wrapped FEK)
 * @param encrypted_len Length of encrypted data (must be at least header + wrapped FEK)
 * @param master_key Pointer to 32-byte Master Key
 * @param master_key_len Length of master key (must be 32)
 * @return Pointer to DecryptionContext, or NULL on error
 *
 * The caller is responsible for:
 * 1. Calling decrypt_chunk() for each chunk of encrypted data
 * 2. Calling decrypt_file_finalize() to free the context
 */
DecryptionContext* decrypt_file_init(
    const uint8_t* encrypted_data,
    size_t encrypted_len,
    const uint8_t* master_key,
    size_t master_key_len
);

/**
 * Decrypt a single chunk of encrypted data using the decryption context
 *
 * This function decrypts one chunk at a time, allowing true streaming decryption
 * with minimal memory usage.
 *
 * @param context Pointer to DecryptionContext from decrypt_file_init()
 * @param encrypted_chunk Pointer to encrypted chunk data (must include chunk header)
 * @param chunk_len Length of encrypted chunk data
 * @param output_len Pointer to store output length
 * @return Pointer to decrypted chunk (caller must free with free_buffer), or NULL on error
 */
uint8_t* decrypt_chunk(
    DecryptionContext* context,
    const uint8_t* encrypted_chunk,
    size_t chunk_len,
    size_t* output_len
);

/**
 * Finalize decryption context and free memory
 *
 * @param context Pointer to DecryptionContext from decrypt_file_init()
 */
void decrypt_file_finalize(DecryptionContext* context);

// ============================================================================
// FOLDER SCANNING API
// ============================================================================

/**
 * Opaque context for folder scanning
 */
typedef struct FolderScanContext FolderScanContext;

/**
 * Initialize a folder scan operation
 *
 * @param folder_path Path to the folder to scan (null-terminated)
 * @param max_depth Maximum scan depth (0 for unlimited)
 * @return Pointer to FolderScanContext, or NULL on error
 *
 * The caller is responsible for:
 * 1. Calling scan_folder_get_json() or other getter functions
 * 2. Calling scan_folder_free() to free the context
 */
FolderScanContext* scan_folder_init(
    const char* folder_path,
    uint32_t max_depth
);

/**
 * Get the JSON representation of scan results
 *
 * @param context Pointer to FolderScanContext
 * @param output_len Pointer to store output length
 * @return Pointer to JSON string (caller must free with scan_folder_free_string), or NULL on error
 *
 * JSON format:
 * {
 *   "root_path": "C:/path/to/folder",
 *   "items": [
 *     {
 *       "relative_path": "subfolder/file.txt",
 *       "name": "file.txt",
 *       "is_folder": false,
 *       "size": 1024,
 *       "absolute_path": "C:/path/to/folder/subfolder/file.txt"
 *     }
 *   ],
 *   "total_size": 2048,
 *   "file_count": 2,
 *   "folder_count": 1,
 *   "scan_duration_ms": 15
 * }
 */
char* scan_folder_get_json(
    FolderScanContext* context,
    size_t* output_len
);

/**
 * Get the error message if scan failed
 *
 * @param context Pointer to FolderScanContext
 * @param output_len Pointer to store output length
 * @return Pointer to error string (caller must free with scan_folder_free_string), or NULL if no error
 */
char* scan_folder_get_error(
    FolderScanContext* context,
    size_t* output_len
);

/**
 * Check if scan was successful
 *
 * @param context Pointer to FolderScanContext
 * @return 1 if successful, 0 if error occurred
 */
int32_t scan_folder_is_success(FolderScanContext* context);

/**
 * Get file count from scan result
 *
 * @param context Pointer to FolderScanContext
 * @return Number of files, or 0 if no result
 */
uint64_t scan_folder_get_file_count(FolderScanContext* context);

/**
 * Get folder count from scan result
 *
 * @param context Pointer to FolderScanContext
 * @return Number of folders, or 0 if no result
 */
uint64_t scan_folder_get_folder_count(FolderScanContext* context);

/**
 * Get total size from scan result
 *
 * @param context Pointer to FolderScanContext
 * @return Total size in bytes, or 0 if no result
 */
uint64_t scan_folder_get_total_size(FolderScanContext* context);

/**
 * Get scan duration from scan result
 *
 * @param context Pointer to FolderScanContext
 * @return Scan duration in milliseconds, or 0 if no result
 */
uint64_t scan_folder_get_duration_ms(FolderScanContext* context);

/**
 * Free a string allocated by scan_folder_get_json or scan_folder_get_error
 *
 * @param s Pointer to string to free
 */
void scan_folder_free_string(char* s);

/**
 * Free folder scan context
 *
 * @param context Pointer to FolderScanContext to free
 */
void scan_folder_free(FolderScanContext* context);

/**
 * Quick scan function that returns JSON directly
 * This is a convenience function for simple use cases
 *
 * @param folder_path Path to the folder to scan (null-terminated)
 * @param max_depth Maximum scan depth (0 for unlimited)
 * @param output_len Pointer to store output length
 * @return Pointer to JSON string (caller must free with scan_folder_free_string), or NULL on error
 */
char* scan_folder_quick(
    const char* folder_path,
    uint32_t max_depth,
    size_t* output_len
);

// ============================================================================
// UPLOAD API (streaming file uploads with optional encryption)
// ============================================================================

/**
 * Progress callback for upload operations
 */
typedef void (*UploadProgressCallback)(size_t bytes_processed, size_t total_bytes, void* user_data);

/**
 * Data callback for providing encrypted chunks to Dart
 */
typedef void (*UploadDataCallback)(const uint8_t* data, size_t data_len, uint32_t chunk_index, void* user_data);

/**
 * Opaque context for streaming uploads
 */
typedef struct UploadContext UploadContext;

/**
 * Initialize upload context
 */
UploadContext* upload_init(
    const char* local_file_path,
    const uint8_t* master_key,
    size_t master_key_len,
    size_t chunk_size,
    int32_t should_encrypt,
    UploadProgressCallback progress_callback,
    UploadDataCallback data_callback,
    void* cancel_flag,
    void* user_data
);

/**
 * Process next chunk of upload
 */
intptr_t upload_process_chunk(
    UploadContext* context,
    uint8_t* buffer,
    size_t buffer_size,
    UploadProgressCallback progress_callback,
    UploadDataCallback data_callback,
    void* user_data
);

/**
 * Get header and wrapped FEK for upload
 */
int32_t upload_get_header(
    UploadContext* context,
    uint8_t* header_buffer,
    uint8_t* fek_buffer,
    size_t fek_buffer_size,
    size_t* fek_len
);

/**
 * Finalize upload and clean up resources
 */
int32_t upload_finalize(UploadContext* context);

/**
 * Free upload context
 */
void upload_free(UploadContext* context);

/**
 * Get total bytes for upload
 */
size_t upload_get_total_bytes(UploadContext* context);

/**
 * Get bytes processed
 */
size_t upload_get_bytes_processed(UploadContext* context);

/**
 * Copy file streaming for local copies
 */
int32_t copy_file_streaming(
    const char* source_path,
    const char* dest_path,
    size_t chunk_size,
    UploadProgressCallback progress_callback,
    void* cancel_flag,
    void* user_data
);

// ============================================================================
// DOWNLOAD API (streaming file downloads with optional decryption)
// ============================================================================

/**
 * Progress callback for download operations
 */
typedef void (*DownloadProgressCallback)(size_t bytes_written, size_t total_bytes, void* user_data);

/**
 * Opaque context for streaming downloads
 */
typedef struct DownloadContext DownloadContext;

/**
 * Initialize download context
 */
DownloadContext* download_init(
    const char* local_file_path,
    const uint8_t* master_key,
    size_t master_key_len,
    int32_t should_decrypt,
    DownloadProgressCallback progress_callback,
    void* cancel_flag,
    void* user_data
);

/**
 * Initialize download with known total size
 */
DownloadContext* download_init_with_size(
    const char* local_file_path,
    size_t total_bytes,
    const uint8_t* master_key,
    size_t master_key_len,
    int32_t should_decrypt,
    DownloadProgressCallback progress_callback,
    void* cancel_flag,
    void* user_data
);

/**
 * Append encrypted chunk to download stream
 */
int32_t download_append_chunk(
    DownloadContext* context,
    const uint8_t* encrypted_data,
    size_t data_len,
    DownloadProgressCallback progress_callback,
    void* user_data
);

/**
 * Append decrypted data directly
 */
int32_t download_append_decrypted(
    DownloadContext* context,
    const uint8_t* data,
    size_t data_len,
    DownloadProgressCallback progress_callback,
    void* user_data
);

/**
 * Finalize download and clean up resources
 */
int32_t download_finalize(DownloadContext* context);

/**
 * Free download context
 */
void download_free(DownloadContext* context);

/**
 * Get bytes written for download
 */
size_t download_get_bytes_written(DownloadContext* context);

/**
 * Get total bytes for download
 */
size_t download_get_total_bytes(DownloadContext* context);

/**
 * Set total bytes for download
 */
void download_set_total_bytes(DownloadContext* context, size_t total_bytes);

// ============================================================================
// COPY API (file and folder copy operations)
// ============================================================================

typedef struct CopyContext CopyContext;

int32_t copy_file(const char* source_path, const char* dest_path);

CopyContext* folder_copy_init(const char* source_path, const char* dest_path, void* cancel_flag);

int32_t folder_copy_next_file(CopyContext* context, char* dest_path, size_t dest_path_size);

int32_t folder_copy_finalize(CopyContext* context);

void copy_free(CopyContext* context);

// ============================================================================
// CHUNKED STREAMING COPY API (for cross-account transfers)
// ============================================================================

/**
 * Data callback for chunked copy - receives chunk data
 * @param data Pointer to chunk data
 * @param data_len Length of data
 * @param user_data User-provided data pointer
 * @return Bytes written to buffer (negative for error)
 */
typedef intptr_t (*CopyDataCallback)(uint8_t* data, size_t data_len, void* user_data);

/**
 * Opaque context for chunked streaming copy
 */
typedef struct ChunkedCopyContext ChunkedCopyContext;

/**
 * Initialize chunked streaming copy for cross-account transfers
 *
 * @param source_path Source file path
 * @param dest_path Destination file path
 * @param chunk_size Size of chunks in bytes (10MB recommended)
 * @param cancel_flag Cancellation flag pointer
 * @return Pointer to ChunkedCopyContext, or NULL on error
 */
ChunkedCopyContext* chunked_copy_init(
    const char* source_path,
    const char* dest_path,
    size_t chunk_size,
    void* cancel_flag
);

/**
 * Open source file for chunked copy
 *
 * @param context Pointer to ChunkedCopyContext
 * @return 0 on success, negative error code on failure
 */
int32_t chunked_copy_open_source(ChunkedCopyContext* context);

/**
 * Read next chunk from source file
 *
 * @param context Pointer to ChunkedCopyContext
 * @param buffer Buffer to write chunk data
 * @param buffer_size Size of buffer
 * @param data_callback Callback to receive chunk data (optional, can be NULL)
 * @param user_data User data for callback
 * @return Number of bytes read (0 for EOF), negative error code on failure
 */
intptr_t chunked_copy_read_chunk(
    ChunkedCopyContext* context,
    uint8_t* buffer,
    size_t buffer_size,
    CopyDataCallback data_callback,
    void* user_data
);

/**
 * Write chunk to destination file
 *
 * @param context Pointer to ChunkedCopyContext
 * @param data Pointer to data to write
 * @param data_len Length of data
 * @param progress_callback Optional progress callback
 * @param user_data User data for callback
 * @return 0 on success, negative error code on failure
 */
int32_t chunked_copy_write_chunk(
    ChunkedCopyContext* context,
    const uint8_t* data,
    size_t data_len,
    UploadProgressCallback progress_callback,
    void* user_data
);

/**
 * Flush destination file
 *
 * @param context Pointer to ChunkedCopyContext
 * @return 0 on success, negative error code on failure
 */
int32_t chunked_copy_flush(ChunkedCopyContext* context);

/**
 * Finalize chunked copy
 *
 * @param context Pointer to ChunkedCopyContext
 * @param progress_callback Optional final progress callback
 * @param user_data User data for callback
 * @return 0 on success, negative error code on failure
 */
int32_t chunked_copy_finalize(
    ChunkedCopyContext* context,
    UploadProgressCallback progress_callback,
    void* user_data
);

/**
 * Free chunked copy context
 *
 * @param context Pointer to ChunkedCopyContext
 */
void chunked_copy_free(ChunkedCopyContext* context);

/**
 * Get chunked copy progress
 *
 * @param context Pointer to ChunkedCopyContext
 * @param bytes_copied Pointer to store bytes copied
 * @param total_bytes Pointer to store total bytes
 */
void chunked_copy_get_progress(
    ChunkedCopyContext* context,
    size_t* bytes_copied,
    size_t* total_bytes
);

// ============================================================================
// CLOUD-TO-CLOUD STREAMING COPY (Rust-orchestrated)
// ============================================================================

/**
 * Opaque context for cloud-to-cloud streaming copy
 */
typedef struct CloudCopyContext CloudCopyContext;

/**
 * Read callback for cloud copy - Dart provides data from source stream
 * @param buffer Buffer to fill with data
 * @param buffer_size Size of buffer
 * @param user_data User-provided data pointer
 * @return Bytes read (0 for EOF), negative for error
 */
typedef int64_t (*CloudCopyReadCallback)(uint8_t* buffer, size_t buffer_size, void* user_data);

/**
 * Write callback for cloud copy - Dart receives data for destination stream
 * @param data Pointer to data
 * @param data_len Length of data
 * @param user_data User-provided data pointer
 * @return 0 on success, negative for error
 */
typedef int32_t (*CloudCopyWriteCallback)(const uint8_t* data, size_t data_len, void* user_data);

/**
 * Initialize cloud-to-cloud streaming copy context
 *
 * Rust orchestrates copy loop: read from source → write to destination
 *
 * @param chunk_size Size of chunks in bytes (10MB recommended)
 * @param total_bytes Total bytes to transfer (0 if unknown)
 * @param cancel_flag Cancellation flag pointer
 * @return Pointer to CloudCopyContext, or NULL on error
 */
CloudCopyContext* cloud_copy_init(
    size_t chunk_size,
    size_t total_bytes,
    void* cancel_flag
);

/**
 * Execute one chunk of cloud-to-cloud copy
 *
 * Rust orchestrates: read callback → write callback
 *
 * @param context Pointer to CloudCopyContext
 * @param read_buffer Buffer for read operation
 * @param buffer_size Size of read buffer
 * @param read_callback Callback to read data from source
 * @param write_callback Callback to write data to destination
 * @param user_data User data for callbacks
 * @return Number of bytes processed (0 for EOF), negative error code on failure
 */
int64_t cloud_copy_process_chunk(
    CloudCopyContext* context,
    uint8_t* read_buffer,
    size_t buffer_size,
    CloudCopyReadCallback read_callback,
    CloudCopyWriteCallback write_callback,
    void* user_data
);

/**
 * Finalize cloud-to-cloud copy
 *
 * @param context Pointer to CloudCopyContext
 * @return 0 on success, error code on failure
 */
int32_t cloud_copy_finalize(CloudCopyContext* context);

/**
 * Free cloud copy context
 *
 * @param context Pointer to CloudCopyContext
 */
void cloud_copy_free(CloudCopyContext* context);

/**
 * Get cloud copy progress
 *
 * @param context Pointer to CloudCopyContext
 * @param bytes_copied Pointer to store bytes copied
 * @param total_bytes Pointer to store total bytes
 */
void cloud_copy_get_progress(
    CloudCopyContext* context,
    size_t* bytes_copied,
    size_t* total_bytes
);

// ============================================================================
// ERROR CODES (extended for file operations)
// ============================================================================

#define ERROR_FILE_NOT_FOUND -7
#define ERROR_PERMISSION_DENIED -8
#define ERROR_IO_FAILED -9
#define ERROR_CANCELLED -10
#define ERROR_INVALID_PATH -11
#define ERROR_DISK_FULL -12

// ============================================================================
// UNIFIED CLOUD COPY API (single method for all copy operations)
// ============================================================================

/**
 * Opaque context for unified cloud copy
 * Works for ANY source/destination combination:
 * - GDrive → GDrive
 * - GDrive → OneDrive
 * - OneDrive → GDrive
 * - OneDrive → OneDrive
 */
typedef struct UnifiedCopyContext UnifiedCopyContext;

/**
 * Progress callback for unified copy operations
 * @param bytes_copied Number of bytes copied so far
 * @param total_bytes Total bytes to copy
 * @param files_processed Number of files processed
 * @param total_files Total number of files
 * @param user_data User-provided data pointer
 */
typedef void (*UnifiedProgressCallback)(
    uint64_t bytes_copied,
    uint64_t total_bytes,
    uint32_t files_processed,
    uint32_t total_files,
    void* user_data
);

/**
 * Read callback: Dart downloads chunk from source cloud into buffer
 * @param buffer RAM buffer to fill with downloaded data
 * @param buffer_size Size of buffer
 * @param offset File offset to read from
 * @param user_data User data
 * @return Number of bytes read (0 for EOF, negative for error)
 */
typedef int64_t (*UnifiedReadCallback)(
    uint8_t* buffer,
    size_t buffer_size,
    uint64_t offset,
    void* user_data
);

/**
 * Write callback: Dart uploads chunk from buffer to destination cloud
 * @param data Pointer to chunk data in RAM
 * @param data_len Length of data
 * @param offset File offset to write to
 * @param user_data User data
 * @return 0 on success, negative on error
 */
typedef int32_t (*UnifiedWriteCallback)(
    const uint8_t* data,
    size_t data_len,
    uint64_t offset,
    void* user_data
);

/**
 * Initialize unified copy context
 *
 * @param total_bytes Total bytes to copy across all files
 * @param total_files Total number of files to copy
 * @param chunk_size Size of chunks in bytes (64KB minimum, 10MB maximum)
 * @param cancel_flag Pointer to AtomicBool for cancellation (can be NULL)
 * @return Pointer to UnifiedCopyContext, or NULL on error
 */
UnifiedCopyContext* unified_copy_init(
    uint64_t total_bytes,
    uint32_t total_files,
    size_t chunk_size,
    void* cancel_flag
);

/**
 * Process one file copy operation
 *
 * This function orchestrates the download→upload→clear loop:
 * 1. Download chunk from source (via read_callback)
 * 2. Chunk is now in RAM buffer
 * 3. Upload chunk to destination (via write_callback)
 * 4. Clear RAM buffer (automatic - buffer reused for next chunk)
 * 5. Repeat until EOF
 *
 * @param context Pointer to UnifiedCopyContext
 * @param read_buffer Pre-allocated RAM buffer for chunk data
 * @param buffer_size Size of buffer (should match chunk_size)
 * @param file_size Size of file being copied
 * @param read_callback Callback to download chunk from source
 * @param write_callback Callback to upload chunk to destination
 * @param progress_callback Optional progress callback
 * @param user_data User data for callbacks
 * @return 1 if more files to process, 0 if done, negative error code on failure
 */
int32_t unified_copy_file(
    UnifiedCopyContext* context,
    uint8_t* read_buffer,
    size_t buffer_size,
    uint64_t file_size,
    UnifiedReadCallback read_callback,
    UnifiedWriteCallback write_callback,
    UnifiedProgressCallback progress_callback,
    void* user_data
);

/**
 * Finalize copy operation and send final progress update
 *
 * @param context Pointer to UnifiedCopyContext
 * @param progress_callback Optional final progress callback
 * @param user_data User data for callback
 * @return 0 on success, error code on failure
 */
int32_t unified_copy_finalize(
    UnifiedCopyContext* context,
    UnifiedProgressCallback progress_callback,
    void* user_data
);

/**
 * Free unified copy context
 *
 * @param context Pointer to UnifiedCopyContext to free
 */
void unified_copy_free(UnifiedCopyContext* context);

/**
 * Get copy progress
 *
 * @param context Pointer to UnifiedCopyContext
 * @param bytes_copied Pointer to store bytes copied
 * @param total_bytes Pointer to store total bytes
 * @param files_processed Pointer to store files processed
 * @param total_files Pointer to store total files
 */
void unified_copy_get_progress(
    UnifiedCopyContext* context,
    uint64_t* bytes_copied,
    uint64_t* total_bytes,
    uint32_t* files_processed,
    uint32_t* total_files
);

/**
 * Get bytes copied so far (simple accessor)
 *
 * @param context Pointer to UnifiedCopyContext
 * @return Bytes copied, or 0 if invalid context
 */
uint64_t unified_copy_get_bytes_copied(UnifiedCopyContext* context);

/**
 * Get total bytes (simple accessor)
 *
 * @param context Pointer to UnifiedCopyContext
 * @return Total bytes, or 0 if invalid context
 */
uint64_t unified_copy_get_total_bytes(UnifiedCopyContext* context);

/**
 * Get files processed (simple accessor)
 *
 * @param context Pointer to UnifiedCopyContext
 * @return Files processed, or 0 if invalid context
 */
uint32_t unified_copy_get_files_processed(UnifiedCopyContext* context);

/**
 * Get total files (simple accessor)
 *
 * @param context Pointer to UnifiedCopyContext
 * @return Total files, or 0 if invalid context
 */
uint32_t unified_copy_get_total_files(UnifiedCopyContext* context);

#ifdef __cplusplus
}
#endif

#endif // CLOUD_NEXUS_ENCRYPTION_H