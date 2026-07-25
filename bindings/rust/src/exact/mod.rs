//! Exact search — where is this pattern, byte for byte.
//!
//! The rg-shaped half of the binding: [`SearchRequest`] is the whole query
//! surface, [`Match`](crate::Match) is one hit, and under `native` a warm
//! [`Engine`] / pull [`Cursor`] stream them without a subprocess.

mod aggregate;
#[cfg(feature = "native")]
mod cursor;
mod rank;
mod request;

/// The `[row_schemas].ranked` id — the one row shape this module produces.
const RANKED_SCHEMA: u32 = 22;

pub use aggregate::{Axis, Group, Tally, tally, tally_by};
#[cfg(feature = "native")]
pub use cursor::{Batches, CancelToken, Cursor, DEFAULT_BATCH, Engine, Run};
pub use request::{SearchEngine, SearchRequest};
