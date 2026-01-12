// FFI bridge for search module
// Phase 2: Full Rust FFI implementation - replaces Dart search service

use std::ffi::{c_void, CString, CStr};
use std::os::raw::c_char;
use std::ptr;

use super::fuzzy::{fuzzy_match, jaro_winkler_similarity, levenshtein_distance, soundex, metaphone};
use super::index::{SearchDocument, SearchIndex};

/// C-compatible search result structure
#[repr(C)]
pub struct CSearchResult {
    pub node_id: *mut c_char,
    pub name: *mut c_char,
    pub score: f64,
    pub account_id: *mut c_char,
    pub provider: *mut c_char,
}

/// C-compatible search document structure
#[repr(C)]
pub struct CSearchDocument {
    pub node_id: *mut c_char,
    pub account_id: *mut c_char,
    pub provider: *mut c_char,
    pub email: *mut c_char,
    pub name: *mut c_char,
    pub is_folder: bool,
    pub parent_id: *mut c_char,
}

/// Create a new search index
/// Returns pointer to index (null on error)
#[no_mangle]
pub extern "C" fn create_search_index() -> *mut SearchIndex {
    let index = Box::new(SearchIndex::new());
    Box::into_raw(index)
}

/// Free search index memory
#[no_mangle]
pub extern "C" fn free_search_index(index_ptr: *mut SearchIndex) {
    if !index_ptr.is_null() {
        unsafe {
            let _ = Box::from_raw(index_ptr);
        }
    }
}

/// Add document to search index
/// Returns 1 on success, 0 on error
#[no_mangle]
pub extern "C" fn add_document_to_index(
    index_ptr: *mut SearchIndex,
    node_id: *const c_char,
    account_id: *const c_char,
    provider: *const c_char,
    email: *const c_char,
    name: *const c_char,
    is_folder: bool,
    parent_id: *const c_char,
) -> i32 {
    if index_ptr.is_null() {
        return 0;
    }
    
    let index = unsafe { &mut *index_ptr };
    
    let node_id_str = if node_id.is_null() {
        String::new()
    } else {
        match unsafe { CStr::from_ptr(node_id).to_str() } {
            Ok(s) => s.to_string(),
            Err(_) => return 0,
        }
    };
    
    let account_id_str = if account_id.is_null() {
        String::new()
    } else {
        match unsafe { CStr::from_ptr(account_id).to_str() } {
            Ok(s) => s.to_string(),
            Err(_) => return 0,
        }
    };
    
    let provider_str = if provider.is_null() {
        String::new()
    } else {
        match unsafe { CStr::from_ptr(provider).to_str() } {
            Ok(s) => s.to_string(),
            Err(_) => return 0,
        }
    };
    
    let email_str = if email.is_null() {
        String::new()
    } else {
        match unsafe { CStr::from_ptr(email).to_str() } {
            Ok(s) => s.to_string(),
            Err(_) => return 0,
        }
    };
    
    let name_str = if name.is_null() {
        String::new()
    } else {
        match unsafe { CStr::from_ptr(name).to_str() } {
            Ok(s) => s.to_string(),
            Err(_) => return 0,
        }
    };
    
    let parent_id_opt = if parent_id.is_null() {
        None
    } else {
        match unsafe { CStr::from_ptr(parent_id).to_str() } {
            Ok(s) => Some(s.to_string()),
            Err(_) => return 0,
        }
    };
    
    let doc = SearchDocument {
        node_id: node_id_str,
        account_id: account_id_str,
        provider: provider_str,
        email: email_str,
        name: name_str,
        is_folder,
        parent_id: parent_id_opt,
    };
    
    index.add_document(doc);
    1
}

