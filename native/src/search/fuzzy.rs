// Fuzzy string matching module for CloudNexus search
// Phase 1: Provides Levenshtein distance and Jaro-Winkler similarity

use std::cmp::{max, min};
use std::collections::HashMap;

/// Calculate Levenshtein distance between two strings
/// Returns the number of insertions, deletions, and substitutions needed to transform one string into another
pub fn levenshtein_distance(s1: &str, s2: &str) -> usize {
    let s1_len = s1.chars().count();
    let s2_len = s2.chars().count();
    
    if s1_len == 0 {
        return s2_len;
    }
    if s2_len == 0 {
        return s1_len;
    }
    
    // Convert to char vectors for indexing
    let s1_chars: Vec<char> = s1.chars().collect();
    let s2_chars: Vec<char> = s2.chars().collect();
    
    // Use two rows instead of full matrix for memory efficiency
    let mut prev_row: Vec<usize> = (0..=s2_len).collect();
    let mut curr_row = vec![0; s2_len + 1];
    
    for i in 1..=s1_len {
        curr_row[0] = i;
        for j in 1..=s2_len {
            let cost = if s1_chars[i - 1] == s2_chars[j - 1] { 0 } else { 1 };
            curr_row[j] = min(
                min(prev_row[j] + 1, curr_row[j - 1] + 1), // insertion, deletion
                prev_row[j - 1] + cost, // substitution
            );
        }
        // Swap rows
        std::mem::swap(&mut prev_row, &mut curr_row);
    }
    
    prev_row[s2_len]
}

/// Calculate Jaro-Winkler similarity between two strings
/// Returns a value between 0.0 (no similarity) and 1.0 (exact match)
/// Jaro-Winkler gives more weight to strings that share a common prefix
pub fn jaro_winkler_similarity(s1: &str, s2: &str) -> f64 {
    if s1 == s2 {
        return 1.0;
    }
    
    let s1_len = s1.chars().count();
    let s2_len = s2.chars().count();
    
    if s1_len == 0 || s2_len == 0 {
        return 0.0;
    }
    
    // Convert to char vectors
    let s1_chars: Vec<char> = s1.chars().collect();
    let s2_chars: Vec<char> = s2.chars().collect();
    
    // Match window (half the distance between characters)
    let match_distance = max(s1_len, s2_len) / 2 - 1;
    
    // Find matches
    let mut s1_matches = vec![false; s1_len];
    let mut s2_matches = vec![false; s2_len];
    
    let mut matches = 0;
    let mut transpositions = 0.0;
    
    for i in 0..s1_len {
        let start = if i > match_distance { i - match_distance } else { 0 };
        let end = min(i + match_distance + 1, s2_len);
        
        for j in start..end {
            if s2_matches[j] || s1_chars[i] != s2_chars[j] {
                continue;
            }
            s1_matches[i] = true;
            s2_matches[j] = true;
            matches += 1;
            break;
        }
    }
    
    if matches == 0 {
        return 0.0;
    }
    
    // Count transpositions
    let mut k = 0;
    for i in 0..s1_len {
        if !s1_matches[i] {
            continue;
        }
        while !s2_matches[k] {
            k += 1;
        }
        if s1_chars[i] != s2_chars[k] {
            transpositions += 1.0;
        }
        k += 1;
    }
    
    // Calculate Jaro similarity
    let jaro = (matches as f64 / s1_len as f64 
        + matches as f64 / s2_len as f64 
        + (matches as f64 - transpositions / 2.0) / matches as f64) / 3.0;
    
    // Calculate common prefix (up to 4 characters)
    let mut prefix = 0;
    for (c1, c2) in s1_chars.iter().zip(s2_chars.iter()).take(4) {
        if c1 == c2 {
            prefix += 1;
        } else {
            break;
        }
    }
    
    // Calculate Jaro-Winkler similarity
    jaro + (prefix as f64 * 0.1 * (1.0 - jaro))
}

/// Check if a string matches a pattern with fuzzy matching
/// Returns true if the similarity is above the threshold
pub fn fuzzy_match(query: &str, target: &str, threshold: f64) -> bool {
    jaro_winkler_similarity(query, target) >= threshold
}

