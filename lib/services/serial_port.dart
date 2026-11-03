import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// Win32 串口（COM 口）FFI 封装：kernel32 CreateFile / ReadFile / WriteFile
/// / DCB / COMMTIMEOUTS。不引入第三方 DLL，与 DPAPI 封装同一套做法。
///
/// 句柄常驻主 isolate。读取采用「立即返回」超时配置
/// （ReadIntervalTimeout = MAXDWORD，Total = 0），由 SerialConnection 以
/// 10ms 周期轮询，单次 ReadFile 不阻塞 UI 线程。
class SerialPort {
  SerialPort._(this._handle);

  final int _handle;
  bool _closed = false;

  // HANDLE 作为 IntPtr 处理，规避指针语义；INVALID_HANDLE_VALUE == -1。
  static const int _invalidHandleValue = -1;
  static const int _genericReadWrite = 0xC0000000; // GENERIC_READ|GENERIC_WRITE
  static const int _openExisting = 3;
  static const int _maxDword = 0xFFFFFFFF;

  // DCB fFlags 位定义
  static const int _fBinary = 0x1;
  static const int _fParity = 0x2;
  static const int _fOutxCtsFlow = 0x4;
  static const int _fOutxDsrFlow = 0x8;
  static const int _fDtrControlEnable = 0x10; // bits 4-5 = 01
  static const int _fOutX = 0x100;
  static const int _fInX = 0x200;
  static const int _fNull = 0x800;
  static const int _fRtsControlEnable = 0x1000; // bits 12-13 = 01
  static const int _fAbortOnError = 0x4000;

  /// 打开并配置串口（默认 8N1）。失败抛 [StateError]，message 可直接展示。
  static SerialPort open(
    String rawName, {
    int baudRate = 9600,
    int dataBits = 8,
    String parity = 'N',
    int stopBits = 1,
  }) {
    final name = rawName.toUpperCase();
    // COM10+ 必须用 \\.\ 前缀访问；对 COM1-9 同样有效。
    final path = '\\\\.\\$name';
    final pathPtr = path.toNativeUtf16(allocator: calloc).cast<Uint16>();
    final handle = _createFile(pathPtr, _genericReadWrite, 0, nullptr,
        _openExisting, 0, nullptr);
    // GetLastError 必须紧随 CreateFileW 读取，中间任何原生调用都可能覆盖。
    final errorCode = _lastError();
    calloc.free(pathPtr);

    if (handle == _invalidHandleValue || handle == 0) {
      throw StateError(_openErrorMessage(errorCode, name));
    }
    final port = SerialPort._(handle);
    try {
      port
        .._dataBits = dataBits
        .._parity = parity
        .._stopBits = stopBits;
      port._configure(baudRate: baudRate);
      _setupComm(handle, 8192, 8192);
      port.purge();
    } catch (_) {
      port.close();
      rethrow;
    }
    return port;
  }

  /// 枚举系统当前在位的串口名（COM1-COM99，按口号排序）。
  ///
  /// QueryDosDeviceW 一次调用列出全部 DOS 设备映射（含当前在位的
  /// COM 口），毫秒级返回、不触碰任何驱动——替代逐个 CreateFile
  /// 暴力探测（后者会卡死 UI，见 2026-10-27 扫描卡死修复）。
  static List<String> systemPortNames() {
    final pattern = RegExp(r'^COM(\d+)$', caseSensitive: false);
    var size = 1 << 16; // 64K UTF-16 单元起步，不足则翻倍。
    while (size <= (1 << 21)) {
      final buf = calloc<Uint16>(size);
      final n = _queryDosDevice(nullptr, buf, size);
      final err = _lastError();
      if (n > 0) {
        // 缓冲区是连续 \0 结尾的字符串序列，双 \0 表示结束。
        final ports = <String, int>{};
        var start = 0;
        for (var i = 0; i < n; i++) {
          if (buf[i] != 0) continue;
          if (i == start) break; // 空串 → 列表结束
          final name = String.fromCharCodes(
              [for (var j = start; j < i; j++) buf[j]]);
          start = i + 1;
          final m = pattern.firstMatch(name);
          if (m != null && (int.parse(m.group(1)!) <= 99)) {
            ports[name.toUpperCase()] = int.parse(m.group(1)!);
          }
        }
        final names = ports.keys.toList();
        names.sort((a, b) => ports[a]!.compareTo(ports[b]!));
        calloc.free(buf);
        return names;
      }
      calloc.free(buf);
      if (err != 122) return const []; // 122 = ERROR_INSUFFICIENT_BUFFER
      size *= 2;
    }
    return const [];
  }

  /// 扫描可用串口：先系统枚举在位端口，再逐一验证可打开性
  /// （排除被其他程序占用的口）。
  ///
  /// 整段在后台 isolate 运行（Isolate.run）：驱动初始化慢的口
  /// （蓝牙串口/USB 转串）也只会拖慢扫描，不会冻结 UI。
  static Future<List<String>> scanAvailable({
    int max = 99,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final port = ReceivePort();
    final isolate = await Isolate.spawn(_scanWorker, [port.sendPort, max]);
    try {
      final result = await port.first.timeout(timeout);
      if (result is List<String>) return result;
      throw StateError('串口扫描失败：$result');
    } finally {
      isolate.kill(priority: Isolate.immediate);
      port.close();
    }
  }

  static void _scanWorker(List<Object> args) {
    final sendPort = args[0] as SendPort;
    final max = args[1] as int;
    try {
      sendPort.send(_scanAvailableSync(max: max));
    } catch (e) {
      sendPort.send(e.toString());
    }
  }

  static List<String> _scanAvailableSync({required int max}) {
    final present = systemPortNames()
        .where((n) => int.parse(n.substring(3)) <= max)
        .toList();
    final usable = <String>[];
    for (final name in present) {
      SerialPort? probe;
      try {
        probe = open(name);
        usable.add(name);
      } catch (_) {
        // 被占用或驱动异常：不算可用。
      } finally {
        probe?.close();
      }
    }
    return usable;
  }

  static String _openErrorMessage(int code, String name) {
    // 错误码 0：CreateFileW 返回无效句柄但未置错误（驱动/系统差异），
    // 按占用处理给用户可操作的提示。
    final resolved = code == 0 ? 5 : code;
    return switch (resolved) {
      2 => '串口 $name 不存在',
      5 => '串口 $name 被占用（可能已被其他程序打开）',
      _ => '无法打开串口 $name（Win32 错误码 $code）',
    };
  }

  // 连接参数（open 时设定；自动探测仅切波特率，其余保持不变）。
  int _dataBits = 8;
  String _parity = 'N';
  int _stopBits = 1;

  void _configure({required int baudRate}) {
    _applyDcb(baudRate);
    final timeouts = calloc<_CommTimeouts>();
    try {
      final t = timeouts.ref;
      // 立即返回：有数据带回多少算多少，无数据 0 字节。
      t.readIntervalTimeout = _maxDword;
      t.readTotalTimeoutMultiplier = 0;
      t.readTotalTimeoutConstant = 0;
      // 写入限时 500ms，避免硬件异常时阻塞 UI 线程。
      t.writeTotalTimeoutMultiplier = 0;
      t.writeTotalTimeoutConstant = 500;
      if (_setCommTimeouts(_handle, timeouts) == 0) {
        throw StateError('SetCommTimeouts 失败（Win32 错误码 ${_lastError()}）');
      }
    } finally {
      calloc.free(timeouts);
    }
  }

  /// 运行中切换波特率（自动探测用）：只改波特率，其余参数不变。
  void setBaudRate(int baudRate) => _applyDcb(baudRate);

  void _applyDcb(int baudRate) {
    final dcbPtr = calloc<_Dcb>();
    try {
      if (_getCommState(_handle, dcbPtr) == 0) {
        throw StateError('GetCommState 失败（Win32 错误码 ${_lastError()}）');
      }
      final dcb = dcbPtr.ref;
      // 在驱动返回的 DCB 上收敛为控制台常用的无流控模式。
      var flags = dcb.flags;
      flags &= ~(_fOutxCtsFlow |
          _fOutxDsrFlow |
          _fOutX |
          _fInX |
          _fNull |
          _fAbortOnError);
      flags |= _fBinary | _fDtrControlEnable | _fRtsControlEnable;
      if (_parity != 'N') flags |= _fParity;
      dcb.flags = flags;
      dcb.baudRate = baudRate;
      dcb.byteSize = _dataBits;
      dcb.parity = _parityCode(_parity);
      dcb.stopBits = _stopBits == 2 ? 2 : 0; // 0=1 位，2=2 位
      if (_setCommState(_handle, dcbPtr) == 0) {
        throw StateError(
            'SetCommState 失败：波特率/参数可能不被支持（Win32 错误码 ${_lastError()}）');
      }
    } finally {
      calloc.free(dcbPtr);
    }
  }

  static int _parityCode(String parity) => switch (parity.toUpperCase()) {
        'E' => 2,
        'O' => 1,
        'M' => 4,
        'S' => 3,
        _ => 0, // N
      };

  /// 非阻塞读取：返回当前可用的字节（可能为空）。
  Uint8List read(int maxBytes) {
    if (_closed) return Uint8List(0);
    final buf = calloc<Uint8>(maxBytes);
    final readPtr = calloc<Uint32>();
    try {
      if (_readFile(_handle, buf, maxBytes, readPtr, nullptr) == 0) {
        throw StateError('串口读取失败（Win32 错误码 ${_lastError()}，'
            '可能已被拔出）');
      }
      final n = readPtr.value;
      if (n == 0 || n > maxBytes) return Uint8List(0);
      return Uint8List.fromList(buf.asTypedList(n));
    } finally {
      calloc.free(buf);
      calloc.free(readPtr);
    }
  }

  /// 写入字节（驱动超时上限 500ms，见 _configure）。
  void write(Uint8List bytes) {
    if (_closed || bytes.isEmpty) return;
    final buf = calloc<Uint8>(bytes.length);
    final written = calloc<Uint32>();
    try {
      buf.asTypedList(bytes.length).setAll(0, bytes);
      if (_writeFile(_handle, buf, bytes.length, written, nullptr) == 0) {
        throw StateError('串口写入失败（Win32 错误码 ${_lastError()}）');
      }
    } finally {
      calloc.free(buf);
      calloc.free(written);
    }
  }

  /// 清空收发缓冲（探测切换波特率前后调用，丢弃错乱字节）。
  void purge() => _purgeComm(_handle, 0xC); // PURGE_TXCLEAR | PURGE_RXCLEAR

  void close() {
    if (_closed) return;
    _closed = true;
    _closeHandle(_handle);
  }

  static int _lastError() => _getError();
}

// ---------- Win32 类型与绑定 ----------

final class _Dcb extends Struct {
  @Uint32()
  external int dcbLength;

