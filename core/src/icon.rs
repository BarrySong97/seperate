//! Finds a project's own icon (favicon / app icon) to use as its avatar in the sidebar.
//! Looks at the conventional places web, Next.js, Vite, Tauri and Electron projects keep one,
//! at the root and inside monorepo `apps/*` / `packages/*`.

use std::fs;
use std::path::{Path, PathBuf};

/// Relative locations, most specific first. Checked against each candidate base directory.
const CANDIDATES: &[&str] = &[
    "public/favicon.svg", "public/favicon.png", "public/favicon.ico",
    "public/icon.svg", "public/icon.png", "public/apple-touch-icon.png", "public/logo.svg", "public/logo.png",
    "app/icon.svg", "app/icon.png", "app/favicon.ico",
    "src/app/icon.svg", "src/app/icon.png", "src/app/favicon.ico",
    "static/favicon.svg", "static/favicon.png", "static/favicon.ico",
    "src-tauri/icons/128x128.png", "src-tauri/icons/icon.png",
    "assets/icon.png", "assets/logo.png", "assets/favicon.png",
    "resources/icon.png", "build/icon.png",
    "favicon.svg", "favicon.png", "favicon.ico", "icon.png", "logo.svg", "logo.png",
];

const MAX_BYTES: u64 = 1024 * 1024;

pub fn find_icon(root: &Path) -> Option<PathBuf> {
    let mut bases = vec![root.to_path_buf()];
    for group in ["apps", "packages"] {
        if let Ok(entries) = fs::read_dir(root.join(group)) {
            let mut dirs: Vec<PathBuf> = entries.flatten().map(|e| e.path()).filter(|p| p.is_dir()).collect();
            // Prefer the app most likely to be "the" product: web first, then alphabetical.
            dirs.sort_by_key(|p| {
                let n = p.file_name().map(|s| s.to_string_lossy().to_lowercase()).unwrap_or_default();
                (!(n == "web" || n == "www" || n == "site" || n == "app"), n)
            });
            bases.extend(dirs);
        }
    }
    for base in &bases {
        for rel in CANDIDATES {
            let p = base.join(rel);
            if let Ok(meta) = fs::metadata(&p) {
                if meta.is_file() && meta.len() > 0 && meta.len() <= MAX_BYTES {
                    return Some(p);
                }
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prefers_root_public_then_monorepo_web_app() {
        let t = std::env::temp_dir().join(format!("wbcore-icon-{}", std::process::id()));
        let _ = fs::remove_dir_all(&t);
        fs::create_dir_all(t.join("apps/admin/public")).unwrap();
        fs::create_dir_all(t.join("apps/web/public")).unwrap();
        fs::write(t.join("apps/admin/public/favicon.ico"), b"x").unwrap();
        fs::write(t.join("apps/web/public/favicon.svg"), b"<svg/>").unwrap();
        assert_eq!(find_icon(&t), Some(t.join("apps/web/public/favicon.svg")));

        fs::create_dir_all(t.join("public")).unwrap();
        fs::write(t.join("public/favicon.png"), b"x").unwrap();
        assert_eq!(find_icon(&t), Some(t.join("public/favicon.png")));

        let empty = t.join("empty");
        fs::create_dir_all(&empty).unwrap();
        assert_eq!(find_icon(&empty), None);
    }
}
