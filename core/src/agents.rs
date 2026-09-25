//! Projects the user's agents have worked in, for "import from agents".
//!
//! Every Codex / Claude session records the folder it ran in. Those folders are folded into their
//! Git repository (a subfolder or linked worktree counts toward the main repo), counted per agent,
//! and searched here, so the app only draws the result.

use crate::sessions::{scan_all, Session};
use serde::Serialize;
use std::collections::HashMap;
use std::path::Path;
use std::sync::Mutex;
use std::time::{Duration, Instant};

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct AgentProject {
    /// Repository root (main worktree), or the folder itself when it is not a Git repo.
    pub root: String,
    pub name: String,
    pub codex: u32,
    pub claude: u32,
    /// Unix seconds of the most recent session there.
    pub last_used: u64,
    pub git: bool,
    /// A per-chat scratch folder of the Codex desktop app (~/Documents/Codex/...).
    pub scratch: bool,
}

/// Groups sessions by repository. Folders that no longer exist, the home folder and `/` are left out.
pub fn group(sessions: &[Session], home: &Path) -> Vec<AgentProject> {
    let home_s = home.to_string_lossy().into_owned();
    let scratch_prefix = format!("{home_s}/Documents/Codex");
    let mut root_of: HashMap<&str, Option<(String, bool)>> = HashMap::new();
    let mut by_root: HashMap<String, AgentProject> = HashMap::new();
    for s in sessions {
        let resolved = root_of.entry(s.cwd.as_str()).or_insert_with(|| {
            let p = Path::new(&s.cwd);
            if !p.is_dir() {
                return None;
            }
            Some(match crate::git::repo_info(p) {
                Some(info) => (info.root, true),
                None => (s.cwd.trim_end_matches('/').to_string(), false),
            })
        });
        let Some((root, git)) = resolved.clone() else { continue };
        if root == home_s || root == "/" || root.is_empty() {
            continue;
        }
        let e = by_root.entry(root.clone()).or_insert_with(|| AgentProject {
            name: Path::new(&root).file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| root.clone()),
            scratch: root == scratch_prefix || root.starts_with(&(scratch_prefix.clone() + "/")),
            root,
            codex: 0,
            claude: 0,
            last_used: 0,
            git,
        });
        match s.kind.as_str() {
            "codex" => e.codex += 1,
            "claude" => e.claude += 1,
            _ => {}
        }
        e.last_used = e.last_used.max(s.last_activity);
    }
    let mut out: Vec<AgentProject> = by_root.into_values().collect();
    out.sort_by(|a, b| b.last_used.cmp(&a.last_used).then_with(|| a.root.cmp(&b.root)));
    out
}

/// Score of `query` against a project: exact / prefix / substring of the name, then the initials of
/// its words ("ssm" → supply-smart-mono) or its pinyin, then the path. `None` = no match.
pub fn score(query: &str, p: &AgentProject) -> Option<u32> {
    let q = query.trim().to_lowercase();
    if q.is_empty() {
        return Some(0);
    }
    let name = p.name.to_lowercase();
    let path = p.root.to_lowercase();
    if name == q {
        return Some(100);
    }
    if name.starts_with(&q) {
        return Some(80);
    }
    if name.contains(&q) {
        return Some(60);
    }
    let initials = crate::text::pinyin_keys(&p.name).initials;
    let full = crate::text::pinyin_keys(&p.name).full;
    if initials.starts_with(&q) || full.starts_with(&q) {
        return Some(55);
    }
    let words: String = name.split(|c: char| !c.is_alphanumeric()).filter_map(|w| w.chars().next()).collect();
    if q.chars().count() >= 2 && words.starts_with(&q) {
        return Some(50);
    }
    path.contains(&q).then_some(40)
}

