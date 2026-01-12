use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Instant;

// ============================================================================
// DATA STRUCTURES
// ============================================================================

/// Result of folder scan operation
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FolderScanResult {
    /// Absolute path to folder
    pub root_path: String,
    
    /// List of all items (files and folders)
    pub items: Vec<FolderScanItem>,
    
    /// Total size of all files in bytes
    pub total_size: u64,
    
    /// Number of files
    pub file_count: u64,
    
    /// Number of folders
    pub folder_count: u64,
    
    /// Duration of scan in milliseconds
    pub scan_duration_ms: u64,
}

/// Single item in folder scan
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FolderScanItem {
    /// Relative path from root folder
    pub relative_path: String,
    
    /// File or folder name
    pub name: String,
    
    /// Whether item is a folder
    pub is_folder: bool,
    
    /// File size in bytes (0 for folders)
    pub size: u64,
    
    /// Absolute path
    pub absolute_path: String,
}

/// Error result for folder scan
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FolderScanError {
    pub error_message: String,
    pub item_path: Option<String>,
}

// ============================================================================
// SYNC FOLDER SCANNING
// ============================================================================

/// Scan folder synchronously with optimized directory traversal
///
/// # Arguments
/// * `root_path` - Absolute path to the folder to scan
/// * `max_depth` - Optional maximum depth to scan (None for unlimited)
///
/// # Returns
/// Result containing FolderScanResult or error string
pub fn scan_folder_sync(
    root_path: &str,
    max_depth: Option<u64>,
) -> Result<FolderScanResult, String> {
    let start_time = Instant::now();
    
    let root = Path::new(root_path);
    
    // Validate root path exists and is a directory
    if !root.exists() {
        return Err(format!("Path does not exist: {}", root_path));
    }
    
    if !root.is_dir() {
        return Err(format!("Path is not a directory: {}", root_path));
    }
    
    let mut items = Vec::new();
    let mut total_size: u64 = 0;
    let mut file_count: u64 = 0;
    let mut folder_count: u64 = 0;
    
    let max_depth = max_depth.unwrap_or(u64::MAX);
    
    // Use a stack for iterative depth-first traversal
    // This avoids stack overflow on deep folder structures
    let mut stack = vec![(PathBuf::from(root_path), 0u64)];
    
    while let Some((current_path, current_depth)) = stack.pop() {
        if current_depth > max_depth {
            continue;
        }
        
        // Read directory entries
        let dir_entries = match fs::read_dir(&current_path) {
            Ok(entries) => entries,
            Err(e) => {
                eprintln!("Failed to read directory {}: {}", current_path.display(), e);
                continue;
            }
        };
        
        // Collect entries first to sort them
        let mut entries: Vec<_> = dir_entries
            .filter_map(|e| e.ok())
            .collect();
        
        // Sort entries: folders first, then files, both alphabetically
        entries.sort_by(|a, b| {
            let a_is_dir = a.path().is_dir();
            let b_is_dir = b.path().is_dir();
            
            match (a_is_dir, b_is_dir) {
                (true, false) => std::cmp::Ordering::Less,
                (false, true) => std::cmp::Ordering::Greater,
                _ => a.file_name().cmp(&b.file_name()),
            }
        });
        
        for entry in entries {
            let entry_path = entry.path();
            
            // Skip symlinks to avoid infinite loops
            if entry_path.is_symlink() {
                continue;
            }
            
            if entry_path.is_dir() {
                // It's a subfolder
                folder_count += 1;
                
                let relative_path = entry_path
                    .strip_prefix(root)
                    .map(|p| p.to_string_lossy().replace('\\', "/"))
                    .unwrap_or_else(|_| entry_path.to_string_lossy().to_string());
                
                items.push(FolderScanItem {
                    name: entry.file_name().to_string_lossy().to_string(),
                    relative_path: relative_path.clone(),
                    is_folder: true,
                    size: 0,
                    absolute_path: entry_path.to_string_lossy().to_string(),
                });
                
                // Add to stack for deeper traversal
                stack.push((entry_path, current_depth + 1));
            } else {
                // It's a file
                let metadata = match entry.metadata() {
                    Ok(m) => m,
                    Err(_) => continue,
                };
                
                let size = metadata.len();
                total_size += size;
                file_count += 1;
                
                let relative_path = entry_path
                    .strip_prefix(root)
                    .map(|p| p.to_string_lossy().replace('\\', "/"))
                    .unwrap_or_else(|_| entry_path.to_string_lossy().to_string());
                
                items.push(FolderScanItem {
                    name: entry.file_name().to_string_lossy().to_string(),
                    relative_path: relative_path.clone(),
                    is_folder: false,
                    size,
                    absolute_path: entry_path.to_string_lossy().to_string(),
                });
            }
        }
    }
    
    Ok(FolderScanResult {
        root_path: root_path.to_string(),
        items,
        total_size,
        file_count,
        folder_count,
        scan_duration_ms: start_time.elapsed().as_millis() as u64,
    })
}

