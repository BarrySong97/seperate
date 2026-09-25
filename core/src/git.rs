//! Repository and worktree discovery by reading git's own files.
//! No `git` process is spawned: on this machine spawning anything costs ~70 ms.
//!
//! Layout git uses:
//!   main worktree:    <root>/.git/                      (a directory)
//!   linked worktree:  <path>/.git  = "gitdir: <root>/.git/worktrees/<name>"
//!   registry:         <root>/.git/worktrees/<name>/gitdir = "<path>/.git"

use serde::Serialize;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct Worktree {
    pub path: String,
    pub is_main: bool,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct RepoInfo {
    /// Main worktree root (the directory that holds the real `.git` directory).
    pub root: String,
    pub worktrees: Vec<Worktree>,
}

/// Finds the repository that contains `path`, or `None` for a plain folder.
pub fn repo_info(path: &Path) -> Option<RepoInfo> {
    let common = common_dir(path)?;
    let root = common.parent()?.to_path_buf();
    let mut worktrees = vec![Worktree { path: display(&root), is_main: true }];
    if let Ok(entries) = fs::read_dir(common.join("worktrees")) {
        let mut linked: Vec<PathBuf> = entries
            .flatten()
            .filter_map(|e| {
                let gitdir = fs::read_to_string(e.path().join("gitdir")).ok()?;
                // "<path>/.git\n" → <path>
                let p = PathBuf::from(gitdir.trim());
                let wt = p.parent()?.to_path_buf();
                wt.is_dir().then_some(wt)
            })
            .collect();
        linked.sort();
        worktrees.extend(linked.into_iter().map(|p| Worktree { path: display(&p), is_main: false }));
    }
    Some(RepoInfo { root: display(&root), worktrees })
}

/// Walks up from `path` to the nearest `.git`, then resolves the shared `.git` directory.
fn common_dir(path: &Path) -> Option<PathBuf> {
    let mut dir = if path.is_dir() { path.to_path_buf() } else { path.parent()?.to_path_buf() };
    loop {
        let dotgit = dir.join(".git");
        if dotgit.is_dir() {
            return Some(dotgit);
        }
        if dotgit.is_file() {
            // Linked worktree: gitdir points at <common>/worktrees/<name>.
            let content = fs::read_to_string(&dotgit).ok()?;
            let gitdir = content.trim().strip_prefix("gitdir:")?.trim();
            let gitdir = absolutize(&dir, Path::new(gitdir));
            let common = match fs::read_to_string(gitdir.join("commondir")) {
                Ok(rel) => absolutize(&gitdir, Path::new(rel.trim())),
                Err(_) => gitdir.parent()?.parent()?.to_path_buf(),
            };
            return Some(normalize(&common));
        }
        if !dir.pop() {
            return None;
        }
    }
}

fn absolutize(base: &Path, p: &Path) -> PathBuf {
    if p.is_absolute() { p.to_path_buf() } else { normalize(&base.join(p)) }
}

/// Removes `.` and `..` components without touching the file system.
fn normalize(p: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for c in p.components() {
        match c {
            std::path::Component::ParentDir => {
                out.pop();
            }
            std::path::Component::CurDir => {}
            other => out.push(other.as_os_str()),
        }
    }
    out
}

fn display(p: &Path) -> String {
    p.to_string_lossy().into_owned()
}

/// Creates a detached worktree at `dir`. Rare, user-initiated: shelling out is fine here.
pub fn worktree_add(root: &Path, dir: &Path) -> Result<(), String> {
    let out = Command::new("/usr/bin/git")
        .arg("-C")
        .arg(root)
        .args(["worktree", "add", "--detach"])
        .arg(dir)
        .output()
        .map_err(|e| e.to_string())?;
    if out.status.success() {
        Ok(())
    } else {
        Err(String::from_utf8_lossy(&out.stderr).trim().to_string())
    }
}

fn git(dir: &Path, args: &[&str]) -> Result<String, String> {
    let out = Command::new("/usr/bin/git").arg("-C").arg(dir).args(args).output().map_err(|e| e.to_string())?;
    if out.status.success() {
        Ok(String::from_utf8_lossy(&out.stdout).into_owned())
    } else {
        Err(String::from_utf8_lossy(&out.stderr).trim().to_string())
    }
}

/// What deleting a worktree would throw away.
#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct WorktreeStatus {
    /// The folder is gone (only git's record is left).
    pub missing: bool,
    /// Uncommitted changes, untracked files included.
    pub dirty: u32,
    /// The first few `git status --porcelain` lines, e.g. " M src/app.ts".
    pub changed: Vec<String>,
    /// Checked-out branch; `None` when detached.
    pub branch: Option<String>,
    /// Commits not on the upstream branch; `None` without an upstream.
    pub ahead: Option<u32>,
}

