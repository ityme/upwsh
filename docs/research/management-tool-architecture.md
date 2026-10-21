# upwsh 管理工具架构调研

**调研日期：** 2026-10-21

**范围：** 管理器与 runtime 解耦、安装/更新/卸载、local/remote/source/ref、当前会话激活、外部 CLI 工具、状态与诊断。

## 结论

`upwsh` 应保留为用户看到的统一入口，但内部要明确拆成四层：

1. **Manager / control plane**：解析命令、选择来源、生成计划、执行事务、写状态和日志。
2. **Runtime**：提示符、路径转换、命令适配、补全、主题和终端 hook。
3. **Shell activation**：profile hook、当前会话加载、PATH 持久化和卸载。
4. **Tool backend**：外部 CLI 的 manifest、下载、校验、安装、更新和 ownership。

最重要的边界是：

- 部署 runtime 不等于加载当前 shell。
- 更新 manager 不等于更新 runtime。
- 更新 runtime 不等于更新外部工具。
- 安装来源只影响 artifact resolution，不改变命令语义。
- 用户配置、状态、缓存、工具和 runtime 应有明确的保留/删除策略。

不要一开始重写全部脚本。当前 `_deploy.ps1` 已有 stage、backup、journal、rollback 和锁文件处理，应先抽成公共 operation 层，再逐步替换旧入口。

## 现状问题

当前管理行为分散在：

- `src/script/upwsh.ps1`：统一命令入口和参数转发
- `install.ps1` / `update.ps1` / `uninstall.ps1`：runtime 生命周期
- `_deploy.ps1`：runtime 校验、部署、备份和回滚
- `_relaunch.ps1`：从安装目录调用时的临时重启
- `install_profile.ps1`：profile hook
- `install_cli_tool.ps1`：外部 CLI 工具
- `src/lib/upwsh_home.ps1`：安装目录、PATH、环境变量和 shim

主要问题：

- `install` 同时部署 runtime、修改 profile、加载当前会话，职责不正交。
- local/remote/source/ref/repo 在多个脚本内分别解释，没有统一的 resolved source 对象。
- runtime 以文件树判断状态，tool 主要以 exe 是否存在判断状态，缺少统一的来源、版本、hash、ownership 和最后操作记录。
- runtime 文件部署已有回滚，但 PATH、profile、工具替换和主题变更没有一个统一的 operation 记录。
- `--check` 和文本 status 可用，但缺少稳定 JSON 状态、operation id、日志路径和 doctor 诊断。
- 远程 runtime 和外部工具的完整性、来源信任、代理和校验策略没有统一出口。

## 成熟工具的共同模式

### 声明状态与实际状态分离

mise 将配置请求、已安装工具、`outdated`、`doctor` 分开；npm 使用 package spec、package.json 和 lockfile 分离声明与解析结果；WinGet 用 `list` 观察状态、`upgrade` 执行变化，并提供 export/import/configure。

对 upwsh 的启发：

- `state/installation.json` 记录实际安装结果。
- 未来可选的 `upwsh.json` 或 `upwsh.toml` 记录期望的工具集合。
- 直接安装的外部工具要标记 `managed` / `origin`，不要自动接管 Scoop、WinGet 或其他包管理器安装的工具。

### 来源和 artifact 身份是一等数据

Scoop manifest 明确记录 version、url、hash、bin、depends 和架构；WinGet 支持 ID、version、source、scope、architecture、manifest、hash 和日志；npm 的 package spec 能表达 registry、精确版本、范围、文件、tarball、Git URL 和 ref；rustup 将 channel、date、host 和 proxy 分开。

建议内部统一为：

```text
ArtifactSpec {
  kind: runtime | tool
  name: upwsh | eza | ...
  source: local(path) | git(url) | archive(url) | registry(name)
  ref: optional branch/tag/commit
  version: optional exact/range/channel
  integrity: optional sha256/signature
  platform: windows-x64 | windows-arm64 | ...
  scope: user | machine | project
}
```

解析后生成不可变 `ResolvedArtifact`。安装层只接收解析结果，不再自行猜 URL、版本或来源。

### 安装、激活、卸载是不同动作

mise 把 `activate`、工具 `upgrade`、manager `self-update`、`implode` 分开；Starship 把二进制安装与 shell init 分开；uv 区分临时 `tool run` 和持久 `tool install`；rustup 通过 proxy 把用户命令与具体 toolchain 解耦。

因此 upwsh 应明确区分：

- `runtime install/update/remove`
- `shell enable/disable/reload/status`
- `tool install/update/remove/run`
- `self update`
- `doctor`

兼容期可以保留 `upwsh install/update/uninstall/load/unload`，但内部转发到对应层。

## 推荐命令模型

第一阶段不必马上公开全部新命令。建议内部先按下面的资源模型设计：