/// Matching projects, best first (then most recently used). The scan is cached briefly so typing
/// in the search field does not walk the disk again on every key.
pub fn search(home: &Path, query: &str) -> Vec<AgentProject> {
    static CACHE: Mutex<Option<(Instant, String, Vec<AgentProject>)>> = Mutex::new(None);
    let key = home.to_string_lossy().into_owned();
    let all = {
        let mut guard = CACHE.lock().unwrap_or_else(|e| e.into_inner());
        match guard.as_ref() {
            Some((at, h, list)) if *h == key && at.elapsed() < Duration::from_secs(10) => list.clone(),
            _ => {
                let list = group(&scan_all(home, Duration::MAX), home);
                *guard = Some((Instant::now(), key, list.clone()));
                list
            }
        }
    };
    let mut hits: Vec<(u32, AgentProject)> = all.into_iter().filter_map(|p| score(query, &p).map(|s| (s, p))).collect();
    hits.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| b.1.last_used.cmp(&a.1.last_used)));
    hits.into_iter().map(|(_, p)| p).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn session(kind: &str, cwd: &str, t: u64) -> Session {
        Session { id: format!("{kind}:{t}"), kind: kind.into(), agent_session_id: t.to_string(), cwd: cwd.into(), title: String::new(), last_activity: t }
    }

    #[test]
    fn folds_subfolders_and_worktrees_into_their_repo_and_skips_noise() {
        let n = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos();
        let home = std::env::temp_dir().join(format!("wbagents-{}-{n}", std::process::id()));
        let repo = home.join("repo");
        fs::create_dir_all(repo.join(".git/worktrees/wt")).unwrap();
        fs::create_dir_all(repo.join("packages/app")).unwrap();
        let wt = home.join("wt");
        fs::create_dir_all(&wt).unwrap();
        fs::write(wt.join(".git"), format!("gitdir: {}/.git/worktrees/wt\n", repo.display())).unwrap();
        fs::write(repo.join(".git/worktrees/wt/gitdir"), format!("{}/.git\n", wt.display())).unwrap();
        fs::write(repo.join(".git/worktrees/wt/commondir"), "../..\n").unwrap();
        let plain = home.join("notes");
        fs::create_dir_all(&plain).unwrap();
        let scratch = home.join("Documents/Codex/2026-09-24/new-chat");
        fs::create_dir_all(&scratch).unwrap();
        let s = |p: &std::path::Path| p.to_string_lossy().into_owned();

        let list = group(&[
            session("codex", &s(&repo), 10),
            session("claude", &s(&repo.join("packages/app")), 30),
            session("codex", &s(&wt), 20),
            session("claude", &s(&plain), 5),
            session("codex", &s(&scratch), 40),
            session("codex", &s(&home), 50),                  // the home folder itself: not a project
            session("codex", "/nowhere/that/exists", 60),     // gone
        ], &home);
        let names: Vec<_> = list.iter().map(|p| (p.name.as_str(), p.codex, p.claude, p.git, p.scratch)).collect();
        assert_eq!(names, vec![("new-chat", 1, 0, false, true), ("repo", 2, 1, true, false), ("notes", 0, 1, false, false)]);
        assert_eq!(list[1].last_used, 30);

        let repo_p = list[1].clone();
        assert!(score("repo", &repo_p).unwrap() > score("rep", &repo_p).unwrap());
        assert_eq!(score("zzz", &repo_p), None);
        assert_eq!(score("rp", &repo_p), None, "no loose letter-by-letter matches");
        let ssm = AgentProject { root: "/x/supply-smart-mono".into(), name: "supply-smart-mono".into(), codex: 0, claude: 0, last_used: 0, git: true, scratch: false };
        assert!(score("ssm", &ssm).is_some());
        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn pinyin_initials_match_chinese_names() {
        let p = AgentProject { root: "/x/同花顺".into(), name: "同花顺".into(), codex: 1, claude: 0, last_used: 1, git: false, scratch: false };
        assert!(score("ths", &p).is_some());
        assert!(score("tonghua", &p).is_some());
    }
}
