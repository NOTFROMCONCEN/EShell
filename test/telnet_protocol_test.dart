import 'dart:typed_data';

import 'package:eshell/services/telnet_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List bytes(List<int> values) => Uint8List.fromList(values);

void main() {
  group('TelnetCodec · 初始协商', () {
    test('声明 TERMINAL-TYPE / NAWS / SGA 并请求对端 SGA', () {
      final codec = TelnetCodec();
      expect(codec.initialNegotiation().toList(), [
        TelnetCommand.iac, TelnetCommand.will, TelnetOption.terminalType,
        TelnetCommand.iac, TelnetCommand.will, TelnetOption.naws,
        TelnetCommand.iac, TelnetCommand.will, TelnetOption.suppressGoAhead,
        TelnetCommand.iac, TelnetCommand.doOption,
        TelnetOption.suppressGoAhead,
      ]);
    });
  });

  group('TelnetCodec · 数据通道', () {
    test('普通数据原样通过，无回包', () {
      final codec = TelnetCodec();
      final result = codec.feed(bytes([0x68, 0x65, 0x6C, 0x6C, 0x6F]));
      expect(result.data.toList(), [0x68, 0x65, 0x6C, 0x6C, 0x6F]);
      expect(result.replies, isEmpty);
    });

    test('IAC IAC 还原为数据字节 0xFF', () {
      final codec = TelnetCodec();
      final result = codec.feed(bytes([0x41, 255, 255, 0x42]));
      expect(result.data.toList(), [0x41, 0xFF, 0x42]);
    });

    test('IAC 命令跨 chunk 拆开也能正确解析', () {
      final codec = TelnetCodec();
      final first = codec.feed(bytes([0x61, 255]));
      expect(first.data.toList(), [0x61]);
      expect(first.replies, isEmpty);

      final second = codec.feed(bytes([TelnetCommand.will, TelnetOption.echo]));
      expect(second.data, isEmpty);
      expect(second.replies.toList(),
          [TelnetCommand.iac, TelnetCommand.doOption, TelnetOption.echo]);
    });

    test('GA / NOP 等无参命令被忽略', () {
      final codec = TelnetCodec();
      final result = codec.feed(bytes([255, 249, 255, 241, 0x7A]));
      expect(result.data.toList(), [0x7A]);
      expect(result.replies, isEmpty);
    });
  });

  group('TelnetCodec · 选项协商', () {
    test('服务端 WILL ECHO → 客户端 DO ECHO', () {
      final codec = TelnetCodec();
      final result = codec.feed(bytes([255, 251, 1]));
      expect(result.replies.toList(),
          [TelnetCommand.iac, TelnetCommand.doOption, TelnetOption.echo]);
      expect(codec.remoteEcho, isTrue);
    });

    test('服务端 WILL BINARY → DO BINARY 且不再补 CR LF', () {
      final codec = TelnetCodec();
      codec.feed(bytes([255, 251, 0]));
      expect(codec.remoteBinary, isTrue);
      expect(codec.encodeOutgoing('a\r').toList(), [0x61, 0x0D]);
    });

    test('不支持的 WILL 选项回 DONT，重复请求不重复回包', () {
      final codec = TelnetCodec();
      final first = codec.feed(bytes([255, 251, 34])); // LINEMODE
      expect(first.replies.toList(),
          [TelnetCommand.iac, TelnetCommand.dont, 34]);
      final second = codec.feed(bytes([255, 251, 34]));
      expect(second.replies, isEmpty);
    });

    test('不支持 DO 选项回 WONT', () {
      final codec = TelnetCodec();
      final result = codec.feed(bytes([255, 253, 34]));
      expect(result.replies.toList(),
          [TelnetCommand.iac, TelnetCommand.wont, 34]);
    });

    test('未预声明的 DO TERMINAL-TYPE → 回 WILL', () {
      final codec = TelnetCodec();
      final result = codec.feed(bytes([255, 253, 24]));
      expect(result.replies.toList(), [
        TelnetCommand.iac,
        TelnetCommand.will,
        TelnetOption.terminalType,
      ]);
    });

    test('初始协商已声明过的 DO TERMINAL-TYPE 不重复回 WILL', () {
      final codec = TelnetCodec()..initialNegotiation();
      final result = codec.feed(bytes([255, 253, 24]));
      expect(result.replies, isEmpty);
    });

    test('DO NAWS → 回当前窗口尺寸子协商', () {
      final codec = TelnetCodec(columns: 120, rows: 40)..initialNegotiation();
      final result = codec.feed(bytes([255, 253, 31]));
      expect(result.replies.toList(), [
        TelnetCommand.iac,
        TelnetCommand.sb,
        TelnetOption.naws,
        0, 120, 0, 40,
        TelnetCommand.iac,
        TelnetCommand.se,
      ]);
      expect(codec.nawsNegotiated, isTrue);
    });

    test('DO NAWS 前不会主动上报 resize（避免向不支持方发子协商）', () {
      final codec = TelnetCodec();
      expect(codec.nawsNegotiated, isFalse);
    });

    test('DONT NAWS 后停止上报窗口尺寸', () {
      final codec = TelnetCodec()..initialNegotiation();
      codec.feed(bytes([255, 253, 31]));
      expect(codec.nawsNegotiated, isTrue);
      codec.feed(bytes([255, 254, 31]));
      expect(codec.nawsNegotiated, isFalse);
    });
  });

  group('TelnetCodec · 子协商', () {
    test('TTYPE SEND → 回 IS xterm-256color', () {
      final codec = TelnetCodec()..initialNegotiation();
      final result = codec.feed(bytes([255, 250, 24, 1, 255, 240]));
      expect(result.data, isEmpty);
      final replies = result.replies.toList();
      expect(replies.sublist(0, 4),
          [TelnetCommand.iac, TelnetCommand.sb, TelnetOption.terminalType, 0]);
      expect(
        String.fromCharCodes(replies.sublist(4, replies.length - 2)),
        'xterm-256color',
      );
      expect(replies.sublist(replies.length - 2),
          [TelnetCommand.iac, TelnetCommand.se]);
    });

    test('子协商 IAC SE 跨 chunk 仍能正确结束', () {
      final codec = TelnetCodec()..initialNegotiation();
      final first = codec.feed(bytes([255, 250, 24, 1, 255]));
      expect(first.replies, isEmpty);
      final second = codec.feed(bytes([TelnetCommand.se]));
      expect(second.replies.toList().sublist(0, 4),
          [TelnetCommand.iac, TelnetCommand.sb, TelnetOption.terminalType, 0]);
    });

    test('超长子协商丢弃后可继续处理正常数据', () {
      final codec = TelnetCodec()..initialNegotiation();
      codec.feed(bytes([255, 250, 24, 1, ...List.filled(9000, 65)]));
      final result = codec.feed(bytes([255, 240, 66]));
      expect(result.replies, isEmpty);
      expect(result.data.toList(), [66]);
    });
  });

  group('TelnetCodec · 出站编码', () {
    test('裸 CR 补成 CR LF', () {
      final codec = TelnetCodec();
      expect(codec.encodeOutgoing('ls\r').toList(),
          [0x6C, 0x73, 0x0D, 0x0A]);
    });

    test('已有 CR LF 不重复补', () {
      final codec = TelnetCodec();
      expect(codec.encodeOutgoing('a\r\nb').toList(),
          [0x61, 0x0D, 0x0A, 0x62]);
    });

    test('updateWindow 反映到 NAWS 尺寸', () {
      final codec = TelnetCodec();
      codec.updateWindow(100, 30);
      expect(codec.nawsBytes().toList(), [
        TelnetCommand.iac,
        TelnetCommand.sb,
        TelnetOption.naws,
        0, 100, 0, 30,
        TelnetCommand.iac,
        TelnetCommand.se,
      ]);
    });

    test('reset 清空协商状态（重连不沿用旧协商）', () {
      final codec = TelnetCodec();
      codec.feed(bytes([255, 251, 1]));
      expect(codec.remoteEcho, isTrue);
      codec.reset();
      expect(codec.remoteEcho, isFalse);
      final result = codec.feed(bytes([255, 251, 1]));
      expect(result.replies.toList().sublist(0, 3),
          [TelnetCommand.iac, TelnetCommand.doOption, TelnetOption.echo]);
    });
  });
}
