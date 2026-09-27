// @purpose Crate root of workbench-core; declares the modules.
// @role    Built as a staticlib by scripts/build-core.sh and linked into the Swift app.
// @deps    pinyin, rusqlite (bundled), serde, serde_json
// @gotcha  Only ffi.rs is the public C surface. docs/modules/core/README.md
//! Workbench core: everything that touches the file system, git, or agent archives.
//! The Swift app only draws what this crate returns.

pub mod agents;
pub mod db;
pub mod ffi;
pub mod git;
pub mod icon;
pub mod sessions;
pub mod text;
