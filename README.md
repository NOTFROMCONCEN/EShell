# EShell 🖥️✨

**秉承 Material You (Material Design 3) 设计的 Windows SSH / Telnet / 串口终端客户端**

基于 Flutter 构建 · 零 Chromium / WebView 依赖（Impeller/Skia 自绘渲染引擎） · Release 版仅 29MB

---

## 📖 简介

**EShell** 是面向网络运维场景的桌面终端客户端，支持 **SSH / Telnet / 串口** 三种通道，采用 Google **Material You (MD3)** 设计语言，由 Flutter 自绘引擎渲染——**完全不依赖任何浏览器内核 / WebView**。

项目初衷：为网络运维提供一个轻量、原生、可自主管理配置的终端客户端，避免为了终端交互额外引入浏览器内核。

## ✨ 功能特性（v0.1）

### 📋 会话管理
- 新建 / 编辑 / 复制 / 删除 SSH 会话（编辑基于副本，取消不污染已打开会话）
- 单层会话文件夹：新建、折叠、重命名、删除与移动会话；旧版分组标签自动转为文件夹，删除文件夹只会把会话移到未分组。支持即时搜索（名称 / 主机 / 用户名 / 文件夹）
- 文件夹名称会自动去首尾空白、大小写不敏感去重，最长 64 个字符且拒绝控制字符；历史折叠状态会自动清理重复或已删除的文件夹
- **侧边栏显示/隐藏**：标签栏按钮 / 侧栏收起按钮 / `Ctrl+Shift+B` 任一切换，状态持久化；隐藏后终端占满全宽（隐藏/显示不重建终端，滚动缓冲与焦点不丢）
- **统一程序设置页**：从侧栏或工作区打开，集中管理外观与终端、布局、日志、Telnet 扫描和 AI 助手设置；修改自动保存，窄窗口也可滚动查看
- 本地持久化（SharedPreferences），**口令经 Windows DPAPI 加密入库**（绑定当前用户，复制配置文件无法解出；旧版明文数据读取兼容、保存时自动升级；加密失败时拒绝保存）

### 🖥️ 多标签 SSH 终端
- 密码 / 私钥两种认证方式（私钥口令独立字段，不再与登录密码混用）
- `xterm-256color` PTY，窗口尺寸自适应同步
- **TOFU 主机指纹校验**（SHA256）：首次连接记录指纹；指纹变化自动阻断，并在界面提供「更新指纹并重连」确认流程（防中间人，适配服务器重装场景）
- 实时连接状态指示（连接中 / 已连接 / 失败 / 已关闭），断线一键重连
- UTF-8 多字节字符跨 TCP 分块安全（增量解码，中文/emoji 不乱码）

### 🔌 串口终端（Console）
- **Win32 API 直连串口**（kernel32 FFI，零第三方 DLL），支持 COM1-COM99；扫描用 `QueryDosDeviceW` 系统枚举在位端口 + 后台 isolate 可用性验证（不冻结 UI）。驱动响应慢时，扫描最多等待 10 秒并提示手动输入 COM 口名
- 快速连接输入 `COM3`（默认 9600）或 `COM3@115200`；会话编辑可选串口类型、扫描可用 COM 口、下拉选波特率（1200-921600，固定 8N1）
- **自动探测波特率**：勾选后连接时按 9600 → 115200 → 57600 → 19200 → 38400 → 4800 → 2400 逐个试探（写回车触发提示符 → 按「可打印占比 + 合法 UTF-8 序列 + 设备横幅特征」打分，高分早退，全程约 2-4 秒）；探测期垃圾字节不进终端，失败落到兜底波特率并提示手动指定；标签悬停显示实际探测到的波特率
- 与 SSH 同一套终端体验：多标签、状态指示、会话日志（含脱敏）、字号调节、断开重连
- 非阻塞轮询读取（10ms 周期），不卡 UI；写盘限时防硬件异常挂死
- 已知限制：编码按 UTF-8 解码（GBK 编码的老设备菜单可能乱码，后续可选编码切换）；不支持流控/奇偶校验配置；探测要求设备有回显（静默设备请手动指定波特率）

