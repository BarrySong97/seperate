//! Workbench core: everything that touches the file system, git, or agent archives.
//! The Swift app only draws what this crate returns.

pub mod agents;
pub mod db;
pub mod ffi;
pub mod git;
pub mod icon;
pub mod sessions;
pub mod text;
