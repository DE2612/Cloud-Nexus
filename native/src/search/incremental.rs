// Incremental indexing module for CloudNexus
// Phase 2: Efficient updates for changed documents

use std::collections::HashSet;
use std::collections::HashMap;
use std::path::PathBuf;
use serde::{Deserialize, Serialize};

use super::index::{SearchDocument, SearchIndex};

/// Change type for incremental updates
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub enum DocumentChange {
    Added(SearchDocument),
    Modified(SearchDocument),
    Removed(String), // node_id
}

/// Incremental indexer that tracks changes and applies them efficiently
pub struct IncrementalIndexer {
    /// The underlying search index
    index: SearchIndex,
    /// Track processed node IDs
    processed_ids: HashSet<String>,
    /// Track changed node IDs
    changed_ids: HashSet<String>,
    /// Mapping of node_id to file path (for persistence)
    node_file_map: HashMap<String, PathBuf>,
    /// Path to persistence file
    persistence_path: Option<PathBuf>,
}

impl IncrementalIndexer {
    /// Create a new incremental indexer
    pub fn new() -> Self {
        IncrementalIndexer {
            index: SearchIndex::new(),
            processed_ids: HashSet::new(),
            changed_ids: HashSet::new(),
            node_file_map: HashMap::new(),
            persistence_path: None,
        }
    }
    
    /// Create with persistence
    pub fn with_persistence(path: PathBuf) -> Self {
        let mut indexer = IncrementalIndexer::new();
        indexer.persistence_path = Some(path.clone());
        
        // Try to load existing state
        if path.exists() {
            let _ = indexer.load_state();
        }
        
        indexer
    }
    
    /// Mark a document as changed (needs re-indexing)
    pub fn mark_changed(&mut self, node_id: String) {
        self.changed_ids.insert(node_id);
    }
    
    /// Mark a document as added
    pub fn mark_added(&mut self, doc: SearchDocument) {
        self.changed_ids.insert(doc.node_id.clone());
        self.processed_ids.insert(doc.node_id.clone());
        self.index.add_document(doc);
    }
    
    /// Mark a document as removed
    pub fn mark_removed(&mut self, node_id: &str) {
        self.changed_ids.insert(node_id.to_string());
        self.processed_ids.remove(node_id);
        self.index.remove_document(node_id);
    }
    
    /// Apply changes from a change list
    pub fn apply_changes(&mut self, changes: &[DocumentChange]) {
        for change in changes {
            match change {
                DocumentChange::Added(doc) => {
                    self.processed_ids.insert(doc.node_id.clone());
                    self.index.add_document(doc.clone());
                }
                DocumentChange::Modified(doc) => {
                    self.index.remove_document(&doc.node_id);
                    self.index.add_document(doc.clone());
                }
                DocumentChange::Removed(node_id) => {
                    self.processed_ids.remove(node_id);
                    self.index.remove_document(node_id);
                }
            }
        }
        
        self.changed_ids.clear();
    }
    
    /// Get pending changes
    pub fn get_pending_changes(&self) -> Vec<&String> {
        self.changed_ids.iter().collect()
    }
    
    /// Check if there are pending changes
    pub fn has_pending_changes(&self) -> bool {
        !self.changed_ids.is_empty()
    }
    
    /// Get number of changed documents
    pub fn changed_count(&self) -> usize {
        self.changed_ids.len()
    }
    
    /// Get number of processed documents
    pub fn processed_count(&self) -> usize {
        self.processed_ids.len()
    }
    
    /// Get the underlying index reference
    pub fn inner(&self) -> &SearchIndex {
        &self.index
    }
    
    /// Get the underlying index mutable reference
    pub fn inner_mut(&mut self) -> &mut SearchIndex {
        &mut self.index
    }
    
    /// Save state to disk
    pub fn save_state(&self) -> Result<(), String> {
        if let Some(ref path) = self.persistence_path {
            if let Some(parent) = path.parent() {
                std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
            }
            
            let state = IncrementalIndexState {
                processed_ids: self.processed_ids.clone(),
                node_file_map: self.node_file_map.clone(),
            };
            
            let data = serde_json::to_string_pretty(&state).map_err(|e| e.to_string())?;
            std::fs::write(path, data).map_err(|e| e.to_string())?;
        }
        Ok(())
    }
    
    /// Load state from disk
    pub fn load_state(&mut self) -> Result<(), String> {
        if let Some(ref path) = self.persistence_path {
            if !path.exists() {
                return Ok(());
            }
            
            let data = std::fs::read_to_string(path).map_err(|e| e.to_string())?;
            let state: IncrementalIndexState = serde_json::from_str(&data).map_err(|e| e.to_string())?;
            
            self.processed_ids = state.processed_ids;
            self.node_file_map = state.node_file_map;
        }
        Ok(())
    }
    
    /// Clear all state
    pub fn clear(&mut self) {
        self.index.clear();
        self.processed_ids.clear();
        self.changed_ids.clear();
        self.node_file_map.clear();
    }
}

/// State for persistence
#[derive(Debug, Serialize, Deserialize)]
struct IncrementalIndexState {
    processed_ids: HashSet<String>,
    node_file_map: HashMap<String, PathBuf>,
}

#[cfg(test)]
mod tests {
    use super::*;
    
    #[test]
    fn test_incremental_indexer_basic() {
        let mut indexer = IncrementalIndexer::new();
        
        // Add a document
        let doc = create_test_doc("1", "Test Document");
        indexer.mark_added(doc.clone());
        assert_eq!(indexer.processed_count(), 1);
        assert_eq!(indexer.inner().len(), 1);
        
        // Mark as changed
        indexer.mark_changed("1".to_string());
        assert!(indexer.has_pending_changes());
        assert_eq!(indexer.changed_count(), 1);
        
        // Remove
        indexer.mark_removed("1");
        assert_eq!(indexer.processed_count(), 0);
        assert_eq!(indexer.inner().len(), 0);
    }
    
    #[test]
    fn test_incremental_indexer_apply_changes() {
        let mut indexer = IncrementalIndexer::new();
        
        let changes = vec![
            DocumentChange::Added(create_test_doc("1", "Doc 1")),
            DocumentChange::Added(create_test_doc("2", "Doc 2")),
            DocumentChange::Modified(create_test_doc("3", "Doc 3 Modified")),
            DocumentChange::Removed("4".to_string()),
        ];
        
        indexer.apply_changes(&changes);
        
        assert_eq!(indexer.processed_count(), 3);
        assert_eq!(indexer.inner().len(), 3);
        assert!(!indexer.has_pending_changes());
    }
    
    fn create_test_doc(id: &str, name: &str) -> SearchDocument {
        SearchDocument {
            node_id: id.to_string(),
            account_id: "test_account".to_string(),
            provider: "gdrive".to_string(),
            email: "test@example.com".to_string(),
            name: name.to_string(),
            is_folder: false,
            parent_id: None,
        }
    }
}