#!/usr/bin/env node
/**
 * @purpose 跨工具防漂移检查器:校验源文件 AI 文件头、文档与代码是否同步、引用是否失效。
 * @role    AI-Doc-System 的收尾闸门;被 agent 的 DoD、Claude Code Stop hook、人工审计三种方式调用。
 * @deps    node 内置 fs/path/child_process、git(可选)
 * @gotcha  纯 node 无三方依赖;非 git 仓库自动跳过漂移检查;templates/ 与忽略目录不参与检查。
 */

import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { join, relative, dirname, resolve, sep } from 'node:path';
import { execSync } from 'node:child_process';

const ROOT = process.cwd();
const rawArgs = process.argv.slice(2);
const STRICT = rawArgs.includes('--strict');
const HOOK = rawArgs.includes('--hook');            // Stop hook 模式:硬错误 exit 2,让 Claude/Codex 真正拦截收尾
let BASE = null;                                     // 对比基准 ref:git diff <BASE>...HEAD(供 CI / 审一个分支)
{
  const i = rawArgs.findIndex((a) => a === '--base' || a.startsWith('--base='));
  if (i !== -1) BASE = rawArgs[i].includes('=') ? rawArgs[i].slice('--base='.length) : rawArgs[i + 1];
  if (BASE && !/^[\w./@~^-]+$/.test(BASE)) { console.error('⚠️  --base 引用含非法字符,已忽略'); BASE = null; }
}

if (rawArgs.includes('--help') || rawArgs.includes('-h')) {
  console.log(`check-docs — AI-Doc-System 防漂移检查器
用法: node scripts/check-docs.mjs [--strict] [--hook] [--base <ref>]
  --strict       把警告(⚠️)也算作失败
  --hook         Stop hook 模式:有硬错误时 exit 2 并把原因写 stderr(Claude/Codex 才会真正拦截收尾)
  --base <ref>   漂移检测改用 git diff <ref>...HEAD(对比已提交差异,供 CI / 审分支);并入未提交工作区
检查:
  ① 源文件是否缺 AI 文件头(@purpose 标记)
  ② 改动了某模块代码,但 docs/modules/<module>/ 未同步
  ③ 文档/文件头里引用的本地路径是否失效
可选配置: 仓库根放 check-docs.config.json 覆盖默认(sourceExts / sourceRoots / ignoreDirs / docsDir / moduleMap 等)`);
  process.exit(0);
}

const DEFAULTS = {
  sourceExts: ['.ts', '.tsx', '.js', '.jsx', '.mjs', '.cjs', '.vue', '.svelte', '.py', '.go', '.rs', '.java', '.kt', '.swift'],
  sourceRoots: [],            // 空 → 自动:有 src/ 则用 ['src'],否则用 ['.']
  ignoreDirs: ['node_modules', '.git', 'dist', 'build', '.next', 'out', 'coverage', '.turbo', '.cache', 'vendor', '.venv', 'venv', '__pycache__', '.idea', '.vscode', 'templates'],
  nonModuleDirs: ['scripts', 'test', 'tests', '__tests__', 'spec', 'bin', 'config', 'public', 'assets', 'types', 'typings', 'migrations'],
  headerMarker: '@purpose',
  headerScanLines: 20,
  docsDir: 'docs',
  moduleMap: {},              // 路径前缀 → 模块名(如 {"Sources/Workbench/UI/": "ui"});命中则优先于「源码根下第一级目录」规则
};

let CONFIG = { ...DEFAULTS };
const cfgPath = join(ROOT, 'check-docs.config.json');
if (existsSync(cfgPath)) {
  try { CONFIG = { ...DEFAULTS, ...JSON.parse(readFileSync(cfgPath, 'utf8')) }; }
  catch (e) { console.error('⚠️  check-docs.config.json 解析失败,改用默认配置:', e.message); }
}

const IGNORE = new Set(CONFIG.ignoreDirs);
const NON_MODULE = new Set(CONFIG.nonModuleDirs);
const hasSourceExt = (f) => CONFIG.sourceExts.some((e) => f.endsWith(e));
const toPosix = (p) => p.split(sep).join('/');

