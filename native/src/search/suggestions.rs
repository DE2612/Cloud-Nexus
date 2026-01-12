// Search suggestions module for CloudNexus
// Phase 2: Autocomplete suggestions based on indexed content

use std::collections::{HashMap, VecDeque};

/// Search suggestion with score
#[derive(Debug, Clone)]
pub struct Suggestion {
    pub text: String,
    pub score: f64,
    pub frequency: usize,
}

/// Suggestion engine that builds a prefix-based index for autocomplete
pub struct SuggestionEngine {
    /// Prefix -> suggestions (sorted by score)
    prefix_map: HashMap<String, Vec<Suggestion>>,
    /// Track document frequencies
    frequency_map: HashMap<String, usize>,
    /// Maximum suggestions per prefix
    max_suggestions: usize,
    /// Maximum prefix length to store
    max_prefix_length: usize,
    /// Recently used suggestions (for recency boost)
    recent_suggestions: VecDeque<String>,
    /// Maximum recent suggestions to track
    max_recent: usize,
}

impl SuggestionEngine {
    /// Create a new suggestion engine
    pub fn new(max_suggestions: usize, max_prefix_length: usize) -> Self {
        SuggestionEngine {
            prefix_map: HashMap::new(),
            frequency_map: HashMap::new(),
            max_suggestions,
            max_prefix_length,
            recent_suggestions: VecDeque::new(),
            max_recent: 100,
        }
    }
    
    /// Create with default values
    pub fn default() -> Self {
        SuggestionEngine::new(10, 20)
    }
    
    /// Add a suggestion (usually from indexed document names)
    pub fn add_suggestion(&mut self, text: &str, frequency: usize) {
        if text.is_empty() {
            return;
        }
        
        let text_lower = text.to_lowercase();
        
        // Update frequency
        *self.frequency_map.entry(text_lower.clone()).or_insert(0) += frequency;
        
        // Add all prefixes
        let chars: Vec<char> = text_lower.chars().collect();
        let prefix_len = std::cmp::min(chars.len(), self.max_prefix_length);
        
        // Pre-calculate scores for all prefixes before mutating anything
        let mut prefix_scores: Vec<(String, f64)> = Vec::new();
        for i in 1..=prefix_len {
            let prefix_str: String = chars[..i].iter().collect();
            let score = self._calculate_score(&text_lower, &prefix_str);
            prefix_scores.push((prefix_str.clone(), score));
        }
        
        // Now add/update suggestions with the pre-calculated scores
        for (prefix_str, score) in prefix_scores {
            let suggestion = Suggestion {
                text: text.to_string(),
                score,
                frequency,
            };
            
            let suggestions = self.prefix_map.entry(prefix_str).or_insert_with(Vec::new);
            
            // Add or update suggestion
            if let Some(existing) = suggestions.iter_mut().find(|s| s.text == text) {
                existing.frequency += frequency;
                existing.score = score;
            } else {
                suggestions.push(suggestion);
            }
            
            // Sort and trim
            suggestions.sort_by(|a, b| b.score.partial_cmp(&a.score).unwrap());
            if suggestions.len() > self.max_suggestions {
                suggestions.truncate(self.max_suggestions);
            }
        }
    }
    
    /// Add multiple suggestions at once
    pub fn add_suggestions(&mut self, texts: &[(&str, usize)]) {
        for (text, freq) in texts {
            self.add_suggestion(text, *freq);
        }
    }
    
    /// Get suggestions for a prefix
    pub fn get_suggestions(&self, prefix: &str) -> Vec<Suggestion> {
        let prefix_lower = prefix.to_lowercase();
        
        // Find exact prefix match
        if let Some(suggestions) = self.prefix_map.get(&prefix_lower) {
            return suggestions.clone();
        }
        
        // Find closest prefix
        let mut best_match: Option<&Vec<Suggestion>> = None;
        for (key, suggestions) in &self.prefix_map {
            if key.starts_with(&prefix_lower) || prefix_lower.starts_with(key) {
                if best_match.is_none() || key.len() > best_match.unwrap().len() {
                    best_match = Some(suggestions);
                }
            }
        }
        
        best_match.cloned().unwrap_or_default()
    }
    
    /// Get prefix-based suggestions (for autocomplete)
    pub fn get_prefix_suggestions(&self, prefix: &str, limit: usize) -> Vec<String> {
        self.get_suggestions(prefix)
            .into_iter()
            .take(limit)
            .map(|s| s.text)
            .collect()
    }
    
    /// Record a suggestion was used (boosts recency)
    pub fn record_usage(&mut self, text: &str) {
        // Add to recent
        let text_lower = text.to_lowercase();
        self.recent_suggestions.retain(|s| s != &text_lower);
        self.recent_suggestions.push_front(text_lower.clone());
        
        // Trim recent
        while self.recent_suggestions.len() > self.max_recent {
            self.recent_suggestions.pop_back();
        }
        
        // Boost frequency
        *self.frequency_map.entry(text_lower).or_insert(0) += 1;
    }
    
    /// Clear all suggestions
    pub fn clear(&mut self) {
        self.prefix_map.clear();
        self.frequency_map.clear();
        self.recent_suggestions.clear();
    }
    
    /// Calculate suggestion score
    fn _calculate_score(&self, text: &str, prefix: &str) -> f64 {
        let text_lower = text.to_lowercase();
        
        // Base score from frequency
        let freq = self.frequency_map.get(&text_lower).copied().unwrap_or(0) as f64;
        let freq_score = (freq + 1.0).ln();
        
        // Exact prefix match bonus
        let exact_prefix_bonus = if text_lower.starts_with(prefix) { 2.0 } else { 0.0 };
        
        // Length penalty (prefer shorter, more common terms)
        let length_penalty = (text.len() as f64).ln() / 10.0;
        
        // Recency boost
        let recency_boost = if self.recent_suggestions.contains(&text_lower) {
            1.5
        } else {
            1.0
        };
        
        (freq_score + exact_prefix_bonus - length_penalty) * recency_boost
    }
    
    /// Get number of indexed suggestions
    pub fn len(&self) -> usize {
        self.frequency_map.len()
    }
    
    /// Check if empty
    pub fn is_empty(&self) -> bool {
        self.frequency_map.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    
    #[test]
    fn test_suggestion_engine_basic() {
        let mut engine = SuggestionEngine::new(3, 10);
        
        // Add some suggestions
        engine.add_suggestion("document.pdf", 10);
        engine.add_suggestion("document.docx", 5);
        engine.add_suggestion("downloads", 3);
        
        // Get suggestions for "doc"
        let suggestions = engine.get_prefix_suggestions("doc", 5);
        assert!(suggestions.len() >= 2);
        assert!(suggestions.contains(&"document.pdf".to_string()));
        assert!(suggestions.contains(&"document.docx".to_string()));
    }
    
    #[test]
    fn test_suggestion_engine_recency() {
        let mut engine = SuggestionEngine::default();
        
        engine.add_suggestion("test", 1);
        engine.add_suggestion("testing", 1);
        
        // Record usage
        engine.record_usage("test");
        
        // "test" should be boosted
        let suggestions = engine.get_prefix_suggestions("tes", 5);
        assert!(!suggestions.is_empty());
    }
    
    #[test]
    fn test_suggestion_engine_clear() {
        let mut engine = SuggestionEngine::default();
        engine.add_suggestion("test", 1);
        assert!(!engine.is_empty());
        
        engine.clear();
        assert!(engine.is_empty());
    }
}