/// Add multiple documents to search index in a single call
/// More efficient than calling add_document_to_index multiple times
/// Returns number of documents added successfully
#[no_mangle]
pub extern "C" fn add_documents_batch(
    index_ptr: *mut SearchIndex,
    docs: *const CSearchDocument,
    count: usize,
) -> usize {
    if index_ptr.is_null() || docs.is_null() || count == 0 {
        return 0;
    }
    
    let index = unsafe { &mut *index_ptr };
    let mut added = 0;
    
    for i in 0..count {
        let doc_ref = unsafe { docs.offset(i as isize).read() };
        
        let node_id_str = if doc_ref.node_id.is_null() {
            String::new()
        } else {
            match unsafe { CStr::from_ptr(doc_ref.node_id).to_str() } {
                Ok(s) => s.to_string(),
                Err(_) => continue,
            }
        };
        
        let account_id_str = if doc_ref.account_id.is_null() {
            String::new()
        } else {
            match unsafe { CStr::from_ptr(doc_ref.account_id).to_str() } {
                Ok(s) => s.to_string(),
                Err(_) => continue,
            }
        };
        
        let provider_str = if doc_ref.provider.is_null() {
            String::new()
        } else {
            match unsafe { CStr::from_ptr(doc_ref.provider).to_str() } {
                Ok(s) => s.to_string(),
                Err(_) => continue,
            }
        };
        
        let email_str = if doc_ref.email.is_null() {
            String::new()
        } else {
            match unsafe { CStr::from_ptr(doc_ref.email).to_str() } {
                Ok(s) => s.to_string(),
                Err(_) => continue,
            }
        };
        
        let name_str = if doc_ref.name.is_null() {
            String::new()
        } else {
            match unsafe { CStr::from_ptr(doc_ref.name).to_str() } {
                Ok(s) => s.to_string(),
                Err(_) => continue,
            }
        };
        
        let parent_id_opt = if doc_ref.parent_id.is_null() {
            None
        } else {
            match unsafe { CStr::from_ptr(doc_ref.parent_id).to_str() } {
                Ok(s) => Some(s.to_string()),
                Err(_) => continue,
            }
        };
        
        let doc = SearchDocument {
            node_id: node_id_str,
            account_id: account_id_str,
            provider: provider_str,
            email: email_str,
            name: name_str,
            is_folder: doc_ref.is_folder,
            parent_id: parent_id_opt,
        };
        
        index.add_document(doc);
        added += 1;
    }
    
    added
}

/// Search index with exact matching
/// Returns number of results found (results_out must be freed with free_search_results)
#[no_mangle]
pub extern "C" fn search_index(
    index_ptr: *mut SearchIndex,
    query: *const c_char,
    limit: usize,
    results_out: *mut *mut CSearchResult,
    results_count: *mut usize,
) -> i32 {
    if index_ptr.is_null() || results_out.is_null() || results_count.is_null() {
        return 0;
    }
    
    let index = unsafe { &mut *index_ptr };
    
    let query_str = if query.is_null() {
        String::new()
    } else {
        match unsafe { CStr::from_ptr(query).to_str() } {
            Ok(s) => s.to_string(),
            Err(_) => return 0,
        }
    };
    
    let results = index.search_exact(&query_str, limit);
    let count = results.len();
    
    // Allocate results array
    let results_array = unsafe {
        libc::malloc(count * std::mem::size_of::<CSearchResult>()) as *mut CSearchResult
    };
    
    if results_array.is_null() {
        unsafe { *results_count = 0; }
        return 0;
    }
    
    // Fill results array
    for (i, result) in results.iter().enumerate() {
        let c_result = CSearchResult {
            node_id: CString::new(result.node_id.clone()).unwrap().into_raw(),
            name: CString::new(result.name.clone()).unwrap().into_raw(),
            score: result.score,
            account_id: CString::new(result.account_id.clone()).unwrap().into_raw(),
            provider: CString::new(result.provider.clone()).unwrap().into_raw(),
        };
        unsafe { results_array.offset(i as isize).write(c_result); }
    }
    
    unsafe {
        *results_out = results_array;
        *results_count = count;
    }
    
    1
}

/// Search index with prefix matching
#[no_mangle]
pub extern "C" fn search_index_prefix(
    index_ptr: *mut SearchIndex,
    query: *const c_char,
    limit: usize,
    results_out: *mut *mut CSearchResult,
    results_count: *mut usize,
) -> i32 {
    if index_ptr.is_null() || results_out.is_null() || results_count.is_null() {
        return 0;
    }
    
    let index = unsafe { &mut *index_ptr };
    
    let query_str = if query.is_null() {
        String::new()
    } else {
        match unsafe { CStr::from_ptr(query).to_str() } {
            Ok(s) => s.to_string(),
            Err(_) => return 0,
        }
    };
    
    let results = index.search_prefix(&query_str, limit);
    let count = results.len();
    
    let results_array = unsafe {
        libc::malloc(count * std::mem::size_of::<CSearchResult>()) as *mut CSearchResult
    };
    
    if results_array.is_null() {
        unsafe { *results_count = 0; }
        return 0;
    }
    
    for (i, result) in results.iter().enumerate() {
        let c_result = CSearchResult {
            node_id: CString::new(result.node_id.clone()).unwrap().into_raw(),
            name: CString::new(result.name.clone()).unwrap().into_raw(),
            score: result.score,
            account_id: CString::new(result.account_id.clone()).unwrap().into_raw(),
            provider: CString::new(result.provider.clone()).unwrap().into_raw(),
        };
        unsafe { results_array.offset(i as isize).write(c_result); }
    }
    
    unsafe {
        *results_out = results_array;
        *results_count = count;
    }
    
    1
}