pub fn worktree_status(path: &Path) -> WorktreeStatus {
    if !path.is_dir() {
        return WorktreeStatus { missing: true, dirty: 0, changed: vec![], branch: None, ahead: None };
    }
    let lines: Vec<String> = git(path, &["status", "--porcelain=v1"])
        .map(|o| o.lines().filter(|l| !l.is_empty()).map(str::to_string).collect())
        .unwrap_or_default();
    let branch = git(path, &["symbolic-ref", "--short", "-q", "HEAD"]).ok().map(|b| b.trim().to_string()).filter(|b| !b.is_empty());
    let ahead = git(path, &["rev-list", "--count", "@{upstream}..HEAD"]).ok().and_then(|n| n.trim().parse().ok());
    WorktreeStatus { missing: false, dirty: lines.len() as u32, changed: lines.into_iter().take(10).collect(), branch, ahead }
}

/// `git worktree remove`; `force` also discards uncommitted changes. A worktree whose folder is
/// already gone is cleaned out of git's records with `git worktree prune` instead.
pub fn worktree_remove(root: &Path, path: &Path, force: bool) -> Result<(), String> {
    if !path.exists() {
        return git(root, &["worktree", "prune"]).map(|_| ());
    }
    let p = path.to_string_lossy();
    let mut args = vec!["worktree", "remove"];
    if force {
        args.push("--force");
    }
    args.push(&p);
    match git(root, &args) {
        Ok(_) => Ok(()),
        Err(e) if e.contains("is not a working tree") => git(root, &["worktree", "prune"]).map(|_| ()),
        Err(e) => Err(e),
    }
}

/// Deletes a branch only when it is merged (`git branch -d`); an unmerged one is kept and the error says so.
pub fn branch_delete(root: &Path, branch: &str) -> Result<(), String> {
    git(root, &["branch", "-d", branch]).map(|_| ())
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct Branch {
    pub name: String,
    /// Unix seconds of the tip commit.
    pub updated: u64,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq, Default)]
pub struct Branches {
    pub local: Vec<Branch>,
    pub remote: Vec<Branch>,
}

/// Local and remote branches, most recently updated first. No fetch: what git already knows.
pub fn list_branches(root: &Path) -> Branches {
    let read = |refs: &str| -> Vec<Branch> {
        git(root, &["for-each-ref", "--sort=-committerdate", "--format=%(refname:short)%09%(committerdate:unix)", refs])
            .unwrap_or_default()
            .lines()
            .filter_map(|l| {
                let (name, t) = l.split_once('\t')?;
                Some(Branch { name: name.to_string(), updated: t.trim().parse().unwrap_or(0) })
            })
            .collect()
    };
    let remote = read("refs/remotes")
        .into_iter()
        // "origin/HEAD" and the bare remote name ("origin") are pointers, not branches.
        .filter(|b| b.name.contains('/') && !b.name.ends_with("/HEAD"))
        .collect();
    Branches { local: read("refs/heads"), remote }
}