### 🌐 Telnet 终端（新增）
- 基于 `dart:io` Socket 的**自研 RFC 854 最小协议栈**：IAC 转义、选项协商（TERMINAL-TYPE / NAWS / SGA / BINARY / ECHO）、子协商应答；远端协商字节被剥离，不会污染终端显示
- 窗口尺寸同步（NAWS）、回车按 NVT 约定编码为 CR LF、UTF-8 跨分块增量解码（中文不乱码）
- 适用于 Telnet 设备控制台、终端服务器，以及 **EVE-NG 节点控制台**（`telnet://<主机>:<端口>`）
- 无认证环节：设备登录提示直接在终端内交互输入；与 SSH/串口同一套终端体验（多标签、状态指示、会话日志、字号调节、断开重连）
- 已知限制：与串口一致按 UTF-8 解码（GBK 编码的老设备菜单可能乱码，后续做编码切换）；无本地回显开关（设备不回显时输入不可见）

### 📡 快速扫描 Telnet 服务（EVE-NG 专用入口，新增）
- 专为 EVE-NG 工作流设计：EVE-NG 把每个运行中节点的控制台映射成 `telnet://<主机>:<端口>`（端口通常从 **32768** 起）
- 并发扫描目标主机的端口区间：默认本机 `127.0.0.1:32768-32800`，单次上限 4096 个端口，48 并发 + 毫秒级单端口超时，支持随时停止
- 端口分类：**Telnet 协商**（收到 IAC）/ **有回显**（提示符、横幅）/ **无回显**（EVE-NG 直通控制台常见）/ **非 Telnet**（HTTP/SSH/TLS，不建议连接）
- 探测策略：先等主动横幅，无输出时补发回车触发控制台回显；结果按端口排序，一键「连接」即以 Telnet 打开该节点终端，可选保存为会话
- 入口：侧栏雷达按钮、空状态「扫描 Telnet」按钮；上次扫描的主机与端口区间自动记忆，重复扫描 EVE-NG 无需重新输入

### 🤖 AI 助手（只读分析，2026-11-02 新增）
- 右侧 AI 面板（标签条星标 / 侧栏星标 / 空状态「AI 助手」三处入口），自动带入**当前活动会话最近 N 行终端输出**一起提问
- 流式回复（SSE）：先出结论再分点，命令以代码块呈现，**一键复制**后由你手动粘贴执行
- **Markdown 渲染**：自研零依赖解析（标题/列表/引用/代码块/行内标记），GFM 管道表格渲染为全边框表格（列对齐 `:---`/`:---:`/`---:`、`\|` 转义、流式输出逐帧成表、超宽横向滚动，2026-11-03 新增）
- **只读定位**：AI 不会执行任何命令、不会自动连接设备；涉及变更时提示风险与回滚思路
- 快捷提问：分析当前终端 / 解释报错 / 生成巡检命令；也支持自由问答（无会话时按通用网络知识回答）
- **OpenAI 兼容接口**：默认 DeepSeek（`https://api.deepseek.com/v1` + `deepseek-chat`），可改成 OpenAI / 通义 / Kimi / 本地网关等；API Key 经 Windows DPAPI 加密后本机保存，加密失败时拒绝保存
- 设置项：Base URL / 模型 / API Key / 上下文行数（30–500，默认 150），带「测试连接」
- 隐私：每次提问会把「当前会话最近 N 行输出 + 你的问题」发送到所配置的 AI 服务；未配置 Key 时不会发请求
- 已知限制：不自动执行命令、不做多设备批量巡检（列入 Roadmap）

### ⚡ 快速连接
- `user@host[:port]` 智能解析（支持 `[IPv6]:port`），可临时连接或保存
- 也支持 `telnet://host[:port]`（可直接粘贴 EVE-NG 网页里的控制台链接）与串口 `COM3[@波特率]`

