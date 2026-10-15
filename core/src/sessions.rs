// @purpose Discovers Codex and Claude Code conversations from their on-disk transcripts.
// @role    Behind wb_scan_sessions; also feeds agents.rs.
// @deps    serde_json, ~/.codex and ~/.claude/projects file layouts
// @gotcha  Reads heads (and a Claude transcript's tail for its newest title), cached by size + mtime;
//          formats are the agents' private files and may change.
//          docs/modules/core/README.md
//! Discovers Codex and Claude Code conversations on disk.
//!
//! Codex:  ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl, first line is `session_meta`
//!         title = ~/.codex/session_index.jsonl (`{id, thread_name}` per line, last wins), else the
//!         first prompt the user typed (not the environment / AGENTS.md messages Codex adds)
//! Claude: ~/.claude/projects/<encoded cwd>/<uuid>.jsonl, entries carry `cwd`;
//!         title = the last `custom-title` / `ai-title` / `agent-name` entry (rewritten as the session
//!         goes on, so read from the end), else a `summary`, else the first plain user prompt
//!         (a string, or the text blocks of a list as the Agent SDK writes it)
//! Heads and tails are only read again when a file's size or mtime changed (see `cached`).

use serde::Serialize;
use serde_json::Value;
use std::collections::HashMap;
use std::fs::{self, File};
use std::io::{BufRead, BufReader, Read};
use std::io::{Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const HEAD: usize = 256 * 1024;
/// How far back from the end to look for the newest title entry.
const TAIL_STEPS: [u64; 3] = [256 * 1024, 1024 * 1024, 4 * 1024 * 1024];

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
        let title = match titles.get(id) {
            Some(t) => t.clone(),
            None => cached(&CODEX_PROMPT, &file, modified, codex_first_prompt).unwrap_or_default(), // empty: the app shows "Codex session"
        };
        by_id.insert(
            id.to_string(),
            Session {
                id: format!("codex:{id}"),
                kind: "codex".into(),
                agent_session_id: id.to_string(),
                cwd: cwd.to_string(),
                title,
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
        let Some((cwd, title)) = cached(&CLAUDE_META, &file, modified, claude_meta) else { continue };
        out.push(Session {
            id: format!("claude:{sid}"),
            kind: "claude".into(),
            agent_session_id: sid,
            cwd,
            title: title.unwrap_or_default(), // empty: the app shows its own "Claude session"
            last_activity: unix(modified),
        });
    }
    out
}

/// Per-file results keyed by path, valid while size and mtime stay the same, so a scan only re-reads
/// the transcripts that changed (a running agent's, mostly).
type Cache<T> = Mutex<HashMap<PathBuf, (SystemTime, u64, Option<T>)>>;
static CLAUDE_META: OnceLock<Cache<(String, Option<String>)>> = OnceLock::new();
static CODEX_PROMPT: OnceLock<Cache<String>> = OnceLock::new();

fn cached<T: Clone>(cache: &OnceLock<Cache<T>>, file: &Path, modified: SystemTime, read: fn(&Path) -> Option<T>) -> Option<T> {
    let cache = cache.get_or_init(Default::default);
    let size = fs::metadata(file).map(|m| m.len()).unwrap_or(0);
    if let Some((m, s, v)) = cache.lock().unwrap().get(file) {
        if *m == modified && *s == size {
            return v.clone();
        }
    }
    let v = read(file);
    cache.lock().unwrap().insert(file.to_path_buf(), (modified, size, v.clone()));
    v
}

/// Names a Claude transcript gives itself; a later entry replaces an earlier one.
#[derive(Default)]
struct ClaudeNames {
    custom: Option<String>,
    ai: Option<String>,
    agent: Option<String>,
}

impl ClaudeNames {
    fn take(&mut self, v: &Value) {
        let text = |k: &str| v[k].as_str().map(str::trim).filter(|t| !t.is_empty()).map(str::to_string);
        match v["type"].as_str() {
            Some("custom-title") => self.custom = text("customTitle").or(self.custom.take()),
            Some("ai-title") => self.ai = text("aiTitle").or(self.ai.take()),
            Some("agent-name") => self.agent = text("agentName").or(self.agent.take()),
            _ => {}
        }
    }
    fn found(&self) -> bool { self.custom.is_some() || self.ai.is_some() || self.agent.is_some() }
    fn best(self) -> Option<String> { self.custom.or(self.ai).or(self.agent) }
}

/// The first thing the user wrote: a plain string, or the text blocks of a list (Agent SDK, Codex).
/// Wrapped context (`<command-name>`, `<environment_context>`, …) and Codex's AGENTS.md message are skipped.
fn prompt_text(content: &Value) -> Option<String> {
    let texts: Vec<&str> = match content {
        Value::String(s) => vec![s.as_str()],
        Value::Array(blocks) => blocks
            .iter()
            .filter(|b| matches!(b["type"].as_str(), Some("text" | "input_text")))
            .filter_map(|b| b["text"].as_str())
            .collect(),
        _ => vec![],
    };
    texts
        .into_iter()
        .map(str::trim)
        .find(|t| !t.is_empty() && !t.starts_with('<') && !t.starts_with("# AGENTS.md instructions"))
        .map(unquote)
}

/// Chat bridges (a Feishu bot) send "[Quoted message from User]:\n<the quoted message>\n\n<the reply>":
/// the reply is what this prompt asks; without one, the quote.
fn unquote(t: &str) -> String {
    let mut lines = t.lines();
    let first = lines.next().unwrap_or("").trim();
    if !(first.starts_with('[') && first.ends_with("]:")) {
        return t.to_string();
    }
    let rest = lines.collect::<Vec<_>>().join("\n");
    let paragraphs: Vec<&str> = rest.split("\n\n").map(str::trim).filter(|p| !p.is_empty()).collect();
    paragraphs.last().map(|p| p.to_string()).unwrap_or_else(|| t.to_string())
}

/// A Claude transcript's cwd and a human title.
fn claude_meta(file: &Path) -> Option<(String, Option<String>)> {
    let head = read_head(file, HEAD)?;
    let (mut cwd, mut summary, mut first_prompt) = (None, None, None);
    let mut names = ClaudeNames::default();
    for (i, line) in head.split(|b| *b == b'\n').enumerate() {
        let Ok(v) = serde_json::from_slice::<Value>(line) else { continue };
        names.take(&v);
        if i >= 400 {
            continue;
        }
        if cwd.is_none() {
            cwd = v["cwd"].as_str().map(str::to_string);
        }
        if summary.is_none() && v["type"] == "summary" {
            summary = v["summary"].as_str().map(str::to_string);
        }
        if first_prompt.is_none() && v["type"] == "user" && v["isMeta"] != true {
            first_prompt = prompt_text(&v["message"]["content"]);
        }
    }
    let cwd = cwd?;
    // Titles are rewritten as the conversation goes on: the newest one is near the end.
    let size = fs::metadata(file).map(|m| m.len()).unwrap_or(0);
    if size > HEAD as u64 {
        for step in TAIL_STEPS {
            let mut tail = ClaudeNames::default();
            let Some(bytes) = read_tail(file, step.min(size)) else { break };
            for line in bytes.split(|b| *b == b'\n').skip(1) {   // the first line may be cut
                if contains(line, b"-title") || contains(line, b"agent-name") {
                    if let Ok(v) = serde_json::from_slice::<Value>(line) {
                        tail.take(&v);
                    }
                }
            }
            if tail.found() {
                names = ClaudeNames { custom: tail.custom.or(names.custom), ai: tail.ai.or(names.ai), agent: tail.agent.or(names.agent) };
                break;
            }
            if step >= size {
                break;
            }
        }
    }
    let title = names.best().or(summary).or(first_prompt).map(|t| one_line(&t, 40));
    Some((cwd, title))
}

/// The first prompt the user typed in a Codex rollout (its `response_item` user messages).
fn codex_first_prompt(file: &Path) -> Option<String> {
    let head = read_head(file, 1024 * 1024)?;
    for line in head.split(|b| *b == b'\n').skip(1) {
        if !contains(line, br#""role":"user""#) {
            continue;
        }
        let Ok(v) = serde_json::from_slice::<Value>(line) else { continue };
        let p = &v["payload"];
        if v["type"] == "response_item" && p["type"] == "message" && p["role"] == "user" {
            if let Some(t) = prompt_text(&p["content"]) {
                return Some(one_line(&t, 40));
            }
        }
    }
    None
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

/// Cheap check before parsing a line as JSON.
fn contains(hay: &[u8], needle: &[u8]) -> bool {
    hay.windows(needle.len()).any(|w| w == needle)
}

fn read_tail(p: &Path, len: u64) -> Option<Vec<u8>> {
    let mut f = File::open(p).ok()?;
    f.seek(SeekFrom::End(-(len as i64))).ok()?;
    let mut buf = Vec::with_capacity(len as usize);
    f.read_to_end(&mut buf).ok()?;
    Some(buf)
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

    #[test]
    fn claude_title_prefers_its_own_newest_name_and_reads_sdk_prompts() {
        let root = std::env::temp_dir().join(format!("wbcore-names-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let proj = root.join("-Users-x-proj");
        fs::create_dir_all(&proj).unwrap();
        // Agent SDK: the prompt is a list of blocks; no title entry yet.
        fs::write(
            proj.join("sdk.jsonl"),
            r#"{"type":"user","cwd":"/Users/x/proj","message":{"content":[{"type":"text","text":"执行KAN-199测试基线"}]}}"#,
        )
        .unwrap();
        // A long session: its ai-title was rewritten, and the newest one is past the head.
        let mut long = String::from(r#"{"type":"user","cwd":"/Users/x/proj","message":{"content":"<command-name>/model</command-name>"}}"#);
        long += "\n";
        long += r#"{"type":"ai-title","aiTitle":"旧标题"}"#;
        long += "\n";
        let filler = format!(r#"{{"type":"assistant","message":{{"content":"{}"}}}}"#, "x".repeat(1000)) + "\n";
        while long.len() < HEAD + 300 * 1024 {
            long += &filler;
        }
        long += r#"{"type":"ai-title","aiTitle":"新标题"}"#;
        long += "\n";
        long += &filler.repeat(10);
        fs::write(proj.join("long.jsonl"), &long).unwrap();
        let found = scan_claude(&root, UNIX_EPOCH);
        let title = |id: &str| found.iter().find(|s| s.agent_session_id == id).unwrap().title.clone();
        assert_eq!(title("sdk"), "执行KAN-199测试基线");
        assert_eq!(title("long"), "新标题");
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn codex_title_falls_back_to_the_first_typed_prompt() {
        let root = std::env::temp_dir().join(format!("wbcore-codexp-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let day = root.join("sessions/2026/10/15");
        fs::create_dir_all(&day).unwrap();
        let user = |t: &str| format!(r#"{{"type":"response_item","payload":{{"type":"message","role":"user","content":[{{"type":"input_text","text":"{t}"}}]}}}}"#);
        fs::write(
            day.join("rollout-1.jsonl"),
            [
                r#"{"type":"session_meta","payload":{"id":"c1","cwd":"/tmp/p","thread_source":"user"}}"#.to_string(),
                user("# AGENTS.md instructions for /tmp/p"),
                user("<environment_context><cwd>/tmp/p</cwd></environment_context>"),
                user("修一下登录页"),
            ]
            .join("\n"),
        )
        .unwrap();
        let found = scan_codex(&root, UNIX_EPOCH);
        assert_eq!(found[0].title, "修一下登录页");
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn quoted_chat_messages_are_titled_by_the_reply() {
        assert_eq!(unquote("[Quoted message from User]:\n@bot 汇报一下\n\n\n你帮 claude 合并一下"), "你帮 claude 合并一下");
        assert_eq!(unquote("[Quoted message from User]:\n@bot 你能做什么"), "@bot 你能做什么");
        assert_eq!(unquote("[x] 不是标签\n第二行"), "[x] 不是标签\n第二行");
    }
}
