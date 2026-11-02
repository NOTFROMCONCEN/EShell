import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'baud_detector.dart';
import 'serial_port.dart';
import 'terminal_connection.dart';

/// 串口终端连接：Win32 COM 口 + xterm 终端实例。
///
/// 读取为主 isolate 10ms 周期轮询（串口 FFI 配置为立即返回，不阻塞 UI）；
/// 键入直接写回串口。日志/解码/状态机由基类共用。
///
/// 自动波特率（autoBaud）：连接时先探测——期间不启动轮询、不接终端，
/// 垃圾字节不会污染渲染；成功后记录实际波特率并复位终端。
class SerialConnection extends TerminalConnection {
  SerialConnection({required super.session});

  SerialPort? _port;
  Timer? _pollTimer;

  /// 自动探测得到的实际波特率（供标签提示展示）。
  int? detectedBaud;

  /// 轮询周期：10ms 延迟对终端交互无感，CPU 占用可忽略。
  static const _pollInterval = Duration(milliseconds: 10);
  static const _readChunkSize = 4096;

  @override
  Future<void> performConnect() async {
    // 串口会话约定：host=COM 口名，port=波特率（8N1）；
    // autoBaud 时 port 仅作探测失败的兜底值。
    final port = SerialPort.open(
      session.host,
      baudRate: session.port,
    );
    _port = port;

    try {
      if (session.autoBaud) {
        await _autoDetectBaud(port);
      }
    } catch (_) {
      // 让基类统一走 failed 流程；performTeardown 会关闭端口。
      rethrow;
    }

    terminal.onOutput = (data) {
      try {
        // xterm 回调给出字符串，串口按 UTF-8 编码写出。
        _port?.write(utf8.encode(data));
      } catch (e) {
        unawaited(handleRemoteClosed(err: e.toString()));
      }
    };
    // 串口无远端尺寸概念，忽略终端尺寸变化。
    terminal.onResize = (_, _, _, _) {};

    _pollTimer = Timer.periodic(_pollInterval, (_) => _poll());
  }

  /// 自动探测波特率。探测阶段轮询未启动、onOutput 未接通，
  /// 错误波特率下的垃圾字节不会进入终端。
  Future<void> _autoDetectBaud(SerialPort port) async {
    final detected = await BaudDetector.detect(
      applyBaud: (baud) async => port.setBaudRate(baud),
      clearBuffers: () async => port.purge(),
      sendProbe: () async => port.write(Uint8List.fromList([0x0D])), // \r
      readAvailable: () => port.read(_readChunkSize),
      wait: (d) => Future<void>.delayed(d),
      onProgress: (baud, attempt, total) {
        statusDetail = '自动探测波特率 · $baud（$attempt/$total）';
        notifyListeners();
      },
    );

    if (detected == null) {
      throw StateError(
          '自动探测波特率失败：未收到有效回显。请确认设备已上电并尝试按回车，'
          '或关闭自动探测、手动指定波特率。');
    }

    detectedBaud = detected;
    // 停在探测到的波特率上，清掉试探期残留字节。
    port.setBaudRate(detected);
    port.purge();
    // 复位终端（RIS），清掉探测期间可能写入的残留（当前无，双保险）。
    terminal.write('\x1bc');
  }

  void _poll() {
    final port = _port;
    if (port == null) return;
    try {
      final Uint8List chunk = port.read(_readChunkSize);
      if (chunk.isNotEmpty) {
        handleRemoteBytes(chunk);
      }
    } catch (e) {
      unawaited(handleRemoteClosed(err: e.toString()));
    }
  }

  @override
  Future<void> performTeardown() async {
    _pollTimer?.cancel();
    _pollTimer = null;
    _port?.close();
    _port = null;
  }
}
