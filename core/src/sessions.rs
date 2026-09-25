//! Discovers Codex and Claude Code conversations on disk.
//!
//! Codex:  ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl, first line is `session_meta`
//!         titles in ~/.codex/session_index.jsonl (`{id, thread_name}` per line, last wins)
//! Claude: ~/.claude/projects/<encoded cwd>/<uuid>.jsonl, entries carry `cwd`;
//!         title = `summary` entry, else the first plain user prompt

use serde::Serialize;
use serde_json::Value;
use std::collections::HashMap;
use std::fs::{self, File};
use std::io::{BufRead, BufReader, Read};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct Session {
    /// App-level id: "codex:<id>" / "claude:<uuid>".
    pub id: String,
    pub kind: String,
    pub agent_session_id: String,
    pub cwd: String,
    pub title: String,
    /// Unix seconds of the transcript's last modification.
    pub last_activity: u64,
}

pub fn scan_all(home: &Path, max_age: Duration) -> Vec<Session> {
    let cutoff = SystemTime::now().checked_sub(max_age).unwrap_or(UNIX_EPOCH);
    let mut out = scan_codex(&home.join(".codex"), cutoff);
    out.extend(scan_claude(&home.join(".claude/projects"), cutoff));
    out
}

pub fn scan_codex(root: &Path, cutoff: SystemTime) -> Vec<Session> {
    let titles = codex_titles(&root.join("session_index.jsonl"));
    let mut by_id: HashMap<String, Session> = HashMap::new();
    for (file, modified) in jsonl_files(&root.join("sessions"), cutoff, None) {
        let Some(line) = first_line(&file) else { continue };
        let Ok(v) = serde_json::from_slice::<Value>(&line) else { continue };
        if v["type"] != "session_meta" {
            continue;
        }
        let p = &v["payload"];
        let (Some(id), Some(cwd)) = (p["id"].as_str(), p["cwd"].as_str()) else { continue };
        // Approval reviewers and other sub-threads are not user conversations.
        if matches!(p["thread_source"].as_str(), Some(s) if s != "user") {
            continue;
        }
        let secs = unix(modified);
        if by_id.get(id).map_or(false, |s| s.last_activity >= secs) {
            continue;
        }
        by_id.insert(
            id.to_string(),
            Session {
                id: format!("codex:{id}"),
                kind: "codex".into(),
                agent_session_id: id.to_string(),
                cwd: cwd.to_string(),
                title: titles.get(id).cloned().unwrap_or_else(|| "Codex 会话".into()),
                last_activity: secs,
            },
        );
    }
    by_id.into_values().collect()
}

fn codex_titles(index: &Path) -> HashMap<String, String> {
    let mut titles = HashMap::new();
    let Ok(f) = File::open(index) else { return titles };
    for line in BufReader::new(f).lines().flatten() {
        if let Ok(v) = serde_json::from_str::<Value>(&line) {
            if let (Some(id), Some(name)) = (v["id"].as_str(), v["thread_name"].as_str()) {
                if !name.is_empty() {
                    titles.insert(id.to_string(), name.to_string());
                }
            }
        }
    }
    titles
}

pub fn scan_claude(root: &Path, cutoff: SystemTime) -> Vec<Session> {
    let mut out = Vec::new();
    for (file, modified) in jsonl_files(root, cutoff, Some(1)) {
        let sid = file.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
        let Some((cwd, title)) = claude_meta(&file) else { continue };
        out.push(Session {
            id: format!("claude:{sid}"),
            kind: "claude".into(),
            agent_session_id: sid,
            cwd,
            title: title.unwrap_or_else(|| "Claude 会话".into()),
            last_activity: unix(modified),
        });
    }
    out
}

/// Reads the head of a Claude transcript: its cwd and a human title.
fn claude_meta(file: &Path) -> Option<(String, Option<String>)> {
    let head = read_head(file, 256 * 1024)?;
    let (mut cwd, mut summary, mut first_prompt) = (None, None, None);
    for line in head.split(|b| *b == b'\n').take(400) {
        let Ok(v) = serde_json::from_slice::<Value>(line) else { continue };
        if cwd.is_none() {
            cwd = v["cwd"].as_str().map(str::to_string);
        }
        if summary.is_none() && v["type"] == "summary" {
            summary = v["summary"].as_str().map(str::to_string);
        }
        if first_prompt.is_none() && v["type"] == "user" && v["isMeta"] != true {
            if let Some(t) = v["message"]["content"].as_str() {
                if !t.starts_with('<') {
                    first_prompt = Some(t.to_string());
                }
            }
        }
        if cwd.is_some() && summary.is_some() {
            break;
        }
    }
    let cwd = cwd?;
    let title = summary.or(first_prompt).map(|t| one_line(&t, 40));
    Some((cwd, title))
}

