#ifndef WORKBENCH_CORE_H
#define WORKBENCH_CORE_H

#include <stdint.h>

/* All returned strings are JSON, owned by Rust, and must be released with wb_free. */

char *wb_repo_info(const char *path);
char *wb_worktree_add(const char *root, const char *dir);
char *wb_worktree_status(const char *path);                                  /* {missing,dirty,changed,branch,ahead} */
char *wb_worktree_remove(const char *root, const char *path, uint8_t force);  /* {ok, error} */
char *wb_branch_delete(const char *root, const char *branch);                 /* {ok, error}; merged only */
char *wb_list_branches(const char *root);                                     /* {local:[{name,updated}], remote:[...]} */
char *wb_worktree_add_from(const char *root, const char *dir, const char *branch, const char *base); /* branch NULL = detached */
char *wb_scan_sessions(const char *home, uint32_t days);   /* days = 0: no age limit */
char *wb_agent_projects(const char *home, const char *query);   /* [{root,name,codex,claude,last_used,git,scratch}] */
char *wb_project_icon(const char *root);   /* plain path, not JSON */
char *wb_pinyin_keys(const char *text);
char *wb_db_open(const char *path);      /* {ok, error} */
char *wb_db_load(void);                   /* app state, NULL if not open */
char *wb_db_save(const char *state_json); /* {ok, error} */
void wb_free(char *s);

#endif