  @Uint32()
  external int baudRate;

  @Uint32()
  external int flags;

  @Uint16()
  external int wReserved;

  @Uint16()
  external int xonLim;

  @Uint16()
  external int xoffLim;

  @Uint8()
  external int byteSize;

  @Uint8()
  external int parity;

  @Uint8()
  external int stopBits;

  @Int8()
  external int xonChar;

  @Int8()
  external int xoffChar;

  @Int8()
  external int errorChar;

  @Int8()
  external int eofChar;

  @Int8()
  external int evtChar;

  @Uint16()
  external int wReserved1;
}

final class _CommTimeouts extends Struct {
  @Uint32()
  external int readIntervalTimeout;

  @Uint32()
  external int readTotalTimeoutMultiplier;

  @Uint32()
  external int readTotalTimeoutConstant;

  @Uint32()
  external int writeTotalTimeoutMultiplier;

  @Uint32()
  external int writeTotalTimeoutConstant;
}

typedef _CreateFileNative = IntPtr Function(
    Pointer<Uint16> lpFileName,
    Uint32 dwDesiredAccess,
    Uint32 dwShareMode,
    Pointer<Void> lpSecurityAttributes,
    Uint32 dwCreationDisposition,
    Uint32 dwFlagsAndAttributes,
    Pointer<Void> hTemplateFile);
typedef _CreateFileDart = int Function(
    Pointer<Uint16> lpFileName,
    int dwDesiredAccess,
    int dwShareMode,
    Pointer<Void> lpSecurityAttributes,
    int dwCreationDisposition,
    int dwFlagsAndAttributes,
    Pointer<Void> hTemplateFile);

typedef _CommStateNative = Int32 Function(IntPtr hFile, Pointer<_Dcb> lpDCB);
typedef _CommStateDart = int Function(int hFile, Pointer<_Dcb> lpDCB);

typedef _CommTimeoutsNative = Int32 Function(
    IntPtr hFile, Pointer<_CommTimeouts> lpCommTimeouts);
typedef _CommTimeoutsDart = int Function(
    int hFile, Pointer<_CommTimeouts> lpCommTimeouts);

typedef _ReadWriteFileNative = Int32 Function(
    IntPtr hFile,
    Pointer<Uint8> lpBuffer,
    Uint32 nNumberOfBytes,
    Pointer<Uint32> lpNumberOfBytes,
    Pointer<Void> lpOverlapped);
typedef _ReadWriteFileDart = int Function(
    int hFile,
    Pointer<Uint8> lpBuffer,
    int nNumberOfBytes,
    Pointer<Uint32> lpNumberOfBytes,
    Pointer<Void> lpOverlapped);

typedef _PurgeCommNative = Int32 Function(IntPtr hFile, Uint32 dwFlags);
typedef _PurgeCommDart = int Function(int hFile, int dwFlags);

typedef _SetupCommNative = Int32 Function(
    IntPtr hFile, Uint32 dwInQueue, Uint32 dwOutQueue);
typedef _SetupCommDart = int Function(int hFile, int dwInQueue, int dwOutQueue);

typedef _CloseHandleNative = Int32 Function(IntPtr hObject);
typedef _CloseHandleDart = int Function(int hObject);

typedef _GetErrorNative = Uint32 Function();
typedef _GetErrorDart = int Function();

final _kernel32 = DynamicLibrary.open('kernel32.dll');

final _createFile = _kernel32
    .lookupFunction<_CreateFileNative, _CreateFileDart>('CreateFileW');
final _getCommState =
    _kernel32.lookupFunction<_CommStateNative, _CommStateDart>('GetCommState');
final _setCommState =
    _kernel32.lookupFunction<_CommStateNative, _CommStateDart>('SetCommState');
final _setCommTimeouts = _kernel32
    .lookupFunction<_CommTimeoutsNative, _CommTimeoutsDart>('SetCommTimeouts');
final _readFile =
    _kernel32.lookupFunction<_ReadWriteFileNative, _ReadWriteFileDart>('ReadFile');
final _writeFile = _kernel32
    .lookupFunction<_ReadWriteFileNative, _ReadWriteFileDart>('WriteFile');
final _purgeComm =
    _kernel32.lookupFunction<_PurgeCommNative, _PurgeCommDart>('PurgeComm');
final _setupComm =
    _kernel32.lookupFunction<_SetupCommNative, _SetupCommDart>('SetupComm');
final _queryDosDevice = _kernel32
    .lookupFunction<_QueryDosDeviceNative, _QueryDosDeviceDart>('QueryDosDeviceW');
final _closeHandle =
    _kernel32.lookupFunction<_CloseHandleNative, _CloseHandleDart>('CloseHandle');
final _getError =
    _kernel32.lookupFunction<_GetErrorNative, _GetErrorDart>('GetLastError');

typedef _QueryDosDeviceNative = Uint32 Function(
    Pointer<Uint16> lpDeviceName, Pointer<Uint16> lpTargetPath, Uint32 ucchMax);
typedef _QueryDosDeviceDart = int Function(
    Pointer<Uint16> lpDeviceName, Pointer<Uint16> lpTargetPath, int ucchMax);