function walk(dir, acc = []) {
  let entries;
  try { entries = readdirSync(dir, { withFileTypes: true }); } catch { return acc; }
  for (const ent of entries) {
    const full = join(dir, ent.name);
    if (ent.isDirectory()) {
      if (IGNORE.has(ent.name)) continue;
      walk(full, acc);
    } else if (ent.isFile()) {
      acc.push(full);
    }
  }
  return acc;
}

// ── 收集源文件 ──────────────────────────────────────────────
const roots = CONFIG.sourceRoots.length
  ? CONFIG.sourceRoots
  : (existsSync(join(ROOT, 'src')) ? ['src'] : ['.']);

const sourceFiles = [];
for (const r of roots) {
  const base = join(ROOT, r);
  if (existsSync(base)) for (const f of walk(base)) if (hasSourceExt(f)) sourceFiles.push(f);
}

// ── 检查 ①:缺文件头 ────────────────────────────────────────
function readHead(file) {
  try {
    return readFileSync(file, 'utf8').split(/\r?\n/).slice(0, CONFIG.headerScanLines).join('\n');
  } catch { return ''; }
}
const missingHeaders = sourceFiles
  .filter((f) => !readHead(f).includes(CONFIG.headerMarker))
  .map((f) => toPosix(relative(ROOT, f)));

// ── 检查 ②:文档漂移(需 git) ──────────────────────────────
function gitChangedFiles(base) {
  try { execSync('git rev-parse --is-inside-work-tree', { cwd: ROOT, stdio: 'ignore' }); }
  catch { return null; }
  const files = new Set();
  const unquote = (p) => p.replace(/^"|"$/g, '');
  // 已提交差异(对比 base):供 CI / 审分支。base 已校验为安全 ref,可安全拼接。
  if (base) {
    try {
      const out = execSync(`git diff --name-only ${base}...HEAD`, { cwd: ROOT, encoding: 'utf8' });
      for (const l of out.split(/\r?\n/)) if (l.trim()) files.add(toPosix(unquote(l.trim())));
    } catch (e) { console.error(`⚠️  git diff ${base}...HEAD 失败(base 是否存在?):`, e.message); }
  }
  // 未提交工作区(始终并入)
  try {
    const out = execSync('git status --porcelain -uall', { cwd: ROOT, encoding: 'utf8' });
    for (const line of out.split(/\r?\n/)) {
      if (!line.trim()) continue;
      let p = line.slice(3);
      if (p.includes(' -> ')) p = p.split(' -> ')[1];   // 重命名取新名
      files.add(toPosix(unquote(p)));
    }
  } catch { /* ignore */ }
  return files;
}

const changed = gitChangedFiles(BASE);
const driftWarnings = [];
if (changed) {
  const prefixes = roots.map((r) => (r === '.' ? '' : toPosix(r) + '/'));
  const seen = new Set();
  const mapped = Object.entries(CONFIG.moduleMap).sort((a, b) => b[0].length - a[0].length);   // 最长前缀优先
  for (const cf of changed) {
    if (!hasSourceExt(cf)) continue;
    let mod = mapped.find(([p]) => cf.startsWith(p))?.[1];
    if (!mod) {
      const pre = prefixes.find((p) => p === '' || cf.startsWith(p));
      if (pre === undefined) continue;
      const rel = pre ? cf.slice(pre.length) : cf;
      const parts = rel.split('/');
      if (parts.length < 2) continue;                 // 直接在根下的文件,无模块目录
      mod = parts[0];
    }
    if (NON_MODULE.has(mod) || seen.has(mod)) continue;
    seen.add(mod);
    // 模块文档位置(按优先级):docs/modules/<mod>/(文件夹) → docs/modules/<mod>.md → docs/<mod>.md(兼容旧平铺)
    const folder = `${CONFIG.docsDir}/modules/${mod}`;
    const flatInModules = `${folder}.md`;
    const flatLegacy = `${CONFIG.docsDir}/${mod}.md`;
    if (existsSync(join(ROOT, folder))) {
      if (![...changed].some((f) => f.startsWith(folder + '/')))
        driftWarnings.push(`改动了 ${mod} 模块代码,但 ${folder}/ 下文档未同步更新`);
    } else if (existsSync(join(ROOT, flatInModules))) {
      if (!changed.has(flatInModules)) driftWarnings.push(`改动了 ${mod} 模块代码,但 ${flatInModules} 未同步更新`);
    } else if (existsSync(join(ROOT, flatLegacy))) {
      if (!changed.has(flatLegacy)) driftWarnings.push(`改动了 ${mod} 模块代码,但 ${flatLegacy} 未同步更新`);
    } else {
      driftWarnings.push(`模块 "${mod}" 有代码改动,但缺 ${folder}/README.md`);
    }
  }
}

