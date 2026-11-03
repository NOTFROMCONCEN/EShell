import 'dart:convert';
import 'dart:typed_data';

/// Telnet 协议常量（RFC 854）。
class TelnetCommand {
  static const int iac = 255; // Interpret As Command
  static const int se = 240; // End of subnegotiation
  static const int sb = 250; // Start of subnegotiation
  static const int will = 251;
  static const int wont = 252;
  static const int doOption = 253;
  static const int dont = 254;
}

/// 常用 Telnet 选项码。
class TelnetOption {
  static const int binary = 0; // RFC 856
  static const int echo = 1; // RFC 857
  static const int suppressGoAhead = 3; // RFC 858
  static const int terminalType = 24; // RFC 1091
  static const int naws = 31; // RFC 1073（窗口尺寸）
}

/// 一次 [TelnetCodec.feed] 的结果。
///
/// [data] 是剥离协商序列后、可直接写给终端的应用数据；
/// [replies] 是本次需要回给对端的协商字节（调用方负责发送）。
class TelnetFeed {
  const TelnetFeed({required this.data, required this.replies});

  final Uint8List data;
  final Uint8List replies;

  bool get isEmpty => data.isEmpty && replies.isEmpty;
}

/// Telnet 协议编解码器（RFC 854/855/858/1073/1091 的最小可用实现）。
///
/// 职责：
/// - 解析对端字节流，剥离 IAC 协商命令与子协商，只把应用数据交给终端；
/// - 对 DO/WILL 协商做出应答（客户端侧：WILL TERMINAL-TYPE / NAWS / SGA，
///   DO ECHO / SGA / BINARY，其余一律 WONT/DONT）；
/// - 应答 TTYPE SEND（回 `xterm-256color`）；
/// - 编码键盘输入（转义 IAC、NVT 模式下把裸 CR 补成 CR LF）。
///
/// 纯逻辑、无 IO，跨 TCP 分块的半包状态（IAC 被拆到两个 chunk）由内部
/// 状态机保留，可单测。
class TelnetCodec {
  TelnetCodec({
    this.terminalType = 'xterm-256color',
    int columns = 80,
    int rows = 24,
  })  : _columns = columns.clamp(1, 0xFFFF),
        _rows = rows.clamp(1, 0xFFFF);

  final String terminalType;

  int _columns;
  int _rows;

  /// 客户端支持本地开启（WILL）的选项。
  static const Set<int> _supportedLocal = {
    TelnetOption.terminalType,
    TelnetOption.naws,
    TelnetOption.suppressGoAhead,
  };

  /// 客户端接受对端开启（DO）的选项。
  static const Set<int> _supportedRemote = {
    TelnetOption.echo,
    TelnetOption.suppressGoAhead,
    TelnetOption.binary,
  };

  static const int _stateData = 0;
  static const int _stateIac = 1;
  static const int _stateOption = 2;
  static const int _stateSb = 3;
  static const int _stateSbIac = 4;

  int _state = _stateData;
  int _pendingCommand = 0;
  final List<int> _sbBuffer = [];
  static const int _maxSubnegotiationBytes = 8192;
  bool _discardSubnegotiation = false;
  final List<int> _replies = [];

  final Set<int> _localEnabled = {};
  final Set<int> _remoteEnabled = {};
  final Set<int> _localRejected = {};
  final Set<int> _remoteRejected = {};

  /// 对端是否已开启 ECHO（服务端回显）。
  bool get remoteEcho => _remoteEnabled.contains(TelnetOption.echo);

  /// 对端是否协商了二进制传输（BINARY 开启后不再做 CR LF 转换）。
  bool get remoteBinary => _remoteEnabled.contains(TelnetOption.binary);

  /// 是否已完成 NAWS（窗口尺寸）协商：是则终端 resize 时应上报。
  bool get nawsNegotiated => _remoteEnabled.contains(TelnetOption.naws);

  /// 重置协商状态（重连时调用，避免沿用上一次连接的选项记忆）。
  void reset() {
    _state = _stateData;
    _pendingCommand = 0;
    _sbBuffer.clear();
    _discardSubnegotiation = false;
    _replies.clear();
    _localEnabled.clear();
    _remoteEnabled.clear();
    _localRejected.clear();
    _remoteRejected.clear();
  }

  /// 连接建立后应主动发送的协商：声明客户端能力并请求对端 SGA。
  ///
  /// 预置选项状态，避免服务端随后发来 DO/WILL 时重复应答造成协商风暴。
  Uint8List initialNegotiation() {
    _localEnabled.addAll(_supportedLocal);
    _remoteEnabled.add(TelnetOption.suppressGoAhead);
    return Uint8List.fromList(const [
      TelnetCommand.iac, TelnetCommand.will, TelnetOption.terminalType,
      TelnetCommand.iac, TelnetCommand.will, TelnetOption.naws,
      TelnetCommand.iac, TelnetCommand.will, TelnetOption.suppressGoAhead,
      TelnetCommand.iac, TelnetCommand.doOption, TelnetOption.suppressGoAhead,
    ]);
  }

  /// 更新本地终端尺寸（NAWS 上报使用）。
  void updateWindow(int columns, int rows) {
    _columns = columns.clamp(1, 0xFFFF);
    _rows = rows.clamp(1, 0xFFFF);
  }

  /// NAWS 子协商字节：`IAC SB NAWS <cols hi> <cols lo> <rows hi> <rows lo> IAC SE`。
  Uint8List nawsBytes([int? columns, int? rows]) {
    final c = (columns ?? _columns).clamp(1, 0xFFFF);
    final r = (rows ?? _rows).clamp(1, 0xFFFF);
    return Uint8List.fromList([
      TelnetCommand.iac,
      TelnetCommand.sb,
      TelnetOption.naws,
      (c >> 8) & 0xFF,
      c & 0xFF,
      (r >> 8) & 0xFF,
      r & 0xFF,
      TelnetCommand.iac,
      TelnetCommand.se,
    ]);
  }

  /// 解析一段对端字节流。
  TelnetFeed feed(Uint8List chunk) {
    final data = <int>[];
    _replies.clear();

    for (final byte in chunk) {
      switch (_state) {
        case _stateData:
          if (byte == TelnetCommand.iac) {
            _state = _stateIac;
          } else {
            data.add(byte);
          }
        case _stateIac:
          if (byte == TelnetCommand.iac) {
            // IAC IAC：数据中的字面 0xFF。
            data.add(TelnetCommand.iac);
            _state = _stateData;
          } else if (byte == TelnetCommand.sb) {
            _sbBuffer.clear();
            _discardSubnegotiation = false;
            _state = _stateSb;
          } else if (byte == TelnetCommand.will ||
              byte == TelnetCommand.wont ||
              byte == TelnetCommand.doOption ||
              byte == TelnetCommand.dont) {
            _pendingCommand = byte;
            _state = _stateOption;
          } else {
            // NOP / GA / DM / AYT 等无参命令：忽略。
            _state = _stateData;
          }
        case _stateOption:
          _handleNegotiation(_pendingCommand, byte);
          _state = _stateData;
        case _stateSb:
          if (byte == TelnetCommand.iac) {
            _state = _stateSbIac;
          } else {
            _appendSubnegotiation(byte);
          }
        case _stateSbIac:
          if (byte == TelnetCommand.se) {
            if (!_discardSubnegotiation) _handleSubnegotiation();
            _sbBuffer.clear();
            _state = _stateData;
          } else if (byte == TelnetCommand.iac) {
            _appendSubnegotiation(TelnetCommand.iac);
            _state = _stateSb;
          } else {
            _appendSubnegotiation(byte);
            _state = _stateSb;
          }
      }
    }

    return TelnetFeed(
      data: Uint8List.fromList(data),
      replies: Uint8List.fromList(_replies),
    );
  }

  void _appendSubnegotiation(int byte) {
    if (_discardSubnegotiation) return;
    if (_sbBuffer.length >= _maxSubnegotiationBytes) {
      _sbBuffer.clear();
      _discardSubnegotiation = true;
      return;
    }
    _sbBuffer.add(byte);
  }

  /// 编码键盘输入：转义 0xFF；非 BINARY 模式下裸 CR 补 LF（NVT 行结束约定）。
  Uint8List encodeOutgoing(String text) {
    final bytes = utf8.encode(text);
    final out = <int>[];
    for (var i = 0; i < bytes.length; i++) {
      final byte = bytes[i];
      if (!remoteBinary &&
          byte == 0x0D &&
          (i + 1 >= bytes.length || bytes[i + 1] != 0x0A)) {
        out
          ..add(0x0D)
          ..add(0x0A);
        continue;
      }
      if (byte == TelnetCommand.iac) {
        out
          ..add(TelnetCommand.iac)
          ..add(TelnetCommand.iac);
      } else {
        out.add(byte);
      }
    }
    return Uint8List.fromList(out);
  }

  void _handleNegotiation(int command, int option) {
    switch (command) {
      case TelnetCommand.will:
        if (_supportedRemote.contains(option)) {
          if (_remoteEnabled.add(option)) {
            _reply(TelnetCommand.doOption, option);
          }
        } else if (_remoteRejected.add(option)) {
          _reply(TelnetCommand.dont, option);
        }
      case TelnetCommand.wont:
        _remoteEnabled.remove(option);
        _remoteRejected.remove(option);
      case TelnetCommand.doOption:
        if (_supportedLocal.contains(option)) {
          if (_localEnabled.add(option)) {
            _reply(TelnetCommand.will, option);
          }
          if (option == TelnetOption.naws) {
            // 对端请求窗口尺寸：把当前尺寸作为子协商回过去。
            _remoteEnabled.add(TelnetOption.naws);
            _replies.addAll(nawsBytes());
          }
        } else if (_localRejected.add(option)) {
          _reply(TelnetCommand.wont, option);
        }
      case TelnetCommand.dont:
        _localEnabled.remove(option);
        _localRejected.remove(option);
        if (option == TelnetOption.naws) {
          _remoteEnabled.remove(TelnetOption.naws);
        }
    }
  }

  void _handleSubnegotiation() {
    if (_sbBuffer.isEmpty) return;
    final option = _sbBuffer.first;
    // TERMINAL-TYPE SEND → 回 IS <终端类型>。
    if (option == TelnetOption.terminalType &&
        _sbBuffer.length >= 2 &&
        _sbBuffer[1] == 1) {
      _replies.addAll([
        TelnetCommand.iac,
        TelnetCommand.sb,
        TelnetOption.terminalType,
        0, // IS
      ]);
      _replies.addAll(utf8.encode(terminalType));
      _replies.addAll([TelnetCommand.iac, TelnetCommand.se]);
    }
  }

  void _reply(int command, int option) {
    _replies.addAll([TelnetCommand.iac, command, option]);
  }
}
