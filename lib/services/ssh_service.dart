import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

import '../models/session.dart';
import 'session_store.dart';
import 'terminal_connection.dart';

/// 一条打开的 SSH 终端连接：dartssh2 通道 + xterm 终端实例。
class SshConnection extends TerminalConnection {
  SshConnection({required super.session});

  SSHClient? _client;
  SSHSocket? _pendingSocket;
  SSHSession? _shell;
  StreamSubscription<Uint8List>? _stdoutSub;

  @override
  Future<void> performConnect() async {
    final socket = await SSHSocket.connect(
      session.host,
      session.port,
      timeout: const Duration(seconds: 12),
    );
    _pendingSocket = socket;

    final knownHosts = await SessionStore.loadKnownHosts();
    final hostKey = '${session.host}:${session.port}';

    var identities = <SSHKeyPair>[];
    if (session.authType == SshAuthType.publicKey &&
        (session.privateKeyPath?.isNotEmpty ?? false)) {
      final pem = await File(session.privateKeyPath!).readAsString();
      // S4：优先独立 passphrase 字段；历史数据曾把口令存在 password 里。
      final passphrase = session.passphrase ?? session.password;
      identities = SSHKeyPair.fromPem(pem, passphrase);
    }

    final client = SSHClient(
      socket,
      username: session.username,
      onPasswordRequest: () => session.password ?? '',
      identities: identities,
      onVerifyHostKey: (keyType, fingerprint) async {
        // fingerprint 是 "SHA256:<base64>" 的 ASCII 字节。
        final fp = utf8.decode(fingerprint);
        hostFingerprint = '$keyType $fp';
        final remembered = knownHosts[hostKey];
        if (remembered == fp) return true;
        if (remembered == null) {
          // TOFU：首次连接记住指纹。
          await SessionStore.rememberHostKey(session.host, session.port, fp);
          return true;
        }
        // S3：指纹变化不再只是阻断，记录待确认信息供 UI 呈现更新流程。
        hostKeyMismatch = HostKeyMismatch(
          host: session.host,
          port: session.port,
          keyType: keyType,
          storedFingerprint: remembered,
          actualFingerprint: fp,
        );
        error = '主机公钥指纹与上次记录不一致，已阻止连接'
            '（可能是服务器重装，也可能存在中间人攻击）。';
        notifyListeners();
        return false;
      },
    );
    _client = client;
    _pendingSocket = null;
    await client.authenticated;

    final shell = await client.shell(
      pty: SSHPtyConfig(
        type: 'xterm-256color',
        width: terminal.viewWidth,
        height: terminal.viewHeight,
      ),
    );
    _shell = shell;

    _stdoutSub = shell.stdout.listen(
      handleRemoteBytes,
      onDone: () {
        unawaited(handleRemoteClosed());
      },
      onError: (Object e) {
        unawaited(handleRemoteClosed(err: e.toString()));
      },
      cancelOnError: true,
    );

    terminal.onOutput = (data) {
      // Dart 3 起 utf8.encode 直接返回 Uint8List，避免 fromList 再复制一份。
      _shell?.write(utf8.encode(data));
    };
    terminal.onResize = (columns, rows, _, _) {
      _shell?.resizeTerminal(columns, rows);
    };
  }

  @override
  Future<void> performTeardown() async {
    await _stdoutSub?.cancel();
    _stdoutSub = null;
    _client?.close();
    _client = null;
    await _pendingSocket?.close();
    _pendingSocket = null;
    _shell = null;
  }
}
