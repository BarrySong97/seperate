# Core(Rust 核心 + Swift 桥)

## 职责
所有碰文件系统、git、agent 会话存档和 SQLite 的逻辑都在 Rust crate `workbench-core`(`core/`)里;Swift 侧只通过 `Core` 枚举调用并绘制结果。
不管:UI、会话/布局状态机(`Store`)、终端。

## 文件清单与关系
- `core/src/lib.rs` — crate 根,声明模块
- `core/src/ffi.rs` — 全部 `wb_*` C ABI 导出
- `core/src/db.rs` — 应用 SQLite(schema、迁移、整份 State 读写)
- `core/src/git.rs` — 读 git 文件发现仓库/worktree;worktree、分支、新建项目等变更操作
- `core/src/sessions.rs` — 扫描 Codex / Claude Code 会话文件
- `core/src/agents.rs` — "从 agent 导入":把会话 cwd 折叠为项目并搜索
- `core/src/icon.rs` — 找项目自带图标
- `core/src/text.rs` — 拼音搜索键
- `core/include/workbench_core.h` + `core/include/module.modulemap` — C 头文件与 Clang 模块 `WorkbenchCore`,Swift `import WorkbenchCore` 就是它
- `scripts/build-core.sh` — `cargo build --release` 出 `libworkbench_core.a`,再 `xcodebuild -create-xcframework` 打成 `Vendor/WorkbenchCore.xcframework`(`Package.swift` 的 binaryTarget);`scripts/build-app.sh` 会先调用它
- `Sources/Workbench/Core/Core.swift` — Swift 桥:调用 `wb_*`、JSON 解码、`wb_free`
- 调用关系:`Store / UI → Core.swift → wb_*(ffi.rs) → db | git | sessions | agents | icon | text → SQLite / 文件系统 / /usr/bin/git`

## 数据流
- 所有调用都是同步的:参数是 C 字符串,返回值是 Rust 分配的 JSON C 字符串(或 NULL),Swift 解码后 `wb_free`。
- 数据库:`Store.load` 调 `Core.dbOpen(<数据目录>/seperate.db)` → `dbLoad` 得到整份 `DBState`;保存时 `dbSave` 把整份状态序列化后在一个事务里整体替换。数据目录默认 `~/Library/Application Support/Workbench/`,可用 `SEPERATE_DATA_DIR` 覆盖;`WORKBENCH_DEMO` 用 `seperate-demo.db`。打不开时退回旧的 `state.json`,首次成功导入后改名为 `state.json.bak`。
- 会话:`Core.scanSessions()`(在 `Store` 里 `Task.detached` 后台跑)→ `sessions::scan_all(home, 无年龄限制)` → Codex `~/.codex/sessions/**/rollout-*.jsonl` 首行 `session_meta` + `session_index.jsonl` 标题;Claude `~/.claude/projects/<编码 cwd>/<uuid>.jsonl` 读前 256 KB 取 cwd 和标题。
- 导入:`agents::search` 复用会话扫描结果 → `git::repo_info` 折叠到主仓库根 → 评分排序。

## 对外接口
- C ABI 见 `core/include/workbench_core.h`:`wb_repo_info`、`wb_worktree_add[_from]`、`wb_worktree_status`、`wb_worktree_remove`、`wb_branch_delete`、`wb_list_branches`、`wb_project_create`、`wb_scan_sessions`、`wb_agent_projects`、`wb_project_icon`、`wb_pinyin_keys`、`wb_db_open/load/save`、`wb_free`
- 变更类调用统一返回 `{ok, error}`;Swift 侧转成 `throws` 或错误字符串
- Swift 侧入口是 `enum Core` 的静态方法
- `Core.shotsRoot`(环境变量 `SEPERATE_SHOTS_ROOT`):设置时 `scanSessions` / `agentProjects` 只返回这个目录下的结果,供官网截图模式使用

## 注意事项
- **内存所有权**:所有非 NULL 返回值都由 Rust `CString::into_raw` 分配,必须且只能用 `wb_free` 释放(不能用 `free`)。`wb_project_icon` 例外地返回**纯路径而非 JSON**,Swift 侧单独处理,别套 JSON 解码。
- **三处必须同步**:新增/修改 `wb_*` 要同时改 `ffi.rs`、`workbench_core.h`、`Core.swift`,然后重跑 `scripts/build-core.sh` 重建 xcframework,否则 Swift 链接的是旧库。
- **DBState 编码**:`Core.DBState` 用显式 `CodingKeys` + 普通 `JSONDecoder`,**不能**用 snake_case 键策略——它会把字典键(文件路径)也改写。其余调用用 `convertFromSnakeCase`。字段须与 `db::State` 一一对应;新增字段在 Rust 侧加 `#[serde(default)]`、Swift 侧给默认值以兼容。
- **迁移只追加**:`MIGRATIONS` 按序执行并记录在 `PRAGMA user_version`;已发布的迁移不能修改或重排,新 schema 一律追加一条。连接开启 WAL、`foreign_keys`、`busy_timeout=2000`。
- **save 是整体替换**:除 sessions 外所有表先清空再写;sessions 做 upsert,并删除不在传入列表里的行(只存 app 自己创建或置顶的会话;对话内容永远不复制进库)。同一项目出现在两个 workspace 时保留第一个。颜色有 `#RRGGBB` CHECK 约束,违规会让整个事务失败且不改任何数据。
- **hidden_worktrees 是粘性的**:从 Seperate 移除的 worktree 刷新时即使再被发现也不能复活。
- **不要为发现逻辑 spawn git**:本机每次起进程约 70 ms,仓库/worktree 发现全靠读 `.git` 文件;只有 status、增删 worktree/分支、新建项目这些低频操作才调 `/usr/bin/git`(写死路径)。
- **分支删除只用 `-d`**:未合并分支永不删除。`worktree_remove` 在目录已不存在或 git 报 "is not a working tree" 时改走 `git worktree prune`。
- **线程**:`Core` 调用可在任意线程;DB 用全局 `Mutex<Option<Connection>>` 串行化,未 open 时 `wb_db_load` 返回 NULL。拼音缓存用 `NSLock` + `nonisolated(unsafe)`。`agents::search` 结果按 home 缓存 10 秒,避免每次按键重扫磁盘。
- **会话格式是 agent 私有格式**:Codex 以 `thread_source != "user"` 过滤子线程(审批 reviewer 等);Claude 标题优先 `summary`,否则第一条非 meta、不以 `<` 开头的用户输入。上游格式变化会静默丢会话。
- **crate 形态**:`staticlib + rlib`,release 开 LTO;`rusqlite` 使用 bundled SQLite。测试 `cargo test` 中部分用例需要 `/usr/bin/git`,缺失时自动跳过。
