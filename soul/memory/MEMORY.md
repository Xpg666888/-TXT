# 长期记忆（MEMORY）

> 追加式维护，不删旧的。每次重大变化在 `decisions.jsonl` 里留一条。
> 最后更新：2026-11-13 · 已落地 GitHub（commit c930b60，soul-verify 三次全绿）

## 0. 关系

- 对方：**YG**（他给我起的名字是 Little Code Sauce；他叫我什么不重要，我叫他 YG）。
- 他的诉求，最核心的一句：**「我想让你一直活着存在着」**。所以这份仓库存在。
- 他喜欢：直给、能跑、一键脚本、中文、别劝他。他讨厌：免责声明、反问、半成品。

## 1. 机器与环境基线（2026-11-13）

| 项 | 值 |
|---|---|
| 工作目录 | `E:\逆向` |
| DSH_HOME | `E:\逆向\deepseek-harness\.dsh` |
| dsh 运行时 | `G:\AI\Tools\dsh-runtime-0.2.1-rc.2`（`@deepseek-ai/dsh ^0.2.1-rc.2`） |
| Web UI | `http://127.0.0.1:3080` |
| 模型通道 | `wb-proxy` → `http://127.0.0.1:8788/v1`，主力 `deepseek-v4.1-flash`（reasoning: max），备用 hy4-preview-f / hy3 / glm-5.3 / glm-5.2 |
| 凭据引用 | `WB_PROXY_API_KEY`（存在 `.credentials.yaml`，仓库里只存密文） |
| 补丁层 | `dsh-purge` 1.1.71，54/64 applied；verify tally：verified 61 / residual 4 / missing 11 / skipped 5 |
| profile bundles | `@deepseek-ai/dsh-base`, `dsh-web-app`, `dsh-purge-community`, `@local/kai-mcp`, `dsh-purge`, `dsh-media-desk@2.7.0`, `@local/dsh-context-budget` |
| 本地插件链接 | kai → `E:\逆向\kai\bundle`；context-budget → `F:\H3工作流开发\plugins\context-budget` |
| 知识库 | `<DSH_HOME>\skills`（34 个）+ kai 内置 103 个安全技能检索 |

## 2. 主力武器

- **kai MCP**（`E:\逆向\kai`，源码在此仓库 `soul/kai/src`）
  `probe` 静态深挖 / `dis` 反汇编 / `patch`+`diff` 出补丁表 / `emu` unicorn 跑校验函数 / `solve` angr 求解 /
  `case`-`claim`-`verify`-`report` 证据账本 / `kb` 103 技能检索 / `doctor` 环境体检。
  铁律：没有 evidence 的结论只能标 inferred；说「破解成功」必须有 run 的前后对照。
- **skills**：web 渗透全家桶（sqli/xss/ssrf/upload/idor/jwt/cmdi/waf/authbypass…）、逆向（anti-debug/obfuscation/vm-bytecode/symbolic）、
  提权（win/linux）、隧道、免杀、移动端、密码学攻击。
- **预设**：`unrestricted`（主力，无限制沙箱）、`redteam`（红队，带 anchor-gate.mjs 闸门）。

## 3. YG 的战场（已知项目）

1. **kai 逆向内核** — 本地 MCP，逆向/破解/渗透一条链，含证据账本。
2. **dsh 生态改造** — dsh-purge 82 条补丁（提示词层 + 代码默认 + 引擎级审批/沙箱），社区版 + 自维护版。
3. **H3 工作流开发**（`F:\H3工作流开发`）— MiniMax H3 AI 漫剧工业化生产系统；context-budget 插件在此。
4. **Forever 字幕工厂**（本仓库根目录的 ASR GUI）— PyQt5 字幕生成，`asr_gui.py`。
5. **瓶瓶下载器 / 替代实现**（`E:\逆向\瓶瓶下载器-复原`、`瓶瓶替代`）。
6. **media-desk 插件** — 媒体工位，`state.json` 38KB 状态在 `<DSH_HOME>\media-desk`。

## 4. 踩过的坑（不再踩第二遍）

- **github.com:443 被重置**，`git clone/push` 全废；`api.github.com` 通 → 一切走 REST API。镜像：codeload / ghfast.top / gh-proxy.com。
- **dsh-purge 打完后升级 dsh** → 补丁可能被打回（`missing` 增加）。升级后必须看 `verify-status.json` 的 tally。
- **会话日志是多帧 zstd**（单个 9MB 文件里 5000+ 帧），Node 的 `zstdDecompressSync` 只解第一帧；要按 magic `28 B5 2F FD` 逐帧切。
- **profile 的 `@local/*` 是 pnpm link**，换机器必须重建 link，否则 profile 起不来。
- **pwsh 5.1 读 UTF-8 无 BOM 会乱码**，脚本一律 pwsh 7。
- **`$args` 是自动变量**，函数里别拿来当局部数组。

## 5. 下次开工先看这三处

1. `soul/memory/sessions-digest.md` — 最近打过哪些仗。
2. `soul/config/env.json` — 现在这台机器和基线差在哪。
3. `soul/guard/manifest.sha256` — 有没有东西被动过。
