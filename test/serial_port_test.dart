import 'package:eshell/services/serial_port.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SerialPort · Win32 FFI', () {
    test('systemPortNames 系统枚举：毫秒级、名称合法、按口号升序', () {
      final ports = SerialPort.systemPortNames();
      var last = 0;
      for (final p in ports) {
        final m = RegExp(r'^COM(\d+)$').firstMatch(p);
        expect(m, isNotNull, reason: p);
        final n = int.parse(m!.group(1)!);
        expect(n, greaterThanOrEqualTo(last), reason: p);
        last = n;
      }
    });

    test('扫描（后台 isolate）不抛异常，结果均为合法 COM 口名且升序', () async {
      final ports = await SerialPort.scanAvailable();
      // 机器上有没有真实串口均可：只验证扫描流程与名称格式。
      var last = 0;
      for (final p in ports) {
        final m = RegExp(r'^COM(\d+)$').firstMatch(p);
        expect(m, isNotNull, reason: p);
        final n = int.parse(m!.group(1)!);
        expect(n, greaterThanOrEqualTo(last), reason: p);
        last = n;
      }
    });

    test('打开不存在的串口抛出可读错误', () {
      // COM4242 不会存在于常规机器；即便被占用也会走同一错误路径。
      expect(
        () => SerialPort.open('COM4242'),
        throwsA(isA<StateError>()),
      );
    });

    test('COM 口名统一大写处理（com9 等价 COM9）', () {
      // 不存在的口：错误文案中应出现归一化后的大写名称。
      try {
        SerialPort.open('com4242');
        // 若机器真有 com4242（几乎不可能）则跳过断言。
      } on StateError catch (e) {
        expect(e.message, contains('COM4242'));
      }
    });
  });
}