// ============================================================================
// C FFI INTERFACE
// ============================================================================

/// Folder scan result handle (opaque pointer)
pub struct FolderScanContext {
    result: Option<FolderScanResult>,
    error: Option<String>,
}

impl FolderScanContext {
    pub fn new() -> Self {
        FolderScanContext {
            result: None,
            error: None,
        }
    }
    
    pub fn set_result(&mut self, result: FolderScanResult) {
        self.result = Some(result);
    }
    
    pub fn set_error(&mut self, error: String) {
        self.error = Some(error);
    }
    
    pub fn get_result(&self) -> Option<&FolderScanResult> {
        self.result.as_ref()
    }
    
    pub fn get_error(&self) -> Option<&str> {
        self.error.as_deref()
    }
}

/// Initialize a folder scan operation
///
/// # Arguments
/// * `folder_path` - Path to the folder to scan
/// * `max_depth` - Maximum scan depth (0 for unlimited)
///
/// # Returns
/// Pointer to FolderScanContext, or null on error
#[no_mangle]
pub extern "C" fn scan_folder_init(
    folder_path: *const std::os::raw::c_char,
    max_depth: u32,
) -> *mut FolderScanContext {
    if folder_path.is_null() {
        return std::ptr::null_mut();
    }
    
    // Convert C string to Rust string
    let path_str = unsafe {
        std::ffi::CStr::from_ptr(folder_path)
            .to_str()
            .map(|s| s.to_string())
    };
    
    let path_str = match path_str {
        Ok(s) => s,
        Err(_) => return std::ptr::null_mut(),
    };
    
    // Perform the scan
    let max_depth = if max_depth == 0 { None } else { Some(max_depth as u64) };
    let result = scan_folder_sync(&path_str, max_depth);
    
    // Create context
    let mut context = Box::new(FolderScanContext::new());
    
    match result {
        Ok(scan_result) => context.set_result(scan_result),
        Err(error) => context.set_error(error),
    }
    
    Box::leak(context) as *mut FolderScanContext
}

/// Get the JSON representation of scan results
///
/// # Arguments
/// * `context` - Pointer to FolderScanContext
/// * `output_len` - Pointer to store output length
///
/// # Returns
/// Pointer to JSON string (caller must free), or null on error
#[no_mangle]
pub extern "C" fn scan_folder_get_json(
    context: *mut FolderScanContext,
    output_len: *mut usize,
) -> *mut std::os::raw::c_char {
    if context.is_null() || output_len.is_null() {
        return std::ptr::null_mut();
    }
    
    let ctx = unsafe { &*context };
    
    let result = match ctx.get_result() {
        Some(r) => r,
        None => return std::ptr::null_mut(),
    };
    
    // Serialize to JSON
    let json_str = serde_json::to_string(result).unwrap_or_else(|_| "{}".to_string());
    
    // Allocate C string
    let c_str = std::ffi::CString::new(json_str)
        .unwrap_or_else(|_| std::ffi::CString::new("[]").unwrap());
    
    unsafe {
        *output_len = c_str.as_bytes_with_nul().len();
    }
    
    // Leak the CString and return raw pointer
    c_str.into_raw()
}

/// Get the error message if scan failed
///
/// # Arguments
/// * `context` - Pointer to FolderScanContext
/// * `output_len` - Pointer to store output length
///
/// # Returns
/// Pointer to error string (caller must free), or null if no error
#[no_mangle]
pub extern "C" fn scan_folder_get_error(
    context: *mut FolderScanContext,
    output_len: *mut usize,
) -> *mut std::os::raw::c_char {
    if context.is_null() || output_len.is_null() {
        return std::ptr::null_mut();
    }
    
    let ctx = unsafe { &*context };
    
    let error = match ctx.get_error() {
        Some(e) => e,
        None => return std::ptr::null_mut(),
    };
    
    // Allocate C string
    let c_str = std::ffi::CString::new(error)
        .unwrap_or_else(|_| std::ffi::CString::new("Unknown error").unwrap());
    
    unsafe {
        *output_len = c_str.as_bytes_with_nul().len();
    }
    
    // Leak the CString and return raw pointer
    c_str.into_raw()
}

