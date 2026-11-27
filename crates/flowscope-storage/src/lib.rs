//! Storage contracts and Neo4j persistence. The parser has no storage side effects.
mod model;
mod neo4j;
mod normalize;

pub use model::*;
pub use neo4j::{Neo4jConfig, Neo4jStore};
pub use normalize::{normalize, Snapshot};

use sha2::{Digest, Sha256};

pub fn digest(value: impl AsRef<[u8]>) -> String {
    format!("{:x}", Sha256::digest(value.as_ref()))
}

#[derive(Debug, thiserror::Error)]
pub enum StorageError {
    #[error("invalid storage input: {0}")]
    Invalid(String),
    #[error("event or source version conflicts with existing content")]
    Conflict,
    #[error("Neo4j operation failed: {0}")]
    Database(#[from] neo4rs::Error),
    #[error("storage serialization failed: {0}")]
    Json(#[from] serde_json::Error),
}
impl StorageError {
    /// Safe, stable diagnostic code; driver messages can contain query content.
    pub fn database_code(&self) -> Option<&str> {
        match self {
            Self::Database(neo4rs::Error::Neo4j(error)) => Some(error.code()),
            _ => None,
        }
    }
    pub fn retryable(&self) -> bool {
        match self {
            Self::Database(neo4rs::Error::Neo4j(e)) => {
                !(e.code().starts_with("Neo.ClientError.Statement.")
                    || e.code().starts_with("Neo.ClientError.Schema."))
            }
            Self::Database(_) => true,
            _ => false,
        }
    }
}

pub trait LineageStore: Send + Sync {
    fn apply(
        &self,
        event: &StorageEvent,
    ) -> impl std::future::Future<Output = Result<ApplyOutcome, StorageError>> + Send;
}