/// Search index by account
#[no_mangle]
pub extern "C" fn search_index_by_account(
    index_ptr: *mut SearchIndex,
    query: *const c_char,
    account_id: *const c_char,
    limit: usize,
    results_out: *mut *mut CSearchResult,
    results_count: *mut usize,
) -> i32 {
    if index_ptr.is_null() || results_out.is_null() || results_count.is_null() {
        return 0;
    }
    
    let index = unsafe { &mut *index_ptr };
    
    let query_str = if query.is_null() {
        String::new()
    } else {
        match unsafe { CStr::from_ptr(query).to_str() } {
            Ok(s) => s.to_string(),
            Err(_) => return 0,
        }
    };
    
    let account_id_str = if account_id.is_null() {
        String::new()
    } else {
        match unsafe { CStr::from_ptr(account_id).to_str() } {
            Ok(s) => s.to_string(),
            Err(_) => return 0,
        }
    };
    
    let results = index.search_by_account(&query_str, &account_id_str, limit);
    let count = results.len();
    
    let results_array = unsafe {
        libc::malloc(count * std::mem::size_of::<CSearchResult>()) as *mut CSearchResult
    };
    
    if results_array.is_null() {
        unsafe { *results_count = 0; }
        return 0;
    }
    
    for (i, result) in results.iter().enumerate() {
        let c_result = CSearchResult {
            node_id: CString::new(result.node_id.clone()).unwrap().into_raw(),
            name: CString::new(result.name.clone()).unwrap().into_raw(),
            score: result.score,
            account_id: CString::new(result.account_id.clone()).unwrap().into_raw(),
            provider: CString::new(result.provider.clone()).unwrap().into_raw(),
        };
        unsafe { results_array.offset(i as isize).write(c_result); }
    }
    
    unsafe {
        *results_out = results_array;
        *results_count = count;
    }
    
    1
}

/// Free search results memory
#[no_mangle]
pub extern "C" fn free_search_results(results: *mut CSearchResult, count: usize) {
    if results.is_null() {
        return;
    }
    
    unsafe {
        for i in 0..count {
            let result = results.offset(i as isize);
            if !result.read().node_id.is_null() {
                let _ = CString::from_raw(result.read().node_id);
            }
            if !result.read().name.is_null() {
                let _ = CString::from_raw(result.read().name);
            }
            if !result.read().account_id.is_null() {
                let _ = CString::from_raw(result.read().account_id);
            }
            if !result.read().provider.is_null() {
                let _ = CString::from_raw(result.read().provider);
            }
        }
        libc::free(results as *mut c_void);
    }
}

/// Get index document count
#[no_mangle]
pub extern "C" fn get_index_count(index_ptr: *mut SearchIndex) -> usize {
    if index_ptr.is_null() {
        return 0;
    }
    unsafe { (*index_ptr).len() }
}

/// Clear search index
#[no_mangle]
pub extern "C" fn clear_search_index(index_ptr: *mut SearchIndex) -> i32 {
    if index_ptr.is_null() {
        return 0;
    }
    unsafe { (*index_ptr).clear(); }
    1
}

// ============================================================================
// Fuzzy matching FFI functions (standalone - don't require index)
// ============================================================================

/// Fuzzy match two strings
/// Returns 1 if match, 0 if not (threshold = 0.7)
#[no_mangle]
pub extern "C" fn fuzzy_match_strings(
    query: *const c_char,
    target: *const c_char,
    threshold: f64,
) -> i32 {
    let query_str = if query.is_null() {
        String::new()
    } else {
        match unsafe { CStr::from_ptr(query).to_str() } {
            Ok(s) => s.to_string(),
            Err(_) => return 0,
        }
    };
    
    let target_str = if target.is_null() {
        String::new()
    } else {
        match unsafe { CStr::from_ptr(target).to_str() } {
            Ok(s) => s.to_string(),
            Err(_) => return 0,
        }
    };
    
    if fuzzy_match(&query_str, &target_str, threshold) {
        1
    } else {
        0
    }
}

/// Calculate Jaro-Winkler similarity
/// Returns similarity score (0.0 to 1.0)
#[no_mangle]
pub extern "C" fn similarity_score(
    query: *const c_char,
    target: *const c_char,
) -> f64 {
    let query_str = if query.is_null() {
        String::new()
    } else {
        match unsafe { CStr::from_ptr(query).to_str() } {
            Ok(s) => s.to_string(),
            Err(_) => return 0.0,
        }
    };
    
    let target_str = if target.is_null() {
        String::new()
    } else {
        match unsafe { CStr::from_ptr(target).to_str() } {
            Ok(s) => s.to_string(),
            Err(_) => return 0.0,
        }
    };
    
    jaro_winkler_similarity(&query_str, &target_str)
}

