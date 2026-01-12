// Batch indexing module for CloudNexus
// Phase 2: Efficient bulk document addition

use super::index::{SearchDocument, SearchIndex};

/// Batch indexer for efficient bulk document addition
/// Accumulates documents and commits them in batches for better performance
pub struct BatchIndexer {
    /// The underlying search index
    index: SearchIndex,
    /// Maximum batch size before auto-commit
    batch_size: usize,
    /// Current batch of documents
    current_batch: Vec<SearchDocument>,
    /// Total documents indexed
    total_indexed: usize,
}

impl BatchIndexer {
    /// Create a new batch indexer
    pub fn new(batch_size: usize) -> Self {
        BatchIndexer {
            index: SearchIndex::new(),
            batch_size,
            current_batch: Vec::with_capacity(batch_size),
            total_indexed: 0,
        }
    }
    
    /// Add a document to the batch
    /// Returns true if a commit was triggered
    pub fn add_document(&mut self, doc: SearchDocument) -> bool {
        self.current_batch.push(doc);
        
        if self.current_batch.len() >= self.batch_size {
            self.flush().is_ok()
        } else {
            false
        }
    }
    
    /// Add multiple documents at once
    pub fn add_documents(&mut self, docs: &[SearchDocument]) -> Result<(), String> {
        for doc in docs {
            self.add_document(doc.clone());
        }
        Ok(())
    }
    
    /// Flush the current batch to the index
    pub fn flush(&mut self) -> Result<usize, String> {
        if self.current_batch.is_empty() {
            return Ok(0);
        }
        
        let count = self.current_batch.len();
        for doc in self.current_batch.drain(..) {
            self.index.add_document(doc);
        }
        
        self.total_indexed += count;
        Ok(count)
    }
    
    /// Get the underlying index reference
    pub fn inner(&self) -> &SearchIndex {
        &self.index
    }
    
    /// Get the underlying index mutable reference
    pub fn inner_mut(&mut self) -> &mut SearchIndex {
        &mut self.index
    }
    
    /// Get total documents indexed
    pub fn total_indexed(&self) -> usize {
        self.total_indexed
    }
    
    /// Get current batch size
    pub fn current_batch_size(&self) -> usize {
        self.current_batch.len()
    }
    
    /// Get the configured batch size
    pub fn batch_size(&self) -> usize {
        self.batch_size
    }
    
    /// Consume and get the index
    pub fn into_index(self) -> SearchIndex {
        self.index
    }
}

/// Progress callback for batch operations
pub trait BatchProgressCallback {
    fn on_progress(&self, processed: usize, total: usize);
}

/// Default no-op progress callback
impl BatchProgressCallback for () {
    fn on_progress(&self, _processed: usize, _total: usize) {}
}

#[cfg(test)]
mod tests {
    use super::*;
    
    #[test]
    fn test_batch_indexer_basic() {
        let mut batcher = BatchIndexer::new(3);
        
        // Add 2 documents (below batch size)
        batcher.add_document(create_test_doc("1", "Test Document 1"));
        batcher.add_document(create_test_doc("2", "Test Document 2"));
        assert_eq!(batcher.current_batch_size(), 2);
        assert_eq!(batcher.total_indexed(), 0);
        
        // Add 3rd document (should trigger flush)
        let triggered = batcher.add_document(create_test_doc("3", "Test Document 3"));
        assert!(triggered);
        assert_eq!(batcher.current_batch_size(), 0);
        assert_eq!(batcher.total_indexed(), 3);
    }
    
    #[test]
    fn test_batch_indexer_flush() {
        let mut batcher = BatchIndexer::new(5);
        
        batcher.add_document(create_test_doc("1", "Doc 1"));
        batcher.add_document(create_test_doc("2", "Doc 2"));
        
        assert_eq!(batcher.flush().unwrap(), 2);
        assert_eq!(batcher.total_indexed(), 2);
        assert_eq!(batcher.inner().len(), 2);
    }
    
    #[test]
    fn test_batch_indexer_add_documents() {
        let mut batcher = BatchIndexer::new(10);
        
        let docs: Vec<SearchDocument> = (0..5)
            .map(|i| create_test_doc(&i.to_string(), &format!("Document {}", i)))
            .collect();
        
        batcher.add_documents(&docs).unwrap();
        assert_eq!(batcher.total_indexed(), 5);
        assert_eq!(batcher.inner().len(), 5);
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