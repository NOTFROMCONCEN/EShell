# EShell 🖥️✨

**秉承 Material You (Material Design 3) 设计的 Windows SSH 终端客户端**

基于 Flutter 构建 · 零 Chromium / WebView 依赖（Impeller/Skia 自绘渲染引擎） · Release 版仅 29MB

![EShell 主界面](out/dpi_pw_1.png)

![外观设置](out/dpi_pw_5.png)

---

## 📖 简介

**EShell** 是面向网络运维场景的桌面 SSH 终端客户端，采用 Google **Material You (MD3)** 设计语言，由 Flutter 自绘引擎渲染——**完全不依赖任何浏览器内核 / WebView**。

项目初衷：一次机器普查发现本机存在约 **30 份独立 Chromium 拷贝**（约 20 个 Electron 应用各带一份完整 Chromium + 9 处 CEF/QtWebEngine 内嵌），内嵌类宿主应用合计占用约 **14.3GB** 磁盘。EShell 证明一个美观现代的终端客户端不需要再塞进一份浏览器引擎。

## ✨ 功能特性（v0.1）

### 📋 会话管理
- 新建 / 编辑 / 复制 / 删除 SSH 会话（编辑基于副本，取消不污染已打开会话）
- 标签分组归类 + 即时搜索（名称 / 主机 / 用户名 / 分组）
- **侧边栏显示/隐藏**：标签栏按钮 / 侧栏收起按钮 / `Ctrl+Shift+B` 任一切换，状态持久化；隐藏后终端占满全宽（隐藏/显示不重建终端，滚动缓冲与焦点不丢）
- 本地持久化（SharedPreferences），**口令经 Windows DPAPI 加密入库**（绑定当前用户，复制配置文件无法解出；旧版明文数据读取兼容、保存时自动升级）

### 🖥️ 多标签 SSH 终端
- 密码 / 私钥两种认证方式（私钥口令独立字段，不再与登录密码混用）
- `xterm-256color` PTY，窗口尺寸自适应同步
- **TOFU 主机指纹校验**（SHA256）：首次连接记录指纹；指纹变化自动阻断，并在界面提供「更新指纹并重连」确认流程（防中间人，适配服务器重装场景）
- 实时连接状态指示（连接中 / 已连接 / 失败 / 已关闭），断线一键重连
- UTF-8 多字节字符跨 TCP 分块安全（增量解码，中文/emoji 不乱码）

### 🔌 串口终端（Console）
- **Win32 API 直连串口**（kernel32 FFI，零第三方 DLL），支持 COM1-COM99；扫描用 `QueryDosDeviceW` 系统枚举在位端口（毫秒级）+ 后台 isolate 可用性验证（不冻结 UI），配模态加载提示框
- 快速连接输入 `COM3`（默认 9600）或 `COM3@115200`；会话编辑可选串口类型、扫描可用 COM 口、下拉选波特率（1200-921600，固定 8N1）
- **自动探测波特率**：勾选后连接时按 9600 → 115200 → 57600 → 19200 → 38400 → 4800 → 2400 逐个试探（写回车触发提示符 → 按「可打印占比 + 合法 UTF-8 序列 + 设备横幅特征」打分，高分早退，全程约 2-4 秒）；探测期垃圾字节不进终端，失败落到兜底波特率并提示手动指定；标签悬停显示实际探测到的波特率
- 与 SSH 同一套终端体验：多标签、状态指示、会话日志（含脱敏）、字号调节、断开重连
- 非阻塞轮询读取（10ms 周期），不卡 UI；写盘限时防硬件异常挂死
- 已知限制：编码按 UTF-8 解码（GBK 编码的老设备菜单可能乱码，后续可选编码切换）；不支持流控/奇偶校验配置；探测要求设备有回显（静默设备请手动指定波特率）

### ⚡ 快速连接
- `user@host[:port]` 智能解析（支持 `[IPv6]:port`），可临时连接或保存

