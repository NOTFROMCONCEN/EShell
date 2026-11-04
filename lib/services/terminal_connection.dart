import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:xterm/xterm.dart';

import '../models/session.dart';
import '../utils/format.dart';
import '../utils/utf8_stream_decoder.dart';
import 'session_store.dart';

/// 连接生命周期状态。[idle] 已移除：连接对象创建后立即进入 connecting。
enum ConnStatus { connecting, connected, failed, closed }

/// 主机公钥指纹与已记录值不一致时的待确认信息（S3 更新确认流程，仅 SSH）。
class HostKeyMismatch {
  const HostKeyMismatch({
    required this.host,
    required this.port,
    required this.keyType,
    required this.storedFingerprint,
    required this.actualFingerprint,
  });

  final String host;
  final int port;
  final String keyType;
  final String storedFingerprint;
  final String actualFingerprint;
}

/// 会话日志脱敏：password: xxx / 密码=xxx / 口令: xxx 等 → 固定掩码。
/// 仅对日志副本生效，终端显示不变。逐包正则，跨包截断的匹配是尽力而为。
final RegExp _secretPattern = RegExp(
    r'(password|passwd|pwd|passphrase|密码|口令)\s*[:：=]\s*\S*',
    caseSensitive: false);

String _maskSecretsIn(String text) =>
    text.replaceAllMapped(_secretPattern, (m) => '${m[1]}:******');

/// 终端连接基类：SSH 与串口的共用骨架。
///
/// 持有 xterm 终端实例、状态机、会话日志（原始字节落盘/脱敏）与
/// UTF-8 增量解码；子类只实现 [performConnect]（建立通道）、
/// [performTeardown]（释放通道资源），收到远端字节时调用
/// [handleRemoteBytes]，远端关闭时调用 [handleRemoteClosed]。
abstract class TerminalConnection extends ChangeNotifier {
  TerminalConnection({required this.session});

  /// 当前会话配置。不可变模型：编辑保存后由 AppState 通过 [applySession]
  /// 替换为新实例；替换只影响之后的（重）连接，不打断当前会话。
  Session session;

  // 滚动缓冲内存 = 行数 × 行宽 × 16B（约 2-4KB/行）。5000 行对运维场景
  // 已足够宽裕（单标签满载约 20MB）。
  final Terminal terminal = Terminal(maxLines: 5000);

  ConnStatus status = ConnStatus.connecting;
  String? error;

  /// 连接进行中的补充进度文案（如串口自动探测「9600 · 2/7」），
  /// 由「正在连接」覆盖层展示；连接结束自动清空。
  String? statusDetail;

  /// 服务器主机公钥指纹（仅 SSH，供标签提示展示）。
  String? hostFingerprint;

  /// 建立连接的时间（供标签提示展示）。
  DateTime? connectedAt;

  /// 非空表示本次连接因指纹变化被阻止，等待用户确认更新（仅 SSH）。
  HostKeyMismatch? hostKeyMismatch;

  /// 是否已发起过连接尝试。
  ///
  /// 初始 status 即为 connecting（C6 移除 idle 后的显示态），若无此标记，
  /// [connect] 的重入守卫会把「首次连接」误判为「连接进行中」直接拦下，
  /// 表现为永远卡在正在连接（2026-10-27 回归修复）。
  bool _connectStarted = false;
  int _connectionGeneration = 0;

  /// 会话日志状态：把远端输出写入本地文件。
  bool logging = false;
  String? logPath;
  bool _maskSecrets = false;
  IOSink? _logSink;

  /// UTF-8 跨 TCP/串口分块的增量解码器（C1：中文不再乱码）。
  final Utf8StreamDecoder _decoder = Utf8StreamDecoder();

  /// 编辑保存后替换会话配置实例（仅影响之后的重连）。
  void applySession(Session updated) => session = updated;

  /// 建立连接。重入守卫：连接进行中或已连接时忽略；失败/关闭后可重试。
  Future<void> connect() async {
    if (_connectStarted &&
        (status == ConnStatus.connecting || status == ConnStatus.connected)) {
      return;
    }
    _connectStarted = true;
    final generation = ++_connectionGeneration;
    status = ConnStatus.connecting;
    error = null;
    hostKeyMismatch = null;
    statusDetail = null;
    notifyListeners();

    try {
      await performConnect();
      if (generation != _connectionGeneration) {
        await performTeardown();
        return;
      }
      statusDetail = null;
      status = ConnStatus.connected;
      connectedAt = DateTime.now();
      // lastConnectedAt 由 AppState 监听连接状态后 upsert 副本更新（M3）。
    } catch (e) {
      if (generation != _connectionGeneration) {
        await performTeardown();
        return;
      }
      // 指纹阻断路径已设置 error，异常文本不再覆盖。
      error ??= e.toString();
      statusDetail = null;
      status = ConnStatus.failed;
      await performTeardown();
    }
    notifyListeners();
  }