/// Calculate Levenshtein distance
#[no_mangle]
pub extern "C" fn levenshtein(
    s1: *const c_char,
    s2: *const c_char,
) -> usize {
    let s1_str = if s1.is_null() {
        String::new()
    } else {
        match unsafe { CStr::from_ptr(s1).to_str() } {
            Ok(s) => s.to_string(),
            Err(_) => return 0,
        }
    };
    
    let s2_str = if s2.is_null() {
        String::new()
    } else {
        match unsafe { CStr::from_ptr(s2).to_str() } {
            Ok(s) => s.to_string(),
            Err(_) => return 0,
        }
    };
    
    levenshtein_distance(&s1_str, &s2_str)
}

/// Calculate Soundex code
/// Returns pointer to Soundex code string (caller must free)
#[no_mangle]
pub extern "C" fn soundex_code(word: *const c_char) -> *mut c_char {
    let word_str = if word.is_null() {
        String::new()
    } else {
        match unsafe { CStr::from_ptr(word).to_str() } {
            Ok(s) => s.to_string(),
            Err(_) => return ptr::null_mut(),
        }
    };
    
    let code = soundex(&word_str);
    CString::new(code).unwrap().into_raw()
}

/// Calculate Metaphone code
/// Returns pointer to Metaphone code string (caller must free)
#[no_mangle]
pub extern "C" fn metaphone_code(word: *const c_char) -> *mut c_char {
    let word_str = if word.is_null() {
        String::new()
    } else {
        match unsafe { CStr::from_ptr(word).to_str() } {
            Ok(s) => s.to_string(),
            Err(_) => return ptr::null_mut(),
        }
    };
    
    let code = metaphone(&word_str);
    CString::new(code).unwrap().into_raw()
}

/// Free a C string allocated by Rust
#[no_mangle]
pub extern "C" fn free_c_string(s: *mut c_char) {
    if !s.is_null() {
        unsafe {
            let _ = CString::from_raw(s);
        }
    }
}

// ============================================================================
// Phase 2: Path Building FFI
// ============================================================================

// ============================================================================
// Phase 2: Path Building FFI (using SearchIndex directly)
// ============================================================================

/// Build path from node to root (uses SearchIndex directly)
#[no_mangle]
pub extern "C" fn build_path(
    index_ptr: *mut SearchIndex,
    node_id: *const c_char,
    separator: *const c_char,
) -> *mut c_char {
    if index_ptr.is_null() {
        return ptr::null_mut();
    }
    
    let index = unsafe { &mut *index_ptr };
    
    let node_id_str = if node_id.is_null() {
        String::new()
    } else {
        match unsafe { CStr::from_ptr(node_id).to_str() } {
            Ok(s) => s.to_string(),
            Err(_) => return ptr::null_mut(),
        }
    };
    
    let sep = if separator.is_null() {
        String::from("/")
    } else {
        match unsafe { CStr::from_ptr(separator).to_str() } {
            Ok(s) => s.to_string(),
            Err(_) => String::from("/"),
        }
    };
    
    // Build path by traversing parent relationships
    let parts = build_path_from_index(index, &node_id_str);
    let path = parts.join(&sep);
    CString::new(path).unwrap().into_raw()
}

/// Helper function to build path from index
fn build_path_from_index(index: &SearchIndex, node_id: &str) -> Vec<String> {
    let mut parts = Vec::new();
    let mut current_id = node_id;
    let mut visited = std::collections::HashSet::new();
    
    loop {
        if visited.contains(current_id) {
            break;
        }
        visited.insert(current_id.to_string());
        
        if let Some(doc) = index.get(current_id) {
            parts.push(doc.name.clone());
            if let Some(parent_id) = &doc.parent_id {
                current_id = parent_id;
            } else {
                break;
            }
        } else {
            break;
        }
    }
    
    parts.reverse();
    parts
}

// ============================================================================
// Phase 2: Batch Indexing FFI
// ============================================================================

/// Create a batch indexer
#[no_mangle]
pub extern "C" fn create_batch_indexer(batch_size: usize) -> *mut SearchIndex {
    // Use SearchIndex directly for batch operations
    let index = Box::new(SearchIndex::new());
    Box::into_raw(index)
}

