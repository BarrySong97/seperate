//! The app's own data in SQLite: workspaces (color, order, pane layout), the projects in each
//! (one workspace per project, in the user's order), worktree names, settings, and the sessions
//! the app owns something about (started here, or pinned). Conversation content stays in the
//! agents' own files and is never copied here.

use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashSet};
use std::sync::Mutex;

static DB: Mutex<Option<Connection>> = Mutex::new(None);

/// Everything the app persists, exchanged with Swift as one JSON document.
#[derive(Serialize, Deserialize, Debug, Default, PartialEq)]
pub struct State {
    pub active_id: String,
    pub workspaces: Vec<WorkspaceRow>,          // in the user's order
    pub aliases: BTreeMap<String, String>,       // worktree path → name
    #[serde(default)]
    pub worktree_order: BTreeMap<String, Vec<String>>,   // project root → worktree paths, in the user's order
    #[serde(default)]
    pub hidden_worktrees: Vec<HiddenWorktree>,           // removed from Seperate only; still on disk
    pub settings: BTreeMap<String, String>,
    pub sessions: Vec<SessionRow>,
}

#[derive(Serialize, Deserialize, Debug, PartialEq)]
pub struct WorkspaceRow {
    pub id: String,
    pub name: String,
    pub icon: String,
    pub color: String,                           // "#RRGGBB"
    pub layout: String,                          // pane tree as JSON, loaded whole
    pub projects: Vec<String>,                   // project root paths, in the user's order
}

#[derive(Serialize, Deserialize, Debug, PartialEq)]
pub struct HiddenWorktree {
    pub path: String,
    pub project_root: String,
    pub hidden_at: i64,                          // unix ms
}

#[derive(Serialize, Deserialize, Debug, PartialEq)]
pub struct SessionRow {
    pub id: String,
    pub kind: String,
    pub agent_session_id: Option<String>,
    pub origin: String,                          // "created" | "discovered"
    pub cwd: String,
    pub title: String,
    pub custom_title: Option<String>,
    pub created_at: i64,                         // unix ms
    pub last_activity_at: i64,
    pub pinned: bool,
}

/// Schema versions, applied in order; `PRAGMA user_version` records how many have run.
const MIGRATIONS: &[&str] = &[
    "CREATE TABLE workspaces (
        id          TEXT PRIMARY KEY,
        name        TEXT NOT NULL,
        icon        TEXT NOT NULL,
        color       TEXT NOT NULL CHECK (color GLOB '#[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]'),
        position    INTEGER NOT NULL,
        layout_json TEXT NOT NULL
     );
     CREATE TABLE projects (
        root_path    TEXT PRIMARY KEY,
        workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
        position     INTEGER NOT NULL
     );
     CREATE INDEX projects_order ON projects(workspace_id, position);
     CREATE TABLE worktree_aliases (
        path  TEXT PRIMARY KEY,
        alias TEXT NOT NULL
     );
     CREATE TABLE settings (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL
     );
     CREATE TABLE sessions (
        id               TEXT PRIMARY KEY,
        kind             TEXT NOT NULL CHECK (kind IN ('codex','claude','shell')),
        agent_session_id TEXT,
        origin           TEXT NOT NULL CHECK (origin IN ('created','discovered')),
        cwd              TEXT NOT NULL,
        title            TEXT NOT NULL,
        custom_title     TEXT,
        created_at       INTEGER NOT NULL,
        last_activity_at INTEGER NOT NULL,
        pinned           INTEGER NOT NULL DEFAULT 0
     );",
    // 2: the user's order of worktrees inside a project (worktrees themselves come from git).
    "CREATE TABLE worktree_positions (
        path         TEXT PRIMARY KEY,
        project_root TEXT NOT NULL,
        position     INTEGER NOT NULL
     );
     CREATE INDEX worktree_positions_order ON worktree_positions(project_root, position);",
    // 3: worktrees removed from Seperate only (the folder and git's record stay). Sticky: a refresh
    //    that finds the worktree again must not bring it back.
    "CREATE TABLE hidden_worktrees (
        path         TEXT PRIMARY KEY,
        project_root TEXT NOT NULL,
        hidden_at    INTEGER NOT NULL
     );",
];

const ACTIVE_KEY: &str = "active_workspace";

fn migrate(conn: &mut Connection) -> rusqlite::Result<()> {
    let done: usize = conn.query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))? as usize;
    for (i, sql) in MIGRATIONS.iter().enumerate().skip(done) {
        let tx = conn.transaction()?;
        tx.execute_batch(sql)?;
        tx.pragma_update(None, "user_version", (i + 1) as i64)?;
        tx.commit()?;
    }
    Ok(())
}

pub fn open_at(path: &str) -> Result<Connection, String> {
    let mut conn = Connection::open(path).map_err(|e| e.to_string())?;
    conn.execute_batch("PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON; PRAGMA busy_timeout = 2000;")
        .map_err(|e| e.to_string())?;
    migrate(&mut conn).map_err(|e| e.to_string())?;
    Ok(conn)
}