// ── 检查 ③:失效引用 ────────────────────────────────────────
const brokenRefs = new Set();
const linkRe = /\[[^\]]*\]\(([^)\s]+)(?:\s+"[^"]*")?\)/g;
const isSkippableTarget = (t) => !t || /^(https?:|mailto:|tel:|data:|#)/i.test(t) || /[<>*]/.test(t);

for (const md of walk(ROOT).filter((f) => f.endsWith('.md'))) {
  let content;
  try { content = readFileSync(md, 'utf8'); } catch { continue; }
  let m;
  while ((m = linkRe.exec(content)) !== null) {
    let t = m[1].trim();
    if (isSkippableTarget(t)) continue;
    t = t.split('#')[0].split('?')[0];
    if (!t) continue;
    if (!existsSync(resolve(dirname(md), t))) {
      brokenRefs.add(`${toPosix(relative(ROOT, md))} → 引用不存在: ${t}`);
    }
  }
}
// 源文件头里引用的 docs/*.md
const docRefRe = /docs\/[A-Za-z0-9_./-]+\.md/g;
for (const f of sourceFiles) {
  const head = readHead(f);
  let m;
  while ((m = docRefRe.exec(head)) !== null) {
    const t = m[0];
    if (/[<>*]/.test(t)) continue;
    if (!existsSync(join(ROOT, t))) brokenRefs.add(`${toPosix(relative(ROOT, f))} 文件头 → 引用不存在: ${t}`);
  }
}

// ── 输出 ────────────────────────────────────────────────────
const lines = ['── check-docs ──', ''];
let hard = 0;
let soft = 0;

if (missingHeaders.length) {
  hard += missingHeaders.length;
  lines.push(`❌ 缺 AI 文件头 (${missingHeaders.length})`);
  for (const f of missingHeaders) lines.push(`   · ${f}`);
  lines.push('');
}
if (brokenRefs.size) {
  hard += brokenRefs.size;
  lines.push(`❌ 失效引用 (${brokenRefs.size})`);
  for (const r of brokenRefs) lines.push(`   · ${r}`);
  lines.push('');
}
if (driftWarnings.length) {
  soft += driftWarnings.length;
  lines.push(`⚠️  疑似文档漂移 (${driftWarnings.length})`);
  for (const w of driftWarnings) lines.push(`   · ${w}`);
  lines.push('');
}

lines.push(!hard && !soft ? '✅ 全部通过' : `小结: ${hard} 个错误, ${soft} 个警告`);
if (changed === null) lines.push('(提示: 非 git 仓库或 git 不可用,已跳过文档漂移检查)');

const report = lines.join('\n');
console.log(report);

const failed = hard > 0 || (STRICT && soft > 0);
if (HOOK && failed) {
  // 只有 exit 2 才会被 Claude/Codex 当作"阻止收尾",并把 stderr 反馈给模型
  process.stderr.write(`${report}\n\n[check-docs] 以上问题需先解决再结束本次任务(补文件头 / 修引用 / 同步模块文档)。\n`);
  process.exit(2);
}
process.exit(failed ? 1 : 0);