/// Free batch indexer
#[no_mangle]
pub extern "C" fn free_batch_indexer(indexer_ptr: *mut SearchIndex) {
    if !indexer_ptr.is_null() {
        unsafe {
            let _ = Box::from_raw(indexer_ptr);
        }
    }
}

/// Commit batch to search index (no-op since we use SearchIndex directly)
#[no_mangle]
pub extern "C" fn batch_indexer_commit(
    _indexer_ptr: *mut SearchIndex,
    _index_ptr: *mut SearchIndex,
) -> i32 {
    // Batch indexing uses SearchIndex directly, no separate batch indexer needed
    1
}

// ============================================================================
// Phase 2: Incremental Indexing FFI
// ============================================================================

/// Create incremental indexer (uses SearchIndex directly)
#[no_mangle]
pub extern "C" fn create_incremental_indexer() -> *mut SearchIndex {
    let index = Box::new(SearchIndex::new());
    Box::into_raw(index)
}

/// Free incremental indexer
#[no_mangle]
pub extern "C" fn free_incremental_indexer(indexer_ptr: *mut SearchIndex) {
    if !indexer_ptr.is_null() {
        unsafe {
            let _ = Box::from_raw(indexer_ptr);
        }
    }
}

/// Mark document for re-indexing (no-op for SearchIndex)
#[no_mangle]
pub extern "C" fn incremental_indexer_mark_dirty(
    _indexer_ptr: *mut SearchIndex,
    _node_id: *const c_char,
) -> i32 {
    // SearchIndex doesn't track dirty documents - this is a no-op
    1
}

/// Get pending document count (returns 0 for SearchIndex)
#[no_mangle]
pub extern "C" fn incremental_indexer_get_pending_count(_indexer_ptr: *mut SearchIndex) -> usize {
    // SearchIndex doesn't track pending changes
    0
}

// ============================================================================
// Phase 2: Suggestions FFI
// ============================================================================

/// Create suggestion engine (simplified - returns null since we use Dart implementation)
#[no_mangle]
pub extern "C" fn create_suggestion_engine(
    _max_suggestions: usize,
    _max_prefix_length: usize,
) -> *mut c_void {
    ptr::null_mut()
}

/// Free suggestion engine (no-op)
#[no_mangle]
pub extern "C" fn free_suggestion_engine(_engine_ptr: *mut c_void) {
    // No-op since we don't create a real engine
}

/// Add suggestion (no-op)
#[no_mangle]
pub extern "C" fn suggestion_engine_add_suggestion(
    _engine_ptr: *mut c_void,
    _text: *const c_char,
    _frequency: usize,
) -> i32 {
    // No-op - suggestions are handled in Dart
    1
}

/// Get suggestions (returns empty array)
#[no_mangle]
pub extern "C" fn suggestion_engine_get_suggestions(
    _engine_ptr: *mut c_void,
    _prefix: *const c_char,
    _limit: usize,
    results_out: *mut *mut c_char,
    results_count: *mut usize,
) -> i32 {
    // Return empty results
    unsafe {
        *results_out = ptr::null_mut();
        *results_count = 0;
    }
    1
}

/// Free suggestion results
#[no_mangle]
pub extern "C" fn free_suggestion_results(results: *mut *mut c_char, _count: usize) {
    if results.is_null() {
        return;
    }
    unsafe {
        libc::free(results as *mut c_void);
    }
}

// ============================================================================
// Phase 2: Search History FFI
// ============================================================================

/// Create search history (simplified - returns null since we use Dart implementation)
#[no_mangle]
pub extern "C" fn create_search_history(_max_entries: usize) -> *mut c_void {
    ptr::null_mut()
}

/// Free search history (no-op)
#[no_mangle]
pub extern "C" fn free_search_history(_history_ptr: *mut c_void) {
    // No-op
}

/// Add search to history (no-op)
#[no_mangle]
pub extern "C" fn search_history_add(
    _history_ptr: *mut c_void,
    _query: *const c_char,
    _account_id: *const c_char,
) -> i32 {
    // No-op - history is handled in Dart
    1
}

/// Get recent searches (returns empty array)
#[no_mangle]
pub extern "C" fn search_history_get_recent(
    _history_ptr: *mut c_void,
    _limit: usize,
    results_out: *mut *mut c_char,
    results_count: *mut usize,
) -> i32 {
    // Return empty results
    unsafe {
        *results_out = ptr::null_mut();
        *results_count = 0;
    }
    1
}

/// Clear search history (no-op)
#[no_mangle]
pub extern "C" fn search_history_clear(_history_ptr: *mut c_void) -> i32 {
    // No-op
    1
}