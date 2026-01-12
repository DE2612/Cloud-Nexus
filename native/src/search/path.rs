// Search path building module for CloudNexus
// Phase 2: Build display paths for search results

use std::collections::HashMap;

/// Result structure with path information
#[derive(Debug, Clone)]
pub struct SearchResultWithPath {
    pub node_id: String,
    pub name: String,
    pub score: f64,
    pub account_id: String,
    pub provider: String,
    pub display_path: String,
}

/// Path builder for reconstructing full paths from parent relationships
pub struct PathBuilder {
    /// Cache of node_id -> (name, parent_id)
    node_cache: HashMap<String, (String, Option<String>)>,
}

impl PathBuilder {
    /// Create a new path builder
    pub fn new() -> Self {
        PathBuilder {
            node_cache: HashMap::new(),
        }
    }
    
    /// Add a document to the cache
    pub fn add_node(&mut self, node_id: String, name: String, parent_id: Option<String>) {
        self.node_cache.insert(node_id, (name, parent_id));
    }
    
    /// Build the full display path for a node
    pub fn build_path(&self, node_id: &str) -> String {
        let mut path_parts = Vec::new();
        let mut current_id = node_id;
        let mut visited = std::collections::HashSet::new();
        
        // Prevent infinite loops
        while let Some((name, parent_id)) = self.node_cache.get(current_id) {
            if visited.contains(current_id) {
                break; // Loop detected
            }
            visited.insert(current_id);
            
            path_parts.insert(0, name.clone());
            
            if let Some(parent) = parent_id {
                current_id = parent;
            } else {
                break;
            }
        }
        
        path_parts.join(" / ")
    }
    
    /// Build path with account prefix
    pub fn build_path_with_account(
        &self,
        node_id: &str,
        email: &str,
        provider: &str,
    ) -> String {
        let account_prefix = format!("{} ({})", email, provider);
        let path = self.build_path(node_id);
        if path.is_empty() {
            account_prefix.clone()
        } else {
            format!("{} / {}", account_prefix, path)
        }
    }
    
    /// Clear the cache
    pub fn clear(&mut self) {
        self.node_cache.clear();
    }
    
    /// Get number of cached nodes
    pub fn len(&self) -> usize {
        self.node_cache.len()
    }
    
    /// Check if cache is empty
    pub fn is_empty(&self) -> bool {
        self.node_cache.is_empty()
    }
}

impl Default for PathBuilder {
    fn default() -> Self {
        PathBuilder::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    
    #[test]
    fn test_path_builder_basic() {
        let mut builder = PathBuilder::new();
        
        // Add a simple hierarchy: root / folder1 / file.txt
        builder.add_node("root".to_string(), "Root".to_string(), None);
        builder.add_node("folder1".to_string(), "Folder 1".to_string(), Some("root".to_string()));
        builder.add_node("file1".to_string(), "file.txt".to_string(), Some("folder1".to_string()));
        
        // Build path for file1
        let path = builder.build_path("file1");
        assert_eq!(path, "Root / Folder 1 / file.txt");
    }
    
    #[test]
    fn test_path_builder_single_node() {
        let builder = PathBuilder::new();
        builder.add_node("node1".to_string(), "Single Node".to_string(), None);
        
        let path = builder.build_path("node1");
        assert_eq!(path, "Single Node");
    }
    
    #[test]
    fn test_path_builder_with_account() {
        let mut builder = PathBuilder::new();
        builder.add_node("file1".to_string(), "document.pdf".to_string(), Some("folder1".to_string()));
        builder.add_node("folder1".to_string(), "Work".to_string(), Some("root".to_string()));
        builder.add_node("root".to_string(), "My Drive".to_string(), None);
        
        let path = builder.build_path_with_account("file1", "user@example.com", "gdrive");
        assert_eq!(path, "user@example.com (Google Drive) / My Drive / Work / document.pdf");
    }
    
    #[test]
    fn test_path_builder_loop_detection() {
        let mut builder = PathBuilder::new();
        
        // Create a loop: a -> b -> a
        builder.add_node("a".to_string(), "Node A".to_string(), Some("b".to_string()));
        builder.add_node("b".to_string(), "Node B".to_string(), Some("a".to_string()));
        
        // Should handle loop gracefully
        let path = builder.build_path("a");
        // Should contain at least "Node A"
        assert!(path.contains("Node A"));
    }
}