/// `.jsonl` files under `dir` modified after `cutoff`; `max_depth` limits directory nesting.
fn jsonl_files(dir: &Path, cutoff: SystemTime, max_depth: Option<usize>) -> Vec<(PathBuf, SystemTime)> {
    let mut out = Vec::new();
    let mut stack = vec![(dir.to_path_buf(), 0usize)];
    while let Some((d, depth)) = stack.pop() {
        let Ok(entries) = fs::read_dir(&d) else { continue };
        for e in entries.flatten() {
            let p = e.path();
            let Ok(ft) = e.file_type() else { continue };
            if ft.is_dir() {
                if e.file_name().to_string_lossy().starts_with('.') {
                    continue;
                }
                if max_depth.map_or(true, |m| depth < m) {
                    stack.push((p, depth + 1));
                }
            } else if p.extension().map_or(false, |x| x == "jsonl") {
                if let Ok(m) = e.metadata().and_then(|m| m.modified()) {
                    if m >= cutoff {
                        out.push((p, m));
                    }
                }
            }
        }
    }
    out
}

/// First line without reading the whole file (Codex meta lines can be large).
fn first_line(p: &Path) -> Option<Vec<u8>> {
    let f = File::open(p).ok()?;
    let mut buf = Vec::new();
    BufReader::with_capacity(64 * 1024, f).read_until(b'\n', &mut buf).ok()?;
    if buf.last() == Some(&b'\n') {
        buf.pop();
    }
    (!buf.is_empty()).then_some(buf)
}

fn read_head(p: &Path, max: usize) -> Option<Vec<u8>> {
    let mut buf = Vec::with_capacity(max.min(64 * 1024));
    File::open(p).ok()?.take(max as u64).read_to_end(&mut buf).ok()?;
    Some(buf)
}

fn one_line(s: &str, max_chars: usize) -> String {
    let first = s.lines().next().unwrap_or(s).trim();
    if first.chars().count() > max_chars {
        format!("{}…", first.chars().take(max_chars).collect::<String>())
    } else {
        first.to_string()
    }
}

fn unix(t: SystemTime) -> u64 {
    t.duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn codex_scan_skips_sub_threads_and_uses_index_titles() {
        let root = std::env::temp_dir().join(format!("wbcore-sess-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let day = root.join("sessions/2026/09/23");
        fs::create_dir_all(&day).unwrap();
        let meta = |id: &str, src: &str| {
            format!(r#"{{"type":"session_meta","payload":{{"id":"{id}","cwd":"/tmp/p","thread_source":"{src}"}}}}"#) + "\n{}\n"
        };
        fs::write(day.join("rollout-1.jsonl"), meta("u1", "user")).unwrap();
        fs::write(day.join("rollout-2.jsonl"), meta("g1", "guardian")).unwrap();
        fs::write(root.join("session_index.jsonl"), r#"{"id":"u1","thread_name":"修复登录"}"#).unwrap();
        let found = scan_codex(&root, UNIX_EPOCH);
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].agent_session_id, "u1");
        assert_eq!(found[0].title, "修复登录");
        assert_eq!(found[0].cwd, "/tmp/p");
    }

    #[test]
    fn claude_title_prefers_summary_then_first_prompt() {
        let root = std::env::temp_dir().join(format!("wbcore-claude-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let proj = root.join("-Users-x-proj");
        fs::create_dir_all(&proj).unwrap();
        fs::write(
            proj.join("abc.jsonl"),
            concat!(
                r#"{"type":"user","cwd":"/Users/x/proj","message":{"content":"<system>meta</system>"},"isMeta":true}"#, "\n",
                r#"{"type":"user","cwd":"/Users/x/proj","message":{"content":"帮我修一下登录\n第二行"}}"#, "\n",
            ),
        )
        .unwrap();
        let found = scan_claude(&root, UNIX_EPOCH);
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].agent_session_id, "abc");
        assert_eq!(found[0].cwd, "/Users/x/proj");
        assert_eq!(found[0].title, "帮我修一下登录");
    }
}