```text
upwsh
  install [source options]              # 兼容入口：runtime install + 可选激活
  update [source options]               # 兼容入口：runtime update
  uninstall [--purge]                   # 兼容入口：runtime remove
  status [--json]
  doctor [--json]
  plan install|update|uninstall [--dry-run]
  shell
    enable [--profile <path>]
    disable [--profile <path>]
    reload
    status
  runtime
    install [source options]
    update [source options]
    status [--json]
    remove [--purge]
  tool
    list [--json|--managed|--all]
    show <name>
    install <name[@version]>...
    update [name...] [--all]
    uninstall <name>...
    run <name> [-- args...]
  source
    list
    add <name> <location>
    update [name|--all]
    remove <name>
  self
    update
```

不建议首版把所有命令都暴露给用户。优先实现：

```text
upwsh install
upwsh update
upwsh status
upwsh doctor
upwsh shell enable|disable|reload|status
upwsh tool list|install|update|uninstall
```

`runtime`、`source`、`self` 可以先作为内部路由或后续兼容扩展。

## local / remote / source / ref 统一语义

建议把 `--local`、`--remote` 作为快捷策略，而不是最终状态字段：

- `--local`：当前项目工作树或显式本地 source。
- `--remote`：默认远程仓库或 registry。
- `--source <path|url>`：显式来源，优先级高于上下文默认值。
- `--repo <owner/name|url>`：远程 Git 仓库。
- `--ref <branch|tag|commit>`：远程 Git ref；commit 应记录为 resolved commit。
- `--version <value>`：仅用于有版本解析器的来源。
- `--integrity <sha256|signature>`：固定完整性。

优先级：

```text
显式 CLI > 环境变量 > 配置文件 > 命令上下文默认值
```

命令开始时必须显示规范化后的来源：

```text
source   local
path     I:\ispace\unixify-powershell\src
ref      working-tree
target   C:\Users\user\.config\upwsh
```

远程操作显示最终 URL、ref/version、resolved commit 和完整性状态。不能只显示“remote”而隐藏实际下载对象。

建议未来让 `update` 默认使用已记录的来源，而不是仅依赖当前工作目录：

- 从远程安装的 runtime，`upwsh update` 默认继续远程更新同一 channel。
- 从本地安装的 runtime，`upwsh update` 默认使用记录的本地路径；路径不存在时给出明确提示并建议 `--remote`。
- `--local`、`--remote` 用于显式覆盖默认来源。

这是比“当前在哪个目录就决定更新哪里”更可预测的模型。兼容迁移期间可以保留当前仓库内默认 local 的行为，并输出实际采用的 source。

## 一次操作的标准流水线

所有 install/update/remove/tool 操作都应进入同一个 operation orchestrator：

```text
parse
  -> resolve source
  -> plan
  -> acquire to temp/cache
  -> validate manifest/runtime/hash
  -> stage
  -> commit files/state/profile/PATH
  -> verify
  -> summarize
```

建议输出阶段，让用户知道当前发生了什么：

```text
[1/7] resolve source   local: I:\ispace\unixify-powershell\src
[2/7] validate         runtime schema ok
[3/7] stage            42 files
[4/7] commit           runtime deployed
[5/7] shell            profile hook unchanged
[6/7] verify           upwsh command available
[7/7] complete         operation succeeded
```

默认输出摘要，`--verbose` 显示 backend 细节，`--json` 输出稳定对象。错误必须包含：阶段、资源、原因、建议动作、operation id 和日志路径。

## 状态与诊断

建议建立：

```text
~/.config/upwsh/
  state/installation.json
  state/operations/<operation-id>.jsonl
  cache/
  runtime/
  tool/bin/
  user-settings.ps1
  profile.ps1
```

首版 `installation.json` 可只记录：

- manager/runtime 版本
- resolved source、ref、commit/version
- artifact hash
- runtime 路径
- tool ownership 和来源
- profile hook 路径
- 当前/最后 operation id
- 最后成功或失败阶段

`upwsh status` 面向人看，`upwsh status --json` 面向测试和脚本。未知状态要输出 `unknown`，不能把“无法确认”误报成 `missing`。

`upwsh doctor` 应检查：

- PowerShell 版本
- UPWSH_HOME
- 当前 PATH 与持久 PATH
- profile marker 是否成对
- runtime 必需文件
- tool shim 是否可执行
- state 与磁盘是否一致
- operation lock 是否残留
- 代理和网络连通性
- source trust 和 integrity 是否满足策略

## 事务与恢复

现有 `_deploy.ps1` 的 stage/backup/journal/rollback 应保留并抽象成公共 backend。建议每个 operation：

1. 获得用户级锁并生成 operation id。
2. 解析和校验，不修改 live 状态。
3. 下载到临时目录，限制大小。
4. 校验 manifest、hash、签名和 runtime schema。
5. stage 文件、shim 和生成配置。
6. commit 文件、状态、PATH/profile 变更。
7. post-commit 验证命令、版本和 hook。
8. 成功后清理临时文件；失败按 journal 回滚。
9. rollback 失败时写入 `needs-repair`，不能报告成功。

Windows 运行中的目录句柄意味着不能依赖整个目录 rename；应继续使用文件级替换和明确的锁失败提示。

## 迁移路线

### 阶段 0：先统一契约和观测

不改变用户行为：

- 抽取 `ArtifactSpec`、`ResolvedArtifact`、`OperationResult`。
- 统一错误码、operation id 和 source 规范化输出。
- 给 install/update/tool 增加 `--dry-run` 和 JSON 状态。
- 记录 state，但暂时不依赖 state 做决策。

### 阶段 1：增加 manager orchestrator

- 新增 manager 内部模块。
- 将现有 install/update/uninstall/tool 脚本包装为 backend。
- 顶层兼容命令保持不变。
- 把 runtime 已有 journal 纳入 operation 日志。

### 阶段 2：分离 runtime 与 activation

- runtime install 默认只部署。
- `shell enable/disable/reload/status` 单独管理 profile、PATH 和当前会话。
- 兼容入口可保留 `install` 后自动 load，但必须打印“deploy succeeded / shell loaded”两个独立结果。
- update 不自动重载当前会话，保持现有预期。

### 阶段 3：统一 manifest 和来源

- runtime 使用固定来源和可选 pinned ref/hash。
- tool 使用 manifest：URL、架构、bin、hash、依赖、更新规则。
- 增加 source list/update/trust。
- 不接管通过 Scoop/WinGet/npm 安装的外部工具，除非用户明确 adopt。

### 阶段 4：声明式工具集合

- `upwsh.json` / `upwsh.toml` 描述期望工具集合。
- `tool sync`、export/import、lockfile。
- 完善 doctor、日志保留、并发恢复和 `needs-repair` 修复命令。

## 取舍

### 自建 manifest 还是调用系统包管理器

核心 runtime 建议自有 manifest，因为它需要固定目录、profile/PATH 策略和可回滚部署。Scoop、WinGet、npm 可以作为可选 tool backend，不要把它们的外部状态伪装成 upwsh 自己管理。

### 是否立即移动目录

不建议第一阶段就搬动已安装目录。先拆代码边界和契约；保留 `~/.config/upwsh`，避免破坏用户 profile、PATH 和现有工具。等 state、activation 和兼容入口稳定后，再考虑 `manager/`、`runtime/`、`state/`、`cache/` 的物理分层。

### 是否自动更新

不建议默认自动更新 runtime 或接管外部工具。更新必须显式、可预览、可记录；未来可以提供配置化的自动检查，但不应静默修改当前 shell。

## 一手来源

- GitHub README 规范：<https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-readmes>
- mise 安装、self-update、upgrade、implode：<https://mise.jdx.dev/installing-mise.html>
- mise activation 与 PowerShell：<https://mise.jdx.dev/cli/activate.html>
- mise doctor / troubleshooting：<https://mise.jdx.dev/troubleshooting.html>
- Scoop manifest：<https://github.com/ScoopInstaller/Scoop/wiki/App-Manifests>
- Scoop bucket：<https://github.com/ScoopInstaller/Scoop/wiki/Buckets>
- Microsoft WinGet 总览：<https://learn.microsoft.com/en-us/windows/package-manager/winget/>
- Microsoft WinGet install：<https://learn.microsoft.com/en-us/windows/package-manager/winget/install>
- Microsoft WinGet source：<https://learn.microsoft.com/en-us/windows/package-manager/winget/source>
- rustup 基本用法与更新：<https://rust-lang.github.io/rustup/basics.html>
- rustup concepts：<https://rust-lang.github.io/rustup/concepts/toolchains.html>
- Starship 安装：<https://starship.rs/guide/>
- Starship 卸载：<https://starship.rs/faq/>
- uv 安装：<https://docs.astral.sh/uv/getting-started/installation/>
- uv tools：<https://docs.astral.sh/uv/concepts/tools/>
- npm install/update/uninstall：<https://docs.npmjs.com/cli/v11/commands/npm-install/>

## 结论与下一步

建议实施顺序不是先大搬文件，而是先建立可验证的管理契约：

1. `status` / `doctor` / `plan --dry-run`。
2. source resolver 和 `ArtifactSpec`。
3. operation id、阶段输出、日志和统一错误码。
4. runtime 与 shell activation 分离。
5. tool manifest、ownership 和 source trust。
6. 最后再物理拆分 manager/runtime 目录。

这条路径能先降低风险，同时保留当前用户命令和安装目录兼容性。
