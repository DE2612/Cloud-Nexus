// Search module for CloudNexus
// Phase 1: Hybrid approach - Fuzzy matching and advanced search
// Phase 2: Full search features - Path building, batch indexing, suggestions, history

mod fuzzy;
mod index;
mod path;
mod batch;
mod incremental;
mod suggestions;
mod history;
mod bridge;

pub use fuzzy::*;
pub use index::*;
pub use path::*;
pub use batch::*;
pub use incremental::*;
pub use suggestions::*;
pub use history::*;
pub use bridge::*;