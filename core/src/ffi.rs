//! C ABI for the Swift app. Results are JSON strings owned by Rust; free them with `wb_free`.

use std::ffi::{c_char, CStr, CString};
use std::path::Path;
use std::time::Duration;

fn arg(p: *const c_char) -> Option<&'static str> {
    if p.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(p) }.to_str().ok()
}

fn out<T: serde::Serialize>(v: &T) -> *mut c_char {
    match serde_json::to_string(v) {
        Ok(s) => CString::new(s).map(CString::into_raw).unwrap_or(std::ptr::null_mut()),
        Err(_) => std::ptr::null_mut(),
    }
}

/// JSON `{root, worktrees:[{path, is_main}]}` for the repository containing `path`; NULL for a plain folder.
#[no_mangle]
pub extern "C" fn wb_repo_info(path: *const c_char) -> *mut c_char {
    match arg(path).and_then(|p| crate::git::repo_info(Path::new(p))) {
        Some(info) => out(&info),
        None => std::ptr::null_mut(),
    }
}

/// JSON `{ok: bool, error: string}` after `git worktree add --detach <dir>`.
#[no_mangle]
pub extern "C" fn wb_worktree_add(root: *const c_char, dir: *const c_char) -> *mut c_char {
    #[derive(serde::Serialize)]
    struct R { ok: bool, error: String }
    let r = match (arg(root), arg(dir)) {
        (Some(r), Some(d)) => match crate::git::worktree_add(Path::new(r), Path::new(d)) {
            Ok(()) => R { ok: true, error: String::new() },
            Err(e) => R { ok: false, error: e },
        },
        _ => R { ok: false, error: "bad arguments".into() },
    };
    out(&r)
}

/// JSON array of sessions under `home` modified within the last `days`; 0 = every session, no age limit.
#[no_mangle]
pub extern "C" fn wb_scan_sessions(home: *const c_char, days: u32) -> *mut c_char {
    let Some(h) = arg(home) else { return std::ptr::null_mut() };
    let max_age = if days == 0 { Duration::MAX } else { Duration::from_secs(u64::from(days) * 86_400) };
    out(&crate::sessions::scan_all(Path::new(h), max_age))
}

/// JSON `{missing, dirty, changed, branch, ahead}` for a worktree folder.
#[no_mangle]
pub extern "C" fn wb_worktree_status(path: *const c_char) -> *mut c_char {
    match arg(path) {
        Some(p) => out(&crate::git::worktree_status(Path::new(p))),
        None => std::ptr::null_mut(),
    }
}

/// `git worktree remove` (`force` != 0 discards changes; a missing folder is pruned). JSON `{ok, error}`.
#[no_mangle]
pub extern "C" fn wb_worktree_remove(root: *const c_char, path: *const c_char, force: u8) -> *mut c_char {
    outcome(match (arg(root), arg(path)) {
        (Some(r), Some(p)) => crate::git::worktree_remove(Path::new(r), Path::new(p), force != 0),
        _ => Err("bad arguments".into()),
    })
}

/// `git branch -d` (merged branches only). JSON `{ok, error}`.
#[no_mangle]
pub extern "C" fn wb_branch_delete(root: *const c_char, branch: *const c_char) -> *mut c_char {
    outcome(match (arg(root), arg(branch)) {
        (Some(r), Some(b)) => crate::git::branch_delete(Path::new(r), b),
        _ => Err("bad arguments".into()),
    })
}

/// JSON `{local: [{name, updated}], remote: [...]}`, most recently updated first.
#[no_mangle]
pub extern "C" fn wb_list_branches(root: *const c_char) -> *mut c_char {
    match arg(root) {
        Some(r) => out(&crate::git::list_branches(Path::new(r))),
        None => std::ptr::null_mut(),
    }
}

/// `git worktree add` at `dir` from `base`, on new branch `branch` (NULL = detached). JSON `{ok, error}`.
#[no_mangle]
pub extern "C" fn wb_worktree_add_from(root: *const c_char, dir: *const c_char, branch: *const c_char, base: *const c_char) -> *mut c_char {
    outcome(match (arg(root), arg(dir), arg(base)) {
        (Some(r), Some(d), Some(b)) => crate::git::worktree_add_from(Path::new(r), Path::new(d), arg(branch), b),
        _ => Err("bad arguments".into()),
    })
}

/// Creates a new project folder at `dir` (and `git init`s it when `init` != 0). JSON `{ok, error}`.
#[no_mangle]
pub extern "C" fn wb_project_create(dir: *const c_char, init: u8) -> *mut c_char {
    outcome(match arg(dir) {
        Some(d) => crate::git::project_create(Path::new(d), init != 0),
        None => Err("bad arguments".into()),
    })
}

/// JSON array of the projects the user's agents worked in (see `agents::AgentProject`), filtered by
/// `query` (name, pinyin, path) and ranked; an empty query lists them all, most recently used first.
#[no_mangle]
pub extern "C" fn wb_agent_projects(home: *const c_char, query: *const c_char) -> *mut c_char {
    let Some(h) = arg(home) else { return std::ptr::null_mut() };
    out(&crate::agents::search(Path::new(h), arg(query).unwrap_or("")))
}

/// Absolute path of the project's own icon (favicon / app icon), or NULL.
#[no_mangle]
pub extern "C" fn wb_project_icon(root: *const c_char) -> *mut c_char {
    arg(root)
        .and_then(|r| crate::icon::find_icon(Path::new(r)))
        .and_then(|p| CString::new(p.to_string_lossy().into_owned()).ok())
        .map_or(std::ptr::null_mut(), CString::into_raw)
}

/// JSON `{initials, full, owner}` pinyin search keys for `text`.
#[no_mangle]
pub extern "C" fn wb_pinyin_keys(text: *const c_char) -> *mut c_char {
    match arg(text) {
        Some(t) => out(&crate::text::pinyin_keys(t)),
        None => std::ptr::null_mut(),
    }
}

#[derive(serde::Serialize)]
struct Outcome { ok: bool, error: String }

fn outcome(r: Result<(), String>) -> *mut c_char {
    out(&match r { Ok(()) => Outcome { ok: true, error: String::new() }, Err(error) => Outcome { ok: false, error } })
}

/// Opens (creating/migrating) the app database at `path`. JSON `{ok, error}`.
#[no_mangle]
pub extern "C" fn wb_db_open(path: *const c_char) -> *mut c_char {
    outcome(arg(path).ok_or_else(|| "bad path".to_string()).and_then(crate::db::open))
}

/// The stored app state as JSON (see `db::State`), or NULL if the database is not open.
#[no_mangle]
pub extern "C" fn wb_db_load() -> *mut c_char {
    crate::db::load().map_or(std::ptr::null_mut(), |s| out(&s))
}

/// Replaces the stored app state with the JSON `db::State`, in one transaction. JSON `{ok, error}`.
#[no_mangle]
pub extern "C" fn wb_db_save(state: *const c_char) -> *mut c_char {
    let r = arg(state).ok_or_else(|| "bad argument".to_string())
        .and_then(|j| serde_json::from_str::<crate::db::State>(j).map_err(|e| e.to_string()))
        .and_then(|s| crate::db::save(&s));
    outcome(r)
}

#[no_mangle]
pub extern "C" fn wb_free(s: *mut c_char) {
    if !s.is_null() {
        unsafe { drop(CString::from_raw(s)) };
    }
}