/// Check if scan was successful
///
/// # Arguments
/// * `context` - Pointer to FolderScanContext
///
/// # Returns
/// 1 if successful, 0 if error occurred
#[no_mangle]
pub extern "C" fn scan_folder_is_success(context: *mut FolderScanContext) -> i32 {
    if context.is_null() {
        return 0;
    }
    
    let ctx = unsafe { &*context };
    
    if ctx.get_result().is_some() {
        1
    } else {
        0
    }
}

/// Get file count from scan result
///
/// # Arguments
/// * `context` - Pointer to FolderScanContext
///
/// # Returns
/// Number of files, or 0 if no result
#[no_mangle]
pub extern "C" fn scan_folder_get_file_count(context: *mut FolderScanContext) -> u64 {
    if context.is_null() {
        return 0;
    }
    
    let ctx = unsafe { &*context };
    
    ctx.get_result()
        .map(|r| r.file_count)
        .unwrap_or(0)
}

/// Get folder count from scan result
///
/// # Arguments
/// * `context` - Pointer to FolderScanContext
///
/// # Returns
/// Number of folders, or 0 if no result
#[no_mangle]
pub extern "C" fn scan_folder_get_folder_count(context: *mut FolderScanContext) -> u64 {
    if context.is_null() {
        return 0;
    }
    
    let ctx = unsafe { &*context };
    
    ctx.get_result()
        .map(|r| r.folder_count)
        .unwrap_or(0)
}

/// Get total size from scan result
///
/// # Arguments
/// * `context` - Pointer to FolderScanContext
///
/// # Returns
/// Total size in bytes, or 0 if no result
#[no_mangle]
pub extern "C" fn scan_folder_get_total_size(context: *mut FolderScanContext) -> u64 {
    if context.is_null() {
        return 0;
    }
    
    let ctx = unsafe { &*context };
    
    ctx.get_result()
        .map(|r| r.total_size)
        .unwrap_or(0)
}

/// Get scan duration from scan result
///
/// # Arguments
/// * `context` - Pointer to FolderScanContext
///
/// # Returns
/// Scan duration in milliseconds, or 0 if no result
#[no_mangle]
pub extern "C" fn scan_folder_get_duration_ms(context: *mut FolderScanContext) -> u64 {
    if context.is_null() {
        return 0;
    }
    
    let ctx = unsafe { &*context };
    
    ctx.get_result()
        .map(|r| r.scan_duration_ms)
        .unwrap_or(0)
}

/// Free a string allocated by scan_folder_get_json or scan_folder_get_error
#[no_mangle]
pub extern "C" fn scan_folder_free_string(s: *mut std::os::raw::c_char) {
    if !s.is_null() {
        unsafe {
            let _ = std::ffi::CString::from_raw(s);
        }
    }
}

/// Free the folder scan context
///
/// # Arguments
/// * `context` - Pointer to FolderScanContext to free
#[no_mangle]
pub extern "C" fn scan_folder_free(context: *mut FolderScanContext) {
    if !context.is_null() {
        unsafe {
            let _ = Box::from_raw(context);
        }
    }
}

// ============================================================================
// CONVENIENCE FUNCTIONS
// ============================================================================

/// Quick scan function that returns JSON directly
/// This is a convenience function for simple use cases
///
/// # Arguments
/// * `folder_path` - Path to the folder to scan
/// * `max_depth` - Maximum scan depth (0 for unlimited)
/// * `output_len` - Pointer to store output length
///
/// # Returns
/// Pointer to JSON string (caller must free with scan_folder_free_string), or null on error
#[no_mangle]
pub extern "C" fn scan_folder_quick(
    folder_path: *const std::os::raw::c_char,
    max_depth: u32,
    output_len: *mut usize,
) -> *mut std::os::raw::c_char {
    // Initialize scan
    let context = scan_folder_init(folder_path, max_depth);
    
    if context.is_null() {
        return std::ptr::null_mut();
    }
    
    // Get JSON result
    let json_ptr = scan_folder_get_json(context, output_len);
    
    // Free context (we only need the JSON)
    scan_folder_free(context);
    
    json_ptr
}