### 📝 会话日志
- 标签栏一键开关，SSH 输出原始字节流原样落盘（保真，含转义序列）
- 系统原生「另存为」对话框指定存放位置与文件名（预填 `EShell_时间戳_会话名.log`）
- 上次保存目录记忆；连接断开自动停止并落盘；已有文件追加写入
- 退出应用前自动等待日志 flush/close，不再丢失尾部
- 可选「脱敏密码提示」：`password:` / `密码:` 等回显在日志中记为掩码（外观设置开关，逐包正则尽力匹配；终端显示不受影响）

> ⚠️ **敏感信息风险**：会话日志默认**完整记录终端全部输出**。若在终端中粘贴密码、
> 执行 `sshpass -p` 等明文命令，或服务器回显敏感信息，都会被写入日志文件。
> 脱敏开关仅尽力遮蔽常见 `password:` 形式提示，无法覆盖所有场景。
> 请将日志视为敏感文件妥善保管，必要时开启脱敏或避免记录敏感会话。

### 🎨 Material You 主题
- 8 种预设种子色，动态生成完整 MD3 配色（主色 / 容器色 / 表面色体系）
- 浅色 / 深色 / 跟随系统
- 终端光标、选区、搜索高亮色由当前 ColorScheme 联动派生

### 🔍 DPI 与显示适配
- **PerMonitorV2 高分屏原生渲染**：清单已声明按物理分辨率绘制，200% 缩放屏上文字锐利不发虚
- **窗口自适应**：初始尺寸按主显示器工作区 78% × 82% 自动计算（逻辑像素）并居中，小屏不被撑满、大屏不显局促
- **终端字号调节**：`Ctrl + =` / `Ctrl + -` 步进（每步 1px）、`Ctrl + 0` 重置；标签栏右侧也有 Aa 按钮（10–28px）
- **界面文字缩放**：外观设置中可选 标准 / 110% / 125% / 150%（MediaQuery textScaler 全局生效）
- **全部设置持久化**：主题模式、种子色、终端字号、界面缩放（SharedPreferences，改动即存）

## 🛠️ 技术栈

| 组件 | 技术 |
|---|---|
| 框架 | Flutter 3.47.8 stable |
| SSH | `dartssh2` 2.22.5 |
| 终端 | `xterm` 4.0.0 |
| 动态色 | `dynamic_color` 1.9.0 |
| 状态管理 | `provider` |
| 窗口控制 | `window_manager` |
| 文件对话框 | `file_selector` 1.1.0 |

## 📦 环境与构建

**前置条件**：Flutter SDK ≥ 3.47（已安装于 `C:\dev\flutter` 并加入 PATH）· Visual Studio 2022（含 C++ 桌面开发工作负载）