/// Calculate similarity percentage (0-100)
pub fn similarity_percent(query: &str, target: &str) -> f64 {
    jaro_winkler_similarity(query, target) * 100.0
}

/// Simple Soundex implementation for phonetic matching
/// Returns a 4-character code representing the sound of the word
pub fn soundex(word: &str) -> String {
    if word.is_empty() {
        return "0000".to_string();
    }
    
    let word_lower = word.to_uppercase();
    let chars: Vec<char> = word_lower.chars().collect();
    
    // Soundex mapping
    let mapping: HashMap<char, &str> = [
        ('B', "1"), ('F', "1"), ('P', "1"), ('V', "1"),
        ('C', "2"), ('G', "2"), ('J', "2"), ('K', "2"), ('Q', "2"), ('S', "2"), ('X', "2"), ('Z', "2"),
        ('D', "3"), ('T', "3"),
        ('L', "4"),
        ('M', "5"), ('N', "5"),
        ('R', "6"),
    ].iter().cloned().collect();
    
    // First letter
    let mut result = chars[0].to_string();
    let mut prev_code = mapping.get(&chars[0]).unwrap_or(&"");
    
    // Process remaining characters
    for c in &chars[1..] {
        let code = mapping.get(c).unwrap_or(&"");
        if code != prev_code && code != &"" {
            result.push_str(code);
        }
        prev_code = code;
        
        if result.len() >= 4 {
            break;
        }
    }
    
    // Pad with zeros if necessary
    while result.len() < 4 {
        result.push('0');
    }
    
    result
}

/// Simple Metaphone implementation for phonetic matching
/// Returns a more accurate phonetic code than Soundex
pub fn metaphone(word: &str) -> String {
    if word.is_empty() {
        return "".to_string();
    }
    
    let word_upper = word.to_uppercase();
    let mut chars: Vec<char> = word_upper.chars().collect();
    
    let mut result = String::new();
    let mut i = 0;
    
    while i < chars.len() && result.len() < 4 {
        match chars[i] {
            'A' | 'E' | 'I' | 'O' | 'U' => {
                if i == 0 {
                    result.push(chars[i]);
                }
                // Skip consecutive vowels
                while i + 1 < chars.len() && matches!(chars[i + 1], 'A' | 'E' | 'I' | 'O' | 'U') {
                    i += 1;
                }
            }
            'B' => result.push('B'),
            'C' => {
                if i + 1 < chars.len() {
                    match chars[i + 1] {
                        'I' | 'E' | 'Y' => result.push('S'),
                        'H' => {
                            // Silent 'C' after 'S'
                            if i > 0 && chars[i - 1] == 'S' {
                                // Skip
                            } else {
                                result.push('K');
                            }
                        }
                        _ => result.push('K'),
                    }
                } else {
                    result.push('K');
                }
            }
            'D' => {
                if i + 2 < chars.len() && chars[i + 1] == 'G' && matches!(chars[i + 2], 'E' | 'I' | 'Y') {
                    result.push('J');
                    i += 2;
                } else {
                    result.push('D');
                }
            }
            'F' => result.push('F'),
            'G' => {
                if i + 1 < chars.len() && chars[i + 1] == 'H' {
                    // Silent 'G' before 'H'
                } else if i + 1 < chars.len() && chars[i + 1] == 'N' {
                    if i + 2 < chars.len() && chars[i + 2] == 'E' {
                        result.push('N');
                        i += 2;
                    } else {
                        result.push('N');
                    }
                } else if i + 1 < chars.len() && chars[i + 1] == 'E' && i + 2 < chars.len() && chars[i + 2] == 'D' {
                    // 'GED' - keep 'G' but skip 'ED'
                    result.push('K');
                } else {
                    result.push('K');
                }
            }
            'H' => {
                // H is silent after vowels unless followed by vowel
                if i == 0 || !matches!(chars[i - 1], 'A' | 'E' | 'I' | 'O' | 'U') {
                    if i + 1 < chars.len() && !matches!(chars[i + 1], 'A' | 'E' | 'I' | 'O' | 'U') {
                        result.push('H');
                    }
                }
            }
            'J' => result.push('J'),
            'K' => {
                if i > 0 && chars[i - 1] == 'C' {
                    // Silent 'K' after 'C'
                } else {
                    result.push('K');
                }
            }
            'L' => result.push('L'),
            'M' => result.push('M'),
            'N' => result.push('N'),
            'P' => {
                if i + 1 < chars.len() && chars[i + 1] == 'H' {
                    result.push('F');
                    i += 1;
                } else {
                    result.push('P');
                }
            }
            'Q' => result.push('K'),
            'R' => result.push('R'),
            'S' => {
                if i + 1 < chars.len() && chars[i + 1] == 'C' && i + 2 < chars.len() && matches!(chars[i + 2], 'I' | 'E' | 'Y') {
                    result.push('S');
                    i += 2;
                } else if i + 1 < chars.len() && chars[i + 1] == 'H' {
                    // 'SH' sound
                    result.push('X');
                    i += 1;
                } else {
                    result.push('S');
                }
            }
            'T' => {
                if i + 1 < chars.len() && chars[i + 1] == 'C' && i + 2 < chars.len() && matches!(chars[i + 2], 'I' | 'E' | 'Y') {
                    result.push('X');
                    i += 2;
                } else if i + 1 < chars.len() && chars[i + 1] == 'H' {
                    result.push('X');
                    i += 1;
                } else if i + 2 < chars.len() && chars[i + 1] == 'C' && chars[i + 2] == 'H' {
                    result.push('X');
                    i += 2;
                } else {
                    result.push('T');
                }
            }
            'V' => result.push('F'),
            'W' => {
                if i + 1 < chars.len() && matches!(chars[i + 1], 'A' | 'E' | 'I' | 'O' | 'U') {
                    result.push('W');
                }
            }
            'X' => result.push('K'),
            'Y' => {
                if i + 1 < chars.len() && matches!(chars[i + 1], 'A' | 'E' | 'I' | 'O' | 'U') {
                    result.push('Y');
                }
            }
            'Z' => result.push('S'),
            _ => {}
        }
        i += 1;
    }
    
    result
}

