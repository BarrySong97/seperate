# 测试 & 验证策略

## 原则
- **真跑验证**:不只看测试通过 / 读代码;能跑的路径都跑一遍。
- **不要碰正在运行的 Seperate**:用户在 Seperate 里跑着 agent(包括你自己)。不要退出/重启它,不要截图、模拟鼠标、做 AX 查询(会触发系统权限弹窗,授权后 App 重启)。需要看界面时请用户看。
- **聚焦子集**:先 `swift test --filter <TestClass>` 跑受影响的测试,收尾再全量。

## 测什么
- 单元(`Tests/WorkbenchTests/`,XCTest):纯逻辑优先 —— 模糊搜索、布局树、Store 状态变更、hook 事件解析、粘贴处理、侧边栏排序。
- Rust(`core/`):git / 会话扫描 / 文本工具等纯函数,`cargo test`(在 `core/` 下)。
- UI:AppKit 视图目前无自动化测试;把可测逻辑抽成纯函数 / 模型再测(`SidebarTests` 即此做法)。

## 怎么跑
```bash
scripts/build-core.sh && swift test          # 全量(CI 同款)
swift test --filter LayoutModelTests         # 单个测试类
(cd core && cargo test)                      # Rust 单元测试
```
详见 [run.md](run.md)。

## 覆盖期望
- 改 `Model/`、`Layout/`、`core/` 的逻辑必须有对应测试(新增或更新)。
- 修 bug 先写一个能复现的失败测试(Ratchet)。

## 验证某个改动是否真生效
1. `swift test` 通过。
2. `scripts/build-app.sh release` 构建,并按 [run.md](run.md) 的「本地安装」把 `/Applications/Seperate.app` 原地替换(旧包移到 `~/.Trash`)。
3. 告诉用户「已构建并安装,重启 Seperate 试用」,由用户自己重启验证 UI。说清哪些改动已安装、哪些只是构建了。