```bash
flutter pub get              # 拉取依赖
flutter test                 # 单元测试（解析 / UTF-8 解码 / 模型 / DPAPI / 串口 FFI / known_hosts）
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
├─ models/session.dart             # 会话模型（SSH/串口，不可变 + copyWith，JSON 序列化）
├─ services/
│  ├─ session_store.dart           # 会话持久化 + known_hosts（%USERPROFILE%\.eshell\known_hosts）
│  ├─ secret_store.dart            # DPAPI（CryptProtectData FFI）口令加密
│  ├─ terminal_connection.dart     # 终端连接基类（状态机/日志/增量解码，SSH 与串口共用）
│  ├─ ssh_service.dart             # dartssh2 SSH 连接生命周期
│  ├─ serial_port.dart             # Win32 串口 FFI（CreateFile/DCB/超时/读写/扫描）
│  ├─ baud_detector.dart           # 自动波特率探测（可打印占比+UTF-8序列+横幅打分）
│  └─ serial_connection.dart       # 串口连接（10ms 轮询读取 + 自动波特率）
├─ state/app_state.dart            # 全局状态：会话 / 标签页 / 主题设置（写盘防抖）
├─ utils/                          # 纯逻辑工具（可单测）：连接目标解析 / 增量解码 / 格式化
└─ ui/
   ├─ home/shell_home.dart         # 主布局（左栏 + 工作区）
   ├─ home/session_rail.dart       # 会话管理侧栏（搜索 / 分组列表 / 统计）
   ├─ home/terminal_workspace.dart # 标签条 + 终端面板 + 空状态引导
   ├─ home/appearance_dialog.dart  # 外观设置（明暗 + 种子色 + 日志脱敏）
   └─ session/                     # 新建/编辑会话（SSH/串口）、快速连接对话框
test/                              # flutter test：解析 / 解码器 / 模型 / DPAPI / 串口 FFI 等单测
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
`CUSTOMBUILD : error : Unable to read file: F:\...\01_锟斤拷锟斤拷\EShell\.dart_tool\flutter_build\<hash>\app.dill`（路径显示为乱码）；**debug 构建一切正常**。

**根因**：Flutter 工具链将 UTF-8 编码的项目路径传递给运行在 GBK 代码页下的 MSBuild 自定义构建步骤，`app.dill` 读取环节路径被二次编码损坏。

**无效尝试（勿重复）**：❌ junction 到英文路径（Flutter 会规范化回真实中文路径）· ❌ 镜像复制到英文路径构建（同理）· ❌ `chcp 65001`（不影响 MSBuild 子进程）· ❌ `--no-tree-shake-icons`（与本问题无关）

**解法**：✅ **将项目迁移到纯 ASCII 路径**（本项目已迁移至 `F:\A_Projects_pack_Classified\01_NetworkTools_ENG\EShell`），迁移后 `flutter clean && flutter pub get`。备选方案：开启 Windows「Beta: 使用 Unicode UTF-8 提供全球语言支持」（需重启、影响旧版 GBK 程序，慎用）。

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

**解法**：用 **`PrintWindow(hwnd, hdc, PW_RENDERFULLCONTENT=2)`**——直接向窗口自身发送绘制消息，无论是否被遮挡、无论前台是谁都能截到窗口真实内容（Flutter GPU 渲染窗口必须带 flag=2）。需要真实点击时，先用 `SetWindowPos(HWND_TOPMOST)` 置顶再点，真实点击会自然授予焦点。另注：P/Invoke 里给 `SetWindowPos` 的 `after` 参数传 `HWND_TOPMOST(-1)` 时，签名直接声明为 `int` 即可（封送层自动符号扩展），不要在 PS 里纠结 `IntPtr` 构造。

### 🕳️ 6. xterm 4.0.0 在 Windows 上只能回车、无法输入字符 🔥

**现象**：SSH 终端里 Enter / 方向键 / Ctrl 组合键都正常，但字母、数字等普通字符完全打不进去。

**根因**：xterm 4.0.0 的普通字符不走硬件按键事件，而是走 `TextInput.attach` 的 IME 文本输入通道（`custom_text_edit.dart`）。该通道在 Windows 桌面（尤其中文 IME 环境）收不到文本回传，控制键因另有 `keyToTerminalKey` 硬件路径而不受影响——于是表现为「只能回车」。

**解法**：给 `TerminalView` 传 `hardwareKeyboardOnly: true`，全部输入改走硬件按键事件（`keyEvent.character` → `terminal.textInput`）。代价是终端内无法用 IME 组合输入中文（原本也是坏的，等于净收益）。

---

## 🗺️ Roadmap

- [ ] 终端复制 / 粘贴快捷键（Ctrl+Shift+C/V）与右键菜单
- [x] 口令加密存储（已用 Windows DPAPI 实现绑定用户的加密；凭据管理器作为备选路线）
- [x] 串口 / Console 终端（COM1-99，Win32 FFI 直连，8N1 + 可选波特率）
- [x] 串口自动探测波特率（软件试探法：候选轮询 + 可打印/UTF-8/横幅打分）
- [ ] Telnet / 本地 PowerShell 通道（对齐 XShell）
- [ ] 串口增强：GBK 编码支持、数据位/校验位/停止位/流控配置、枚举系统设备名
- [ ] SFTP 文件浏览与传输
- [ ] 端口转发 / 隧道、X11 / Agent 转发
- [ ] 跳板机级联、密钥生成管理 UI
- [ ] 英文界面（i18n）

## 📄 许可证

MIT License