/// Opens (creating and migrating as needed) the database the other calls use.
pub fn open(path: &str) -> Result<(), String> {
    let conn = open_at(path)?;
    *DB.lock().map_err(|_| "database lock poisoned")? = Some(conn);
    Ok(())
}

fn with<T>(f: impl FnOnce(&mut Connection) -> rusqlite::Result<T>) -> Result<T, String> {
    let mut guard = DB.lock().map_err(|_| "database lock poisoned".to_string())?;
    let conn = guard.as_mut().ok_or("database not open")?;
    f(conn).map_err(|e| e.to_string())
}

pub fn load() -> Result<State, String> { with(|c| read(c)) }
pub fn save(s: &State) -> Result<(), String> { with(|c| write(c, s)) }

pub fn read(conn: &Connection) -> rusqlite::Result<State> {
    let mut s = State::default();
    let mut ws = conn.prepare("SELECT id, name, icon, color, layout_json FROM workspaces ORDER BY position")?;
    let mut ps = conn.prepare("SELECT root_path FROM projects WHERE workspace_id = ?1 ORDER BY position")?;
    let rows = ws.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)))?;
    for row in rows {
        let (id, name, icon, color, layout): (String, String, String, String, String) = row?;
        let projects = ps.query_map([&id], |r| r.get(0))?.collect::<rusqlite::Result<Vec<String>>>()?;
        s.workspaces.push(WorkspaceRow { id, name, icon, color, layout, projects });
    }
    let mut q = conn.prepare("SELECT path, alias FROM worktree_aliases")?;
    for row in q.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))? {
        let (k, v) = row?;
        s.aliases.insert(k, v);
    }
    let mut q = conn.prepare("SELECT project_root, path FROM worktree_positions ORDER BY project_root, position")?;
    for row in q.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))? {
        let (root, path) = row?;
        s.worktree_order.entry(root).or_default().push(path);
    }
    let mut q = conn.prepare("SELECT path, project_root, hidden_at FROM hidden_worktrees ORDER BY hidden_at DESC")?;
    for row in q.query_map([], |r| Ok(HiddenWorktree { path: r.get(0)?, project_root: r.get(1)?, hidden_at: r.get(2)? }))? {
        s.hidden_worktrees.push(row?);
    }
    let mut q = conn.prepare("SELECT key, value FROM settings")?;
    for row in q.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))? {
        let (k, v) = row?;
        if k == ACTIVE_KEY { s.active_id = v } else { s.settings.insert(k, v); }
    }
    let mut q = conn.prepare(
        "SELECT id, kind, agent_session_id, origin, cwd, title, custom_title, created_at, last_activity_at, pinned
         FROM sessions ORDER BY last_activity_at DESC")?;
    for row in q.query_map([], |r| Ok(SessionRow {
        id: r.get(0)?, kind: r.get(1)?, agent_session_id: r.get(2)?, origin: r.get(3)?, cwd: r.get(4)?,
        title: r.get(5)?, custom_title: r.get(6)?, created_at: r.get(7)?, last_activity_at: r.get(8)?,
        pinned: r.get::<_, i64>(9)? != 0,
    }))? {
        s.sessions.push(row?);
    }
    Ok(s)
}