  /// 建立底层通道；成功返回前不要改动 status（基类统一流转）。
  @protected
  Future<void> performConnect();

  /// 释放底层通道资源（可重复调用）。
  @protected
  Future<void> performTeardown();

  /// 子类收到远端原始字节时调用：落日志（保真/脱敏）→ 喂终端。
  @protected
  void handleRemoteBytes(Uint8List data) {
    // 增量解码：跨分块的多字节字符留待下块拼接（C1）。
    final text = _decoder.convert(data);
    if (logging) {
      _logSink?.add(_maskSecrets ? utf8.encode(_maskSecretsIn(text)) : data);
    }
    terminal.write(text);
  }

  /// 远端关闭 / 通道出错时调用：停日志（等待落盘）→ 状态流转。
  @protected
  Future<void> handleRemoteClosed({String? err}) async {
    if (err != null) {
      error ??= err;
    }
    await _stopLoggingInternal();
    if (status == ConnStatus.connected || status == ConnStatus.connecting) {
      status = ConnStatus.closed;
      notifyListeners();
    }
  }

  /// 本地主动断开：停日志 → 释放通道 → 状态流转。
  Future<void> disconnect() async {
    ++_connectionGeneration;
    status = ConnStatus.closed;
    await _stopLoggingInternal();
    await performTeardown();
    notifyListeners();
  }

  Future<void> reconnect() => connect();

  /// 向会话发送一条命令并回车（AI「发送到终端」入口）。
  ///
  /// 经 xterm textInput 通道逐行注入：屏幕回显与手动键入完全一致，
  /// SSH/Telnet/串口三种传输统一走同一条路；仅在已连接时生效。
  void sendCommand(String command) {
    if (status != ConnStatus.connected) return;
    final normalized =
        command.trim().replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    if (normalized.isEmpty) return;
    // 逐行 textInput + \r（回车键等价物）：Telnet 的 NVT 编码按 \r
    // 转 CR LF，多行命令等价于逐行键入执行。
    for (final line in normalized.split('\n')) {
      terminal.textInput(line);
      terminal.textInput('\r');
    }
  }

  /// 开始记录会话日志。返回 null 表示成功，否则为错误信息。
  ///
  /// [maskSecrets] 开启时日志写入脱敏后的文本而非原始字节（S2，尽力匹配）。
  Future<String?> startLogging(String path, {bool maskSecrets = false}) async {
    if (logging) return null;
    try {
      final file = File(path);
      final parent = file.parent;
      if (!await parent.exists()) {
        return '目录不存在：${parent.path}';
      }
      final sink = file.openWrite(
        mode: await file.exists() ? FileMode.append : FileMode.write,
      );
      final target = switch (session.transport) {
        SessionTransport.serial => '串口 ${session.address}',
        SessionTransport.telnet => 'telnet ${session.host}:${session.port}',
        SessionTransport.ssh =>
          '${session.username}@${session.host}:${session.port}',
      };
      sink.writeln('===== EShell 会话日志 · '
          '${session.displayName} · $target · '
          '开始于 ${formatTimestamp(DateTime.now())}'
          '${maskSecrets ? ' · 已开启密码脱敏' : ''} =====');
      _logSink = sink;
      logPath = path;
      _maskSecrets = maskSecrets;
      logging = true;
      notifyListeners();
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  /// 停止记录并真正等待落盘完成（C2：不再 fire-and-forget，退出不丢尾部）。
  Future<void> stopLogging() async {
    if (!logging) return;
    await _stopLoggingInternal();
    notifyListeners();
  }

  /// 同步入口的异步实现：写结束标记 → flush → close，均限时防卡死。
  Future<void> _stopLoggingInternal() async {
    final sink = _logSink;
    _logSink = null;
    logging = false;
    if (sink == null) return;
    sink.writeln('===== 连接结束 ${formatTimestamp(DateTime.now())} =====');
    try {
      await sink.flush().timeout(const Duration(seconds: 3));
    } catch (_) {}
    try {
      await sink.close().timeout(const Duration(seconds: 3));
    } catch (_) {}
  }

  /// 用户确认「更新指纹并重连」（S3，仅 SSH）。
  Future<void> acceptHostKey() async {
    final mismatch = hostKeyMismatch;
    if (mismatch == null) return;
    await SessionStore.rememberHostKey(
        mismatch.host, mismatch.port, mismatch.actualFingerprint);
    hostKeyMismatch = null;
    error = null;
    await reconnect();
  }

  /// 放弃本次指纹变化的连接（回到失败页，不更新记录）。
  void dismissHostKeyMismatch() {
    hostKeyMismatch = null;
    notifyListeners();
  }
}
