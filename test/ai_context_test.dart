import 'package:eshell/models/session.dart';
import 'package:eshell/services/ai_context.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('buildTerminalContext', () {
    test('只保留最近 N 行，附带会话信息与行数说明', () {
      final text = List.generate(20, (i) => 'line$i').join('\n');
      final context = buildTerminalContext(
        displayName: 'R1',
        transport: 'SSH',
        address: 'admin@198.51.100.1:22',
        status: '已连接',
        terminalText: text,
        maxLines: 5,
      );
      expect(context, contains('会话: R1'));
      expect(context, contains('类型: SSH'));
      expect(context, contains('地址: admin@198.51.100.1:22'));
      expect(context, contains('最近 5 行'));
      expect(context, contains('line19'));
      expect(context, contains('line15'));
      expect(context, isNot(contains('line14')));
    });

    test('去掉尾部空行；无输出时给出提示', () {
      final context = buildTerminalContext(
        displayName: 'R1',
        transport: 'Telnet',
        address: '127.0.0.1:32768',
        status: '已连接',
        terminalText: 'first\nsecond\n\n\n',
      );
      expect(context, contains('second'));
      expect(context, contains('最近 2 行'));

      final empty = buildTerminalContext(
        displayName: 'R2',
        transport: '串口',
        address: 'COM3 · 9600 bps',
        status: '连接中',
        terminalText: '\n\n',
      );
      expect(empty, contains('终端当前无输出'));
    });

    test('超长内容按字符上限从尾部截断', () {
      final longText = List.generate(3000, (i) => 'abcdefghij').join('\n');
      final context = buildTerminalContext(
        displayName: 'R1',
        transport: 'SSH',
        address: 'h:22',
        status: '已连接',
        terminalText: longText,
        maxLines: 3000,
        maxChars: 500,
      );
      expect(context.length, lessThan(1000));
      expect(context, contains('abcdefghij'));
    });
  });

  test('transportLabel / connectionStatusLabel', () {
    expect(transportLabel(SessionTransport.ssh), 'SSH');
    expect(transportLabel(SessionTransport.telnet), 'Telnet');
    expect(transportLabel(SessionTransport.serial), '串口');
    expect(connectionStatusLabel('connected'), '已连接');
    expect(connectionStatusLabel('failed'), '连接失败');
    expect(connectionStatusLabel('unknown'), 'unknown');
  });
}