/// Replaces the stored state in one transaction. A project listed in two workspaces keeps the first.
pub fn write(conn: &mut Connection, s: &State) -> rusqlite::Result<()> {
    let tx = conn.transaction()?;
    tx.execute("DELETE FROM projects", [])?;
    tx.execute("DELETE FROM workspaces", [])?;
    tx.execute("DELETE FROM worktree_aliases", [])?;
    tx.execute("DELETE FROM worktree_positions", [])?;
    tx.execute("DELETE FROM hidden_worktrees", [])?;
    tx.execute("DELETE FROM settings", [])?;
    {
        let mut ins_w = tx.prepare("INSERT INTO workspaces (id, name, icon, color, position, layout_json) VALUES (?1, ?2, ?3, ?4, ?5, ?6)")?;
        let mut ins_p = tx.prepare("INSERT INTO projects (root_path, workspace_id, position) VALUES (?1, ?2, ?3)")?;
        let mut seen = HashSet::new();
        for (i, w) in s.workspaces.iter().enumerate() {
            ins_w.execute(params![w.id, w.name, w.icon, w.color, i as i64, w.layout])?;
            let mut pos = 0i64;
            for root in &w.projects {
                if seen.insert(root.as_str()) {
                    ins_p.execute(params![root, w.id, pos])?;
                    pos += 1;
                }
            }
        }
        let mut ins_a = tx.prepare("INSERT INTO worktree_aliases (path, alias) VALUES (?1, ?2)")?;
        for (k, v) in &s.aliases { ins_a.execute(params![k, v])?; }
        let mut ins_h = tx.prepare("INSERT OR IGNORE INTO hidden_worktrees (path, project_root, hidden_at) VALUES (?1, ?2, ?3)")?;
        for h in &s.hidden_worktrees { ins_h.execute(params![h.path, h.project_root, h.hidden_at])?; }
        let mut ins_o = tx.prepare("INSERT OR IGNORE INTO worktree_positions (path, project_root, position) VALUES (?1, ?2, ?3)")?;
        for (root, paths) in &s.worktree_order {
            for (i, path) in paths.iter().enumerate() { ins_o.execute(params![path, root, i as i64])?; }
        }
        let mut ins_s = tx.prepare("INSERT INTO settings (key, value) VALUES (?1, ?2)")?;
        for (k, v) in &s.settings { ins_s.execute(params![k, v])?; }
        ins_s.execute(params![ACTIVE_KEY, s.active_id])?;

        // Sessions: upsert the ones given, drop the ones no longer owned by the app.
        let keep: HashSet<&str> = s.sessions.iter().map(|x| x.id.as_str()).collect();
        let existing: Vec<String> = tx.prepare("SELECT id FROM sessions")?
            .query_map([], |r| r.get(0))?.collect::<rusqlite::Result<_>>()?;
        let mut del = tx.prepare("DELETE FROM sessions WHERE id = ?1")?;
        for id in existing.iter().filter(|id| !keep.contains(id.as_str())) { del.execute([id])?; }
        let mut up = tx.prepare(
            "INSERT INTO sessions (id, kind, agent_session_id, origin, cwd, title, custom_title, created_at, last_activity_at, pinned)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
             ON CONFLICT(id) DO UPDATE SET kind = excluded.kind, agent_session_id = excluded.agent_session_id,
               origin = excluded.origin, cwd = excluded.cwd, title = excluded.title, custom_title = excluded.custom_title,
               last_activity_at = excluded.last_activity_at, pinned = excluded.pinned")?;
        for x in &s.sessions {
            up.execute(params![x.id, x.kind, x.agent_session_id, x.origin, x.cwd, x.title, x.custom_title,
                               x.created_at, x.last_activity_at, x.pinned as i64])?;
        }
    }
    tx.commit()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> State {
        State {
            active_id: "w2".into(),
            workspaces: vec![
                WorkspaceRow { id: "w1".into(), name: "默认".into(), icon: "默".into(), color: "#8FA7BA".into(),
                               layout: "{}".into(), projects: vec!["/a".into(), "/b".into()] },
                WorkspaceRow { id: "w2".into(), name: "个人".into(), icon: "个".into(), color: "#E8916C".into(),
                               layout: "{\"x\":1}".into(), projects: vec!["/c".into()] },
            ],
            aliases: BTreeMap::from([("/a/wt".into(), "wt".into())]),
            worktree_order: BTreeMap::from([("/a".into(), vec!["/a/wt".into(), "/a".into()])]),
            hidden_worktrees: vec![HiddenWorktree { path: "/a/old".into(), project_root: "/a".into(), hidden_at: 7 }],
            settings: BTreeMap::from([("show_older".into(), "false".into())]),
            sessions: vec![SessionRow { id: "codex:1".into(), kind: "codex".into(), agent_session_id: Some("1".into()),
                origin: "discovered".into(), cwd: "/a".into(), title: "t".into(), custom_title: None,
                created_at: 1, last_activity_at: 2, pinned: true }],
        }
    }

    fn temp() -> (tempdir::Dir, Connection) {
        let d = tempdir::Dir::new();
        let c = open_at(d.path.join("t.db").to_str().unwrap()).unwrap();
        (d, c)
    }

    #[test]
    fn round_trip_keeps_order_and_fields() {
        let (_d, mut c) = temp();
        let s = sample();
        write(&mut c, &s).unwrap();
        assert_eq!(read(&c).unwrap(), s);
    }

    #[test]
    fn a_project_lives_in_one_workspace() {
        let (_d, mut c) = temp();
        let mut s = sample();
        s.workspaces[1].projects.push("/a".into());   // also claimed by w1
        write(&mut c, &s).unwrap();
        let back = read(&c).unwrap();
        assert_eq!(back.workspaces[0].projects, vec!["/a", "/b"]);
        assert_eq!(back.workspaces[1].projects, vec!["/c"]);
    }

    #[test]
    fn unowned_sessions_are_dropped_and_bad_colors_refused() {
        let (_d, mut c) = temp();
        let mut s = sample();
        write(&mut c, &s).unwrap();
        s.sessions.clear();
        write(&mut c, &s).unwrap();
        assert!(read(&c).unwrap().sessions.is_empty());
        s.workspaces[0].color = "blue".into();
        assert!(write(&mut c, &s).is_err());
        assert_eq!(read(&c).unwrap().workspaces[0].color, "#8FA7BA", "a failed save changes nothing");
    }

    /// Minimal temp dir so tests need no extra crates.
    mod tempdir {
        pub struct Dir { pub path: std::path::PathBuf }
        impl Dir {
            pub fn new() -> Self {
                static NEXT: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
                let n = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                let path = std::env::temp_dir().join(format!("wbdb-{}-{n}", std::process::id()));
                std::fs::create_dir_all(&path).unwrap();
                Dir { path }
            }
        }
        impl Drop for Dir { fn drop(&mut self) { let _ = std::fs::remove_dir_all(&self.path); } }
    }
}
