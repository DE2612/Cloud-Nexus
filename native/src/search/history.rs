// Search history module for CloudNexus
// Phase 2: Track and manage search history

use std::collections::{HashMap, VecDeque};
use std::path::PathBuf;
use serde::{Deserialize, Serialize};

/// Search history entry
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HistoryEntry {
    pub query: String,
    pub timestamp: i64,
    pub result_count: usize,
    pub scope: String,
}

/// Search history manager
pub struct SearchHistory {
    /// History entries (recent first)
    history: VecDeque<HistoryEntry>,
    /// Query -> count (for popularity)
    query_counts: HashMap<String, usize>,
    /// Maximum history entries to keep
    max_history: usize,
    /// Persistence path
    persistence_path: Option<PathBuf>,
}

impl SearchHistory {
    /// Create a new search history
    pub fn new(max_history: usize) -> Self {
        SearchHistory {
            history: VecDeque::new(),
            query_counts: HashMap::new(),
            max_history,
            persistence_path: None,
        }
    }
    
    /// Create with persistence
    pub fn with_persistence(path: PathBuf, max_history: usize) -> Self {
        let mut history = SearchHistory::new(max_history);
        history.persistence_path = Some(path.clone());
        
        // Try to load existing history
        if path.exists() {
            let _ = history.load();
        }
        
        history
    }
    
    /// Record a search query
    pub fn record_search(
        &mut self,
        query: String,
        result_count: usize,
        scope: String,
    ) {
        let entry = HistoryEntry {
            query: query.clone(),
            timestamp: chrono::Utc::now().timestamp(),
            result_count,
            scope,
        };
        
        // Add to history
        self.history.push_front(entry);
        
        // Update counts
        *self.query_counts.entry(query).or_insert(0) += 1;
        
        // Trim history
        while self.history.len() > self.max_history {
            self.history.pop_back();
        }
        
        // Auto-save if persistence is enabled
        if self.persistence_path.is_some() {
            let _ = self.save();
        }
    }
    
    /// Get recent searches
    pub fn get_recent(&self, limit: usize) -> Vec<&HistoryEntry> {
        self.history.iter().take(limit).collect()
    }
    
    /// Get popular searches
    pub fn get_popular(&self, limit: usize) -> Vec<(&String, &usize)> {
        let mut entries: Vec<(&String, &usize)> = self.query_counts.iter().collect();
        entries.sort_by(|a, b| b.1.cmp(a.1));
        entries.into_iter().take(limit).collect()
    }
    
    /// Get searches matching a prefix
    pub fn search_history(&self, prefix: &str) -> Vec<&HistoryEntry> {
        let prefix_lower = prefix.to_lowercase();
        self.history
            .iter()
            .filter(|entry| entry.query.to_lowercase().starts_with(&prefix_lower))
            .take(10)
            .collect()
    }
    
    /// Clear history
    pub fn clear(&mut self) {
        self.history.clear();
        self.query_counts.clear();
        
        if let Some(ref path) = self.persistence_path {
            let _ = std::fs::remove_file(path);
        }
    }
    
    /// Remove a specific entry
    pub fn remove(&mut self, query: &str) {
        self.history.retain(|entry| entry.query != query);
        self.query_counts.remove(query);
    }
    
    /// Get history size
    pub fn len(&self) -> usize {
        self.history.len()
    }
    
    /// Check if empty
    pub fn is_empty(&self) -> bool {
        self.history.is_empty()
    }
    
    /// Save history to disk
    pub fn save(&self) -> Result<(), String> {
        if let Some(ref path) = self.persistence_path {
            if let Some(parent) = path.parent() {
                std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
            }
            
            let data = serde_json::to_string_pretty(&self.history).map_err(|e| e.to_string())?;
            std::fs::write(path, data).map_err(|e| e.to_string())?;
        }
        Ok(())
    }
    
    /// Load history from disk
    pub fn load(&mut self) -> Result<(), String> {
        if let Some(ref path) = self.persistence_path {
            if !path.exists() {
                return Ok(());
            }
            
            let data = std::fs::read_to_string(path).map_err(|e| e.to_string())?;
            let loaded: VecDeque<HistoryEntry> = serde_json::from_str(&data).map_err(|e| e.to_string())?;
            
            self.history = loaded;
            
            // Rebuild counts
            self.query_counts.clear();
            for entry in &self.history {
                *self.query_counts.entry(entry.query.clone()).or_insert(0) += 1;
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    
    #[test]
    fn test_search_history_basic() {
        let mut history = SearchHistory::new(10);
        
        // Record some searches
        history.record_search("document".to_string(), 5, "global".to_string());
        history.record_search("pdf".to_string(), 3, "global".to_string());
        history.record_search("document".to_string(), 7, "global".to_string()); // Same query again
        
        assert_eq!(history.len(), 3);
        
        // "document" should have count 2
        let popular = history.get_popular(5);
        assert_eq!(popular.len(), 2);
        assert_eq!(popular[0].1, &2); // "document" has 2 entries
        assert_eq!(popular[1].1, &1); // "pdf" has 1 entry
    }
    
    #[test]
    fn test_search_history_prefix() {
        let mut history = SearchHistory::new(10);
        
        history.record_search("document".to_string(), 5, "global".to_string());
        history.record_search("documentation".to_string(), 3, "global".to_string());
        history.record_search("pdf".to_string(), 2, "global".to_string());
        
        let matches = history.search_history("doc");
        assert_eq!(matches.len(), 2);
    }
    
    #[test]
    fn test_search_history_clear() {
        let mut history = SearchHistory::new(10);
        
        history.record_search("test".to_string(), 1, "global".to_string());
        assert!(!history.is_empty());
        
        history.clear();
        assert!(history.is_empty());
    }
}