#!/usr/bin/env node
/**
 * @purpose PreToolUse 安全门:拦截危险 Bash 命令(rm -rf、git --no-verify、强推、破坏性 SQL、动 .env)。
 * @role    强制层 sensor;Claude Code(.claude/settings.json)与 Codex(.codex/hooks.json)共用同一脚本。
 * @deps    node 内置;读 stdin 的 hook JSON(两工具字段一致:tool_input.command)
 * @gotcha  非安全边界(agent 可绕),只拦高频误操作;按需增删 RULES。输出 deny JSON 两工具通用。
 */
import { readFileSync } from 'node:fs';

let payload = {};
try { payload = JSON.parse(readFileSync(0, 'utf8') || '{}'); } catch {}
const cmd = payload?.tool_input?.command ?? '';

const RULES = [
  { re: /\brm\s+-[a-z]*r[a-z]*f|\brm\s+-[a-z]*f[a-z]*r/i, why: '禁止 rm -rf。要删除请指明精确路径并人工确认。' },
  { re: /git\s+commit\b[^\n]*--no-verify/, why: '禁止 git commit --no-verify(不得绕过 pre-commit 校验)。' },
  { re: /git\s+push\b[^\n]*--force(?!-with-lease)/, why: '禁止 git push --force,请用 --force-with-lease。' },
  { re: /\b(drop|truncate)\s+table\b/i, why: '禁止破坏性 SQL(DROP / TRUNCATE TABLE)。' },
  { re: /(^|[\s;&|])(rm|mv)\s[^\n]*\.env\b|>\s*\.env\b/, why: '禁止删除/覆盖 .env。' },
  // Seperate 特有:用户在运行中的 Seperate 里跑 agent,退出/重启它会杀掉会话;截图/鼠标注入会触发权限弹窗导致 App 重启。见 ADR-0005。
  { re: /\b(killall|pkill)\b[^\n]*Seperate|osascript\b[^\n]*Seperate[^\n]*\bquit\b|\bopen\b[^\n]*Seperate\.app/i, why: '禁止启动/退出/重启 Seperate(用户正在里面跑 agent)。安装新版请原地替换 /Applications/Seperate.app,由用户自己重启。' },
  { re: /\bscreencapture\b|\bcliclick\b/, why: '禁止截图/模拟鼠标:会触发 Seperate 的系统权限弹窗,授权后 App 会重启。需要看界面请让用户看。' },
  { re: /(^|[\s;&|])(cat|less|head|tail|more|bat)\s[^\n]*\.secrets\b/, why: '禁止读取 .secrets(签名/公证密钥)。' },
];

for (const r of RULES) {
  if (r.re.test(cmd)) {
    process.stdout.write(JSON.stringify({
      hookSpecificOutput: {
        hookEventName: 'PreToolUse',
        permissionDecision: 'deny',
        permissionDecisionReason: r.why,
      },
    }));
    process.exit(0);
  }
}
process.exit(0);
