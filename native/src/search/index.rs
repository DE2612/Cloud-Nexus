// Search index module for CloudNexus
// Phase 1: Simple in-memory index for fuzzy search

use std::collections::HashMap;
use std::path::PathBuf;
use serde::{Deserialize, Serialize};

/// Search document structure for indexing
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct SearchDocument {
    pub node_id: String,
    pub account_id: String,
    pub provider: String,
    pub email: String,
    pub name: String,
    pub is_folder: bool,
    pub parent_id: Option<String>,
}

/// Search result with score
#[derive(Debug, Clone)]
pub struct SearchResult {
    pub node_id: String,
    pub name: String,
    pub score: f64,
    pub account_id: String,
    pub provider: String,
}

/// In-memory search index for Phase 1
/// Stores documents and provides fuzzy search capabilities
pub struct SearchIndex {
    /// Main document storage by node_id
    documents: HashMap<String, SearchDocument>,
    /// Inverted index for fast name lookup
    name_index: HashMap<String, Vec<String>>,
    /// Account index for filtering
    account_index: HashMap<String, Vec<String>>,
}

impl SearchIndex {
    /// Create a new empty search index
    pub fn new() -> Self {
        SearchIndex {
            documents: HashMap::new(),
            name_index: HashMap::new(),
            account_index: HashMap::new(),
        }
    }
    
    /// Add a document to the index
    pub fn add_document(&mut self, doc: SearchDocument) {
        let node_id = doc.node_id.clone();
        let name_lower = doc.name.to_lowercase();
        let account_id = doc.account_id.clone();
        
        // Add to main document store
        self.documents.insert(node_id.clone(), doc.clone());
        
        // Add to name inverted index (tokenized by word)
        for word in name_lower.split_whitespace() {
            if !word.is_empty() {
                self.name_index
                    .entry(word.to_string())
                    .or_insert_with(Vec::new)
                    .push(node_id.clone());
            }
        }
        
        // Add to account index
        self.account_index
            .entry(account_id)
            .or_insert_with(Vec::new)
            .push(node_id);
    }
    
    /// Remove a document from the index
    pub fn remove_document(&mut self, node_id: &str) -> Option<SearchDocument> {
        if let Some(doc) = self.documents.remove(node_id) {
            let name_lower = doc.name.to_lowercase();
            
            // Remove from name index
            for word in name_lower.split_whitespace() {
                if let Some(ids) = self.name_index.get_mut(word) {
                    ids.retain(|id| id != node_id);
                    if ids.is_empty() {
                        self.name_index.remove(word);
                    }
                }
            }
            
            // Remove from account index
            if let Some(ids) = self.account_index.get_mut(&doc.account_id) {
                ids.retain(|id| id != node_id);
                if ids.is_empty() {
                    self.account_index.remove(&doc.account_id);
                }
            }
            
            Some(doc)
        } else {
            None
        }
    }
    
    /// Clear all documents from the index
    pub fn clear(&mut self) {
        self.documents.clear();
        self.name_index.clear();
        self.account_index.clear();
    }
    
    /// Get document by node_id
    pub fn get(&self, node_id: &str) -> Option<&SearchDocument> {
        self.documents.get(node_id)
    }
    
    /// Get number of documents in index
    pub fn len(&self) -> usize {
        self.documents.len()
    }
    
    /// Check if index is empty
    pub fn is_empty(&self) -> bool {
        self.documents.is_empty()
    }
    
    /// Search with exact matching
    pub fn search_exact(&self, query: &str, limit: usize) -> Vec<SearchResult> {
        let query_lower = query.to_lowercase();
        let mut results = Vec::new();
        
        for (node_id, doc) in &self.documents {
            if doc.name.to_lowercase().contains(&query_lower) {
                let score = if doc.name.to_lowercase() == query_lower {
                    1.0
                } else if doc.name.to_lowercase().starts_with(&query_lower) {
                    0.9
                } else {
                    // For partial matches, calculate a more refined score
                    // based on how much of the query matches the name
                    let name_lower = doc.name.to_lowercase();
                    let match_position = name_lower.find(&query_lower).unwrap_or(0);
                    
                    // Calculate bonus for early match position
                    let position_bonus = if match_position == 0 {
                        0.1
                    } else {
                        0.0
                    };
                    
                    // Calculate bonus based on query being a word boundary match
                    let word_boundary_bonus = if match_position == 0 ||
                        name_lower.chars().nth(match_position - 1) == Some(' ') {
                        0.05
                    } else {
                        0.0
                    };
                    
                    0.7 + position_bonus + word_boundary_bonus
                };
                
                results.push(SearchResult {
                    node_id: node_id.clone(),
                    name: doc.name.clone(),
                    score,
                    account_id: doc.account_id.clone(),
                    provider: doc.provider.clone(),
                });
            }
        }
        
        // Sort by score (descending) to return most relevant results first
        results.sort_by(|a, b| b.score.partial_cmp(&a.score).unwrap());
        
        // Apply limit after sorting to get top results
        results.into_iter().take(limit).collect()
    }
    
    /// Search with prefix matching
    pub fn search_prefix(&self, query: &str, limit: usize) -> Vec<SearchResult> {
        let query_lower = query.to_lowercase();
        let mut results = Vec::new();
        
        // First, try exact prefix match in name index
        for word in query_lower.split_whitespace() {
            if let Some(node_ids) = self.name_index.get(word) {
                for node_id in node_ids {
                    if let Some(doc) = self.documents.get(node_id) {
                        // Check if name starts with query
                        if doc.name.to_lowercase().starts_with(&query_lower) {
                            results.push(SearchResult {
                                node_id: node_id.clone(),
                                name: doc.name.clone(),
                                score: 0.95,
                                account_id: doc.account_id.clone(),
                                provider: doc.provider.clone(),
                            });
                        }
                    }
                }
            }
        }
        
        // Remove duplicates and limit results
        results.sort_by(|a, b| b.score.partial_cmp(&a.score).unwrap());
        results.into_iter().take(limit).collect()
    }
    