### 📝 会话日志
- 标签栏一键开关，SSH 输出原始字节流原样落盘（保真，含转义序列）
- 系统原生「另存为」对话框指定存放位置与文件名（预填 `EShell_时间戳_会话名.log`）
- 上次保存目录记忆；连接断开自动停止并落盘；已有文件追加写入
- 退出应用前自动等待日志 flush/close，不再丢失尾部
- 可选「脱敏密码提示」：`password:` / `密码:` 等回显在日志中记为掩码（程序设置页开关，逐包正则尽力匹配；终端显示不受影响）

> ⚠️ **敏感信息风险**：会话日志默认**完整记录终端全部输出**。若在终端中粘贴密码、
> 执行 `sshpass -p` 等明文命令，或服务器回显敏感信息，都会被写入日志文件。
> 脱敏开关仅尽力遮蔽常见 `password:` 形式提示，无法覆盖所有场景。
> 请将日志视为敏感文件妥善保管，必要时开启脱敏或避免记录敏感会话。

### 🎨 Material You 主题
- 8 种预设种子色，动态生成完整 MD3 配色（主色 / 容器色 / 表面色体系）
- 浅色 / 深色 / 跟随系统
- 终端光标、选区、搜索高亮色由当前 ColorScheme 联动派生

### 🧱 直角界面与模块分割（2026-11-02 新增）
- **全局禁用圆角**：按钮、对话框、卡片、输入框、搜索栏、标签页、弹层等一律直角（组件主题统一 `BorderRadius.zero`，代码内零散圆角同步改直）
- **1px 细线分割各模块**：侧栏（头部 / 搜索 / 操作区 / 列表 / 底栏）、标签条与终端区、对话框分区之间均以 `outlineVariant` 细线分隔；Card / Dialog / 弹层改为 0 阴影 + 1px 描边
- **整体界面缩放**：外观设置新增 75% / 80% / 90% / 100% 四档，默认 **90%**（比系统缩放小一号）；文字、图标、间距、控件尺寸等比缩放，逻辑视口变大、窗口尺寸不变；终端字号仍可单独调节

### 🪟 自定义主窗口顶栏（2026-11-03 新增）
- 主窗口隐藏 Windows 系统标题栏和默认窗口按钮，由 Flutter 自绘品牌区、拖动区、最小化、最大化/还原与关闭按钮
- 保留 Windows 原生窗口边框与调整大小能力；AI 助手、会话栏等独立子窗口继续使用原生标题栏，避免影响多窗口操作

### 🔍 DPI 与显示适配
- **PerMonitorV2 高分屏原生渲染**：清单已声明按物理分辨率绘制，200% 缩放屏上文字锐利不发虚
- **窗口自适应**：初始尺寸按主显示器工作区 78% × 82% 自动计算（逻辑像素）并居中，小屏不被撑满、大屏不显局促
- **终端字号调节**：`Ctrl + =` / `Ctrl + -` 步进（每步 1px）、`Ctrl + 0` 重置；标签栏右侧也有 Aa 按钮（10–28px）
- **界面文字缩放**：外观设置中可选 标准 / 110% / 125% / 150%（MediaQuery textScaler 全局生效）
- **整体界面缩放**：外观设置中可选 75% / 80% / 90% / 100%（整屏等比缩放，默认 90%）
- **全部设置持久化**：主题模式、种子色、终端字号、文字缩放、整体缩放（SharedPreferences，改动即存）

## 🛠️ 技术栈

| 组件 | 技术 |
|---|---|
| 框架 | Flutter 3.47.8 stable |
| SSH | `dartssh2` 2.22.5 |
| Telnet | `dart:io` Socket + 自研 RFC 854/855/858/1073/1091 编解码（无第三方依赖） |
| AI 助手 | `dart:io` HttpClient + 自研 SSE 流式解析（OpenAI 兼容，无第三方 SDK） |
| 终端 | `xterm` 4.0.0 |
| 动态色 | `dynamic_color` 1.9.0 |
| 状态管理 | `provider` |
| 窗口控制 | `window_manager` |
| 文件对话框 | `file_selector` 1.1.0 |

## 📦 环境与构建

**前置条件**：Flutter SDK ≥ 3.47 并已加入 PATH · Visual Studio 2022（含 C++ 桌面开发工作负载）