/// A new worktree at `dir` starting from `base`: on a new branch `branch`, or detached when `None`.
pub fn worktree_add_from(root: &Path, dir: &Path, branch: Option<&str>, base: &str) -> Result<(), String> {
    let d = dir.to_string_lossy();
    let mut args = vec!["worktree", "add"];
    match branch {
        Some(b) => {
            args.push("-b");
            args.push(b);
        }
        None => args.push("--detach"),
    }
    args.push(&d);
    args.push(base);
    git(root, &args).map(|_| ())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp() -> PathBuf {
        let d = std::env::temp_dir().join(format!("wbcore-{}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        d
    }

    /// A real repository (needs /usr/bin/git) with one commit on `main`.
    fn real_repo(name: &str) -> Option<PathBuf> {
        let d = std::env::temp_dir().join(format!("wbgit-{}-{name}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).ok()?;
        let run = |args: &[&str]| git(&d, args).ok();
        run(&["init", "-q", "-b", "main"])?;
        fs::write(d.join("a.txt"), "a").ok()?;
        run(&["add", "."])?;
        run(&["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "init"])?;
        Some(d)
    }

    #[test]
    fn remove_refuses_dirty_worktrees_unless_forced() {
        let Some(root) = real_repo("rm") else { return };
        let wt = root.with_extension("wt");
        let _ = fs::remove_dir_all(&wt);
        worktree_add_from(&root, &wt, Some("feat/x"), "main").unwrap();
        let st = worktree_status(&wt);
        assert_eq!((st.missing, st.dirty, st.branch.as_deref()), (false, 0, Some("feat/x")));

        fs::write(wt.join("new.txt"), "untracked").unwrap();
        let st = worktree_status(&wt);
        assert_eq!(st.dirty, 1);
        assert_eq!(st.changed, vec!["?? new.txt"]);
        assert!(worktree_remove(&root, &wt, false).is_err(), "untracked files block a plain remove");
        assert!(wt.exists());
        worktree_remove(&root, &wt, true).unwrap();
        assert!(!wt.exists());

        // Merged branch goes; an unmerged one is kept.
        branch_delete(&root, "feat/x").unwrap();
        let wt2 = root.with_extension("wt2");
        let _ = fs::remove_dir_all(&wt2);
        worktree_add_from(&root, &wt2, Some("feat/y"), "main").unwrap();
        fs::write(wt2.join("b.txt"), "b").unwrap();
        git(&wt2, &["add", "."]).unwrap();
        git(&wt2, &["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "y"]).unwrap();
        worktree_remove(&root, &wt2, false).unwrap();
        assert!(branch_delete(&root, "feat/y").is_err(), "unmerged branches are never deleted");

        let names: Vec<_> = list_branches(&root).local.into_iter().map(|b| b.name).collect();
        assert!(names.contains(&"main".to_string()) && names.contains(&"feat/y".to_string()));
        fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn a_worktree_whose_folder_is_gone_is_pruned() {
        let Some(root) = real_repo("gone") else { return };
        let wt = root.with_extension("gone");
        let _ = fs::remove_dir_all(&wt);
        worktree_add_from(&root, &wt, None, "main").unwrap();
        assert_eq!(repo_info(&root).unwrap().worktrees.len(), 2);
        fs::remove_dir_all(&wt).unwrap();
        assert!(worktree_status(&wt).missing);
        worktree_remove(&root, &wt, false).unwrap();
        assert!(!fs::read_dir(root.join(".git/worktrees")).map(|mut d| d.next().is_some()).unwrap_or(false));
        fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn finds_main_and_linked_worktrees_without_git() {
        let t = temp();
        let root = t.join("repo");
        let linked = t.join("repo-test");
        fs::create_dir_all(root.join(".git/worktrees/test")).unwrap();
        fs::create_dir_all(&linked).unwrap();
        fs::create_dir_all(root.join("src")).unwrap();
        fs::write(root.join(".git/worktrees/test/gitdir"), format!("{}/.git\n", linked.display())).unwrap();
        fs::write(root.join(".git/worktrees/test/commondir"), "../..\n").unwrap();
        fs::write(linked.join(".git"), format!("gitdir: {}/.git/worktrees/test\n", root.display())).unwrap();

        let from_main = repo_info(&root.join("src")).unwrap();
        let from_linked = repo_info(&linked).unwrap();
        assert_eq!(from_main, from_linked);
        assert_eq!(from_main.root, root.to_string_lossy());
        assert_eq!(from_main.worktrees.len(), 2);
        assert!(from_main.worktrees[0].is_main);
        assert_eq!(from_main.worktrees[1].path, linked.to_string_lossy());
        assert!(repo_info(&t).is_none());
    }
}