/// Check if two words sound similar using Soundex
pub fn sounds_like(word1: &str, word2: &str) -> bool {
    soundex(word1) == soundex(word2)
}

#[cfg(test)]
mod tests {
    use super::*;
    
    #[test]
    fn test_levenshtein_basic() {
        assert_eq!(levenshtein_distance("kitten", "sitting"), 3);
        assert_eq!(levenshtein_distance("", ""), 0);
        assert_eq!(levenshtein_distance("abc", ""), 3);
        assert_eq!(levenshtein_distance("", "abc"), 3);
    }
    
    #[test]
    fn test_jaro_winkler() {
        // Same string should return 1.0
        assert!((jaro_winkler_similarity("hello", "hello") - 1.0).abs() < 0.001);
        
        // Empty strings should return 0.0
        assert!((jaro_winkler_similarity("", "hello") - 0.0).abs() < 0.001);
        
        // Similar strings should have high score
        let score = jaro_winkler_similarity("hello", "hallo");
        assert!(score > 0.8);
    }
    
    #[test]
    fn test_fuzzy_match() {
        assert!(fuzzy_match("hello", "hallo", 0.7));
        assert!(!fuzzy_match("hello", "world", 0.7));
    }
    
    #[test]
    fn test_soundex() {
        assert_eq!(soundex("Robert"), "R163");
        assert_eq!(soundex("Rupert"), "R163");
        assert_eq!(soundex("Rubin"), "R150");
        assert_eq!(soundex("Ashcraft"), "A261");
    }
    
    #[test]
    fn test_metaphone() {
        // Should produce same code for similar sounding words
        assert_eq!(metaphone("cat"), metaphone("kat"));
        assert_eq!(metaphone("hello"), metaphone("helo"));
    }
    
    #[test]
    fn test_sounds_like() {
        assert!(sounds_like("Smith", "Smythe"));
        assert!(!sounds_like("Smith", "Jones"));
    }
}