```bash
flutter pub get              # 拉取依赖
flutter test                 # 单元测试（解析 / UTF-8 解码 / 模型 / DPAPI / Telnet / AI SSE / 端口扫描 / 串口 FFI / known_hosts）
flutter run -d windows       # 开发运行（热重载）
flutter build windows --release   # 发布构建 → build\windows\x64\runner\Release\eshell.exe
```

国内镜像（如需）：`PUB_HOSTED_URL=https://pub.flutter-io.cn` · `FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn`

> ⚠️ **务必将项目放在纯 ASCII（英文）路径下**，原因见下方踩坑记录 2。

## 📁 代码结构

```
lib/
├─ main.dart                       # 入口：窗口初始化、MD3 主题装配、Provider、关窗落盘钩子
├─ theme/app_theme.dart            # 主题解析 + 终端 ANSI 配色从 ColorScheme 派生
├─ models/session.dart             # 会话模型（SSH/Telnet/串口，不可变 + copyWith，JSON 序列化）
├─ services/
│  ├─ session_store.dart           # 会话持久化 + known_hosts（%USERPROFILE%\.eshell\known_hosts）
│  ├─ secret_store.dart            # DPAPI（CryptProtectData FFI）口令加密
│  ├─ terminal_connection.dart     # 终端连接基类（状态机/日志/增量解码，SSH/Telnet/串口共用）
│  ├─ ssh_service.dart             # dartssh2 SSH 连接生命周期
│  ├─ telnet_protocol.dart         # Telnet 协议编解码（IAC/选项协商/NAWS/TTYPE，纯逻辑可单测）
│  ├─ telnet_connection.dart       # Telnet 连接（Socket + 协议编解码 + 终端接线）
│  ├─ telnet_scanner.dart          # 端口并发扫描 + 探测分类（Telnet/控制台/静默/非 Telnet）
│  ├─ ai_client.dart               # OpenAI 兼容流式客户端（SSE 解析 / 错误映射 / 可取消）
│  ├─ ai_context.dart              # 终端上下文组装（最近 N 行 / 会话信息 / 截断）
│  ├─ ai_prompt.dart               # AI system 提示词 + 请求消息拼装 + 快捷提问预设
│  ├─ serial_port.dart             # Win32 串口 FFI（CreateFile/DCB/超时/读写/扫描）
│  ├─ baud_detector.dart           # 自动波特率探测（可打印占比+UTF-8序列+横幅打分）
│  └─ serial_connection.dart       # 串口连接（10ms 轮询读取 + 自动波特率）
├─ state/app_state.dart            # 全局状态：会话 / 标签页 / 主题设置 / AI 设置（写盘防抖）
├─ state/ai_state.dart             # AI 设置（DPAPI Key）+ 面板对话状态机
├─ utils/                          # 纯逻辑工具（可单测）：连接目标解析 / 增量解码 / 格式化 / AI Markdown
└─ ui/
   ├─ home/shell_home.dart         # 主布局（左栏 + 工作区）
   ├─ home/session_rail.dart       # 会话管理侧栏（搜索 / 分组列表 / 统计）
   ├─ home/terminal_workspace.dart # 标签条 + 终端面板 + 空状态引导 + AI 侧栏
   ├─ home/appearance_dialog.dart  # 兼容快捷入口：精简外观设置弹窗
   ├─ settings/settings_page.dart  # 统一程序设置页（外观 / 布局 / 日志 / Telnet / AI）
   ├─ window/custom_title_bar.dart # 主窗口自定义顶栏与窗口控制
   ├─ ai/                          # AI 助手面板 / AI 设置对话框 / 面板开关
   └─ session/                     # 新建/编辑会话（SSH/Telnet/串口）、快速连接、Telnet 扫描对话框
test/                              # flutter test：解析 / 解码器 / 模型 / DPAPI / Telnet / AI（SSE/上下文/状态/面板）等单测
```

---

## ⚠️ 踩坑记录（核心知识沉淀）

### 🕳️ 1. dartssh2 2.22.5 API 变更

**现象**：按旧版文档（≤2.3）写的代码编译报错。

**根因与对照**：

| 旧 API | 2.22.5 实际 API |
|---|---|
| `onHostKeyVerification` | `onVerifyHostKey: (String type, Uint8List fingerprint)`，其中 fingerprint 是 `"SHA256:<base64>"` 的 **ASCII 字节**，直接 `utf8.decode` 即可 |
| `SSHPtyConfig(columns:, rows:)` | `SSHPtyConfig(width:, height:)`（width=列数） |
| `SSHKeyPair.fromPem()` 返回单个对象 | 返回 `List<SSHKeyPair>` |
| — | 终端尺寸同步用 `session.resizeTerminal(width, height)` |

**解法**：不要信旧博客，直接读 pub 缓存里的包源码取签名：`%LOCALAPPDATA%\Pub\Cache\hosted\...\dartssh2-<ver>\lib\src\ssh_client.dart`。

### 🕳️ 2. 中文路径 + MSBuild 编码冲突导致 release 构建失败 🔥

**现象**：`flutter build windows --release` 报
`CUSTOMBUILD : error : Unable to read file: <项目路径>\.dart_tool\flutter_build\<hash>\app.dill`（路径显示为乱码）；**debug 构建一切正常**。

**根因**：Flutter 工具链将 UTF-8 编码的项目路径传递给运行在 GBK 代码页下的 MSBuild 自定义构建步骤，`app.dill` 读取环节路径被二次编码损坏。

**无效尝试（勿重复）**：❌ junction 到英文路径（Flutter 会规范化回真实中文路径）· ❌ 镜像复制到英文路径构建（同理）· ❌ `chcp 65001`（不影响 MSBuild 子进程）· ❌ `--no-tree-shake-icons`（与本问题无关）

**解法**：✅ **将项目放在纯 ASCII 路径下**，迁移后执行 `flutter clean && flutter pub get`。备选方案：开启 Windows「Beta: 使用 Unicode UTF-8 提供全球语言支持」（需重启、影响旧版 GBK 程序，慎用）。

### 🕳️ 3. PowerShell 截图保存报「GDI+ 中发生一般性错误」

**现象**：`$bmp.Save()` 向中文路径保存 PNG 失败。

**根因**：UTF-8 无 BOM 的 `.ps1` 内含中文输出路径时，Windows PowerShell 5.1 按错误编码解析，目标目录变成乱码不存在。

**解法**：先保存到 `$env:TEMP`（纯 ASCII）再复制到目标位置。

### 🕳️ 4. Git Bash 向 cmd 传反斜杠路径被转义破坏

**现象**：`cmd //c 'mklink /J C:\link "F:\path"'` 创建的 junction 目标变成 `\F:\path`（多出前导反斜杠）。

**根因**：Git Bash 对经 `cmd //c` 传递的反斜杠参数的转义规则。

**解法**：改用 PowerShell：`New-Item -ItemType Junction -Path ... -Target ...`。

### 🕳️ 5. UI 自动化截图：SetForegroundWindow 前台锁与 CopyFromScreen 盲区

**现象**：PowerShell 自动化验证应用 UI 时，截图截到的全是别的全屏应用（视频播放器），或一片黑。

**根因**：① Windows 前台锁——`SetForegroundWindow` / `SwitchToThisWindow` 对后台进程常被系统拒绝（全屏应用不交出前台）；② `CopyFromScreen` 截的是屏幕该区域「当前最上层」的内容，被遮挡时截到的是别人的窗口。

**解法**：用 **`PrintWindow(hwnd, hdc, PW_RENDERFULLCONTENT=2)`**——直接向窗口自身发送绘制消息，无论是否被遮挡、无论前台是谁都能截到窗口真实内容（Flutter GPU 渲染窗口必须带 flag=2）。需要真实点击时，先用 `SetWindowPos(HWND_TOPMOST)` 置顶再点，真实点击会自然授予焦点。另注：P/Invoke 里给 `SetWindowPos` 的 `after` 参数传 `HWND_TOPMOST(-1)` 时，签名直接声明为 `int` 即可（封送层自动符号扩展），不要在 PS 里纠结 `IntPtr` 构造。验证多窗口数量用 `EnumWindows` 按进程 id 过滤（desktop_multi_window 子窗口与主窗口同进程）。

### 🕳️ 6. xterm 4.0.0 在 Windows 上只能回车、无法输入字符 🔥

**现象**：SSH 终端里 Enter / 方向键 / Ctrl 组合键都正常，但字母、数字等普通字符完全打不进去。

**根因**：xterm 4.0.0 的普通字符不走硬件按键事件，而是走 `TextInput.attach` 的 IME 文本输入通道（`custom_text_edit.dart`）。该通道在 Windows 桌面（尤其中文 IME 环境）收不到文本回传，控制键因另有 `keyToTerminalKey` 硬件路径而不受影响——于是表现为「只能回车」。

**解法**：给 `TerminalView` 传 `hardwareKeyboardOnly: true`，全部输入改走硬件按键事件（`keyEvent.character` → `terminal.textInput`）。代价是终端内无法用 IME 组合输入中文（原本也是坏的，等于净收益）。

### 🕳️ 7. 增量构建不刷新图标字体子集 → 新增 Icons 在 Release 里显示空白 🔥

**现象**：代码里新增的图标（本次为 `Icons.radar_rounded`、`Icons.settings_ethernet`）在 `flutter run` / `flutter test` 里正常，但 `flutter build windows --release` 产物中图标位置一片空白，而构建仍报成功。

**根因**：增量构建复用了旧的 `build\windows\x64\runner\Release\data\flutter_assets\fonts\MaterialIcons-Regular.otf`（图标字体子集，tree-shaking 产物），没有随新源码重新生成——旧子集里没有新图标的字形，运行时按 codepoint 找不到字形即绘制为空。可用 fontTools 验证：旧子集 44 个字形、缺 `0xf00d6`（radar_rounded）/`0xe586`（settings_ethernet）。

**解法**：`flutter clean && flutter pub get && flutter build windows --release`（重建后子集 52 个字形，缺失 codepoint 全部就位）。凡是**新增 `Icons.*` 后发布构建**，都应 clean 重建，或用 fontTools 校验字体子集包含新 codepoint。

### 🕳️ 8. 退出延迟：window_manager.destroy() 不销毁窗口 🔥

**现象**：点窗口关闭按钮后界面仍可能短暂停留，进程退出明显延迟；日志/设置其实早已写盘。

**根因**：`window_manager` 0.4.3 的 `destroy()` 在 Windows 上只执行 `PostQuitMessage(0)`，**不调用 `DestroyWindow`**；而 `setPreventClose(true)` 又让 WM_CLOSE 返回 -1，窗口自始至终没被销毁。窗口仍存活时 Flutter 引擎退场（释放 view/engine）实测卡约 12 秒。

**对照实验**：去掉 `setPreventClose(true)` 或改用 `close()` 后退出恢复正常，说明问题来自窗口销毁路径而不是日志写盘。

**解法**：关窗钩子先 `await windowManager.setPreventClose(false)`，再 `await windowManager.close()`（WM_CLOSE → DefWindowProc → DestroyWindow → WM_DESTROY 正常路径，窗口销毁后进程立即退出）。顺带把多标签日志 flush 改为并行（各自 3s 限时），总等待不再随标签数线性增长。

### 🕳️ 9. 独立 ChangeNotifier 不被 `watch<AppState>()` 监听 → 侧栏按钮「没反应」 🔥

**现象**：点左上角「显示侧边栏」或标签条上的侧栏开关，设置值确实写入了（重启后生效），但当前界面毫无变化。

**根因**：`showSidebar` 存在 `ThemeSettings`（独立的 ChangeNotifier）里，而 `ShellHome` 只 `context.watch<AppState>()`；`settings.notifyListeners()` 不会通知 `AppState` 的监听者。旧实现指望 main 里的 `AnimatedBuilder(animation: settings)` 重建 MaterialApp 来带动布局——但 `home: const ShellHome()` 是 const，Element 遇到相同实例直接跳过重建，侧栏布局不更新。空状态页的「恢复侧栏」按钮与标签条开关也读 settings，一起失效。

**解法**：在 `AppState.load()` 里把 settings 通知桥接给 AppState：`settings.addListener(notifyListeners)`，所有 `watch<AppState>()` 的界面都会随设置同步重建。回归测试 `test/shell_home_test.dart` 覆盖（移除桥接即失败）。

**次要教训**：设置项驱动的布局，不要依赖父级 rebuild 顺带更新子树；要么桥接通知（本项目采用），要么在读取处显式 `ListenableBuilder` / `AnimatedBuilder`。

### 🕳️ 10. 子窗口周期备份回执重置弹出状态 → AI 窗口重复创建 🔥（2026-11-03）

**现象**：AI 助手弹出为独立窗口约 3 秒后，主窗口的停靠面板重新出现（与子窗口显示同一份对话，视觉重复）；此时再点 AI 开关会**再创建一个子窗口**——屏幕上出现多个 AI 助手窗口。

**根因**：主窗口把「收到 `aiBackupSnapshot`（子窗口每 3 秒的周期备份）」和「子窗口已关闭」共用同一个处理函数，函数尾部写了 `aiPoppedOut = false`。于是弹出 3 秒后被周期备份"意外重置"为主窗口以为子窗口已关闭：① 占位卡消失、停靠面板回归（备份还在持续镜像对话，面板内容活着的）；② 弹出守卫失效，再点弹出就 `WindowController.create` 第二个窗口。

**解法**：把「数据镜像」与「生命周期状态」拆开——
- `aiBackupSnapshot`（周期备份）只镜像数据到 `AppState.aiChat`，**绝不碰 `aiPoppedOut`**；
- 新增显式关闭回执 `aiWindowClosed`（子窗口 `closeSelf` 时随最终快照一并发送），主窗口收到才恢复停靠状态；
- `popOutAi` 在已弹出时改为发 `aiFocusWindow` 把已有子窗口调到前台（防重复创建的第三道保险），`WindowController.create` 包 try/catch（失败不让占位卡卡死）；
- 对照：会话栏子窗口天生没这个问题——它的子→主消息只有显式动作与 `railWindowClosed`，没有周期性回执。

**通用教训**：多窗口状态机里，**周期性数据同步消息绝不能携带生命周期语义**；状态翻转只由显式的开始/结束事件驱动。验证手段：`EnumWindows` 按进程 id 数顶层窗口标题，弹出 → 等 5 秒跨备份周期 → 再点弹出，窗口数应恒为 2。

---

## 🗺️ Roadmap

- [ ] 终端复制 / 粘贴快捷键（Ctrl+Shift+C/V）与右键菜单
- [x] 口令加密存储（已用 Windows DPAPI 实现绑定用户的加密；凭据管理器作为备选路线）
- [x] 串口 / Console 终端（COM1-99，Win32 FFI 直连，8N1 + 可选波特率）
- [x] 串口自动探测波特率（软件试探法：候选轮询 + 可打印/UTF-8/横幅打分）
- [x] Telnet 终端（自研 RFC 854 协议栈：IAC 协商 / NAWS / TTYPE / 二进制模式）
- [x] 快速扫描机内 Telnet 服务（EVE-NG 节点控制台一键发现与连接）
- [x] **AI 助手（只读分析）**：OpenAI 兼容流式对话、终端上下文注入、代码块一键复制、Key 加密存储
- [ ] AI 阶段二：命令执行需用户确认（危险命令白名单/拦截）、多设备批量巡检 Agent
- [ ] AI 阶段三：本地 Ollama / 离线模型支持、会话历史持久化
- [ ] 本地 PowerShell 通道（对齐 XShell）
- [ ] Telnet 增强：本地回显开关、GBK/编码切换、自动重连
- [ ] 串口增强：GBK 编码支持、数据位/校验位/停止位/流控配置、枚举系统设备名
- [ ] SFTP 文件浏览与传输
- [ ] 端口转发 / 隧道、X11 / Agent 转发
- [ ] 跳板机级联、密钥生成管理 UI
- [ ] 英文界面（i18n）

## 📄 许可证

MIT License