    /// Search within specific account
    pub fn search_by_account(&self, query: &str, account_id: &str, limit: usize) -> Vec<SearchResult> {
        let query_lower = query.to_lowercase();
        let mut results = Vec::new();
        
        if let Some(node_ids) = self.account_index.get(account_id) {
            for node_id in node_ids {
                if let Some(doc) = self.documents.get(node_id) {
                    if doc.name.to_lowercase().contains(&query_lower) {
                        let score = if doc.name.to_lowercase() == query_lower {
                            1.0
                        } else if doc.name.to_lowercase().starts_with(&query_lower) {
                            0.9
                        } else {
                            0.7
                        };
                        
                        results.push(SearchResult {
                            node_id: node_id.clone(),
                            name: doc.name.clone(),
                            score,
                            account_id: doc.account_id.clone(),
                            provider: doc.provider.clone(),
                        });
                    }
                }
            }
        }
        
        results.sort_by(|a, b| b.score.partial_cmp(&a.score).unwrap());
        results.into_iter().take(limit).collect()
    }
    
    /// Get all documents for an account
    pub fn get_by_account(&self, account_id: &str) -> Vec<&SearchDocument> {
        if let Some(node_ids) = self.account_index.get(account_id) {
            node_ids.iter()
                .filter_map(|id| self.documents.get(id))
                .collect()
        } else {
            Vec::new()
        }
    }
}

impl Default for SearchIndex {
    fn default() -> Self {
        SearchIndex::new()
    }
}

/// Persistent search index that saves to disk
pub struct PersistentSearchIndex {
    index: SearchIndex,
    path: PathBuf,
}

impl PersistentSearchIndex {
    /// Create or open a persistent index
    pub fn new(path: PathBuf) -> Self {
        let index = if path.exists() {
            Self::load_from_disk(&path).unwrap_or_else(|_| SearchIndex::new())
        } else {
            SearchIndex::new()
        };
        
        PersistentSearchIndex { index, path }
    }
    
    /// Save index to disk
    fn save_to_disk(&self) -> Result<(), std::io::Error> {
        // Create parent directories if needed
        if let Some(parent) = self.path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        
        let data = serde_json::to_string_pretty(&self.index.documents)?;
        std::fs::write(&self.path, data)?;
        
        Ok(())
    }
    
    /// Load index from disk
    fn load_from_disk(path: &PathBuf) -> Result<SearchIndex, std::io::Error> {
        let data = std::fs::read_to_string(path)?;
        let documents: HashMap<String, SearchDocument> = serde_json::from_str(&data)?;
        
        let mut index = SearchIndex::new();
        for (_, doc) in documents {
            index.add_document(doc);
        }
        
        Ok(index)
    }
    
    /// Add document and persist
    pub fn add_document(&mut self, doc: SearchDocument) {
        self.index.add_document(doc);
        let _ = self.save_to_disk();
    }
    
    /// Remove document and persist
    pub fn remove_document(&mut self, node_id: &str) -> Option<SearchDocument> {
        let result = self.index.remove_document(node_id);
        let _ = self.save_to_disk();
        result
    }
    
    /// Clear index and persist
    pub fn clear(&mut self) {
        self.index.clear();
        let _ = self.save_to_disk();
    }
    
    /// Get underlying index reference
    pub fn inner(&self) -> &SearchIndex {
        &self.index
    }
    
    /// Get mutable index reference
    pub fn inner_mut(&mut self) -> &mut SearchIndex {
        &mut self.index
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    
    #[test]
    fn test_search_index_basic() {
        let mut index = SearchIndex::new();
        
        index.add_document(SearchDocument {
            node_id: "1".to_string(),
            account_id: "acc1".to_string(),
            provider: "gdrive".to_string(),
            email: "test@example.com".to_string(),
            name: "Document.pdf".to_string(),
            is_folder: false,
            parent_id: None,
        });
        
        index.add_document(SearchDocument {
            node_id: "2".to_string(),
            account_id: "acc1".to_string(),
            provider: "gdrive".to_string(),
            email: "test@example.com".to_string(),
            name: "Project Files".to_string(),
            is_folder: true,
            parent_id: None,
        });
        
        assert_eq!(index.len(), 2);
        
        // Test exact search
        let results = index.search_exact("document", 10);
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].node_id, "1");
        
        // Test prefix search
        let results = index.search_prefix("doc", 10);
        assert_eq!(results.len(), 1);
        
        // Test account filter
        let results = index.search_by_account("doc", "acc1", 10);
        assert_eq!(results.len(), 1);
        
        // Test non-existent account
        let results = index.search_by_account("doc", "acc2", 10);
        assert_eq!(results.len(), 0);
    }
    
    #[test]
    fn test_search_index_remove() {
        let mut index = SearchIndex::new();
        
        index.add_document(SearchDocument {
            node_id: "1".to_string(),
            account_id: "acc1".to_string(),
            provider: "gdrive".to_string(),
            email: "test@example.com".to_string(),
            name: "Test".to_string(),
            is_folder: false,
            parent_id: None,
        });
        
        assert_eq!(index.len(), 1);
        
        let removed = index.remove_document("1");
        assert!(removed.is_some());
        assert_eq!(index.len(), 0);
        
        let removed = index.remove_document("1");
        assert!(removed.is_none());
    }
}