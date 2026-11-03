import 'dart:async';

import 'package:eshell/models/session.dart';
import 'package:eshell/services/terminal_connection.dart';
import 'package:flutter_test/flutter_test.dart';

class _DelayedConnection extends TerminalConnection {
  _DelayedConnection()
      : super(
          session: Session(
            id: 'race',
            name: '',
            host: '127.0.0.1',
            port: 22,
            username: 'test',
          ),
        );

  final ready = Completer<void>();
  final complete = Completer<void>();
  int teardowns = 0;

  @override
  Future<void> performConnect() async {
    ready.complete();
    await complete.future;
  }

  @override
  Future<void> performTeardown() async {
    teardowns++;
  }
}

void main() {
  test('连接建立期间断开，迟到的成功不得恢复 connected', () async {
    final conn = _DelayedConnection();
    final connecting = conn.connect();
    await conn.ready.future;
    await conn.disconnect();
    conn.complete.complete();
    await connecting;
    expect(conn.status, ConnStatus.closed);
    expect(conn.teardowns, greaterThanOrEqualTo(1));
  });
}
