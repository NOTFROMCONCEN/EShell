import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// 剪贴板图片读取（Win32 CF_DIB）与图片统一压缩编码。
///
/// 与 DPAPI/串口同一套零插件做法：kernel32/user32 FFI 读剪贴板位图，
/// 解码/缩放/PNG 编码放在后台 isolate（大截图不卡 UI）。
/// 统一缩放到最长边 [defaultMaxDimension]（OpenAI 视觉推荐 ≤1568px），
/// 编码为 PNG 供 `data:image/png;base64,...` 内联到多模态请求。
class ClipboardImage {
  ClipboardImage._();

  /// 视觉模型推荐的最长边上限。
  static const int defaultMaxDimension = 1568;

  /// 剪贴板里是否有位图（同步、毫秒级——用于决定是否拦截 Ctrl+V）。
  static bool hasImage() {
    if (!Platform.isWindows) return false;
    if (_isFormatAvailable(_cfDib) == 0) return false;
    return true;
  }

  /// 读取剪贴板图片并压缩为 PNG；没有图片或解析失败返回 null。
  static Future<Uint8List?> readImagePng({int maxDimension = defaultMaxDimension}) async {
    final dib = _readDibBytes();
    if (dib == null) return null;
    return normalizeImageBytes(dib, isDib: true, maxDimension: maxDimension);
  }

  /// 任意图片字节（PNG/JPG/BMP…）或剪贴板 DIB → 缩放后的 PNG。
  /// 解码/缩放/编码在后台 isolate 执行。
  static Future<Uint8List?> normalizeImageBytes(
    Uint8List bytes, {
    bool isDib = false,
    int maxDimension = defaultMaxDimension,
  }) {
    return Isolate.run(() => _normalizeSync(bytes, isDib, maxDimension));
  }

  static Uint8List? _normalizeSync(
      Uint8List bytes, bool isDib, int maxDimension) {
    img.Image? decoded;
    if (isDib) {
      decoded = _decodeDib(bytes);
    } else {
      try {
        decoded = img.decodeImage(bytes);
      } catch (_) {
        decoded = null;
      }
    }
    if (decoded == null) return null;

    var image = decoded;
    final maxSide = image.width > image.height ? image.width : image.height;
    if (maxSide > maxDimension) {
      final scale = maxDimension / maxSide;
      image = img.copyResize(
        image,
        width: (image.width * scale).round().clamp(1, maxDimension),
        height: (image.height * scale).round().clamp(1, maxDimension),
        interpolation: img.Interpolation.average,
      );
    }
    return Uint8List.fromList(img.encodePng(image, level: 6));
  }

  /// 解析 CF_DIB（BITMAPINFOHEADER + 24/32bpp 像素，BI_RGB）。
  ///
  /// 兼容自底向上（正高度）与自顶向下（负高度）；BI_BITFIELDS 的
  /// 32bpp 按 BGRA 处理（系统截图工具默认布局）。
  static img.Image? _decodeDib(Uint8List dib) {
    if (dib.length < 40) return null;
    final bd = ByteData.sublistView(dib);
    final headerSize = bd.getUint32(0, Endian.little);
    final width = bd.getInt32(4, Endian.little);
    final rawHeight = bd.getInt32(8, Endian.little);
    final bitCount = bd.getUint16(14, Endian.little);
    final compression = bd.getUint32(16, Endian.little);
    final clrUsed = bd.getUint32(32, Endian.little);

    if (width <= 0 || rawHeight == 0) return null;
    if (bitCount != 24 && bitCount != 32) return null;
    if (bitCount == 24 && compression != 0) return null; // 仅 BI_RGB
    if (bitCount == 32 && compression != 0 && compression != 3) return null;

    final topDown = rawHeight < 0;
    final height = rawHeight.abs();
    final bytesPerPixel = bitCount ~/ 8;
    final stride = ((width * bitCount + 31) ~/ 32) * 4;
    final offset = headerSize + clrUsed * 4;
    if (offset < 0 || dib.length < offset + stride * height) return null;

    final image = img.Image(width: width, height: height);
    for (var y = 0; y < height; y++) {
      final srcY = topDown ? y : height - 1 - y;
      var p = offset + srcY * stride;
      for (var x = 0; x < width; x++) {
        final b = dib[p];
        final g = dib[p + 1];
        final r = dib[p + 2];
        final a = bitCount == 32 ? dib[p + 3] : 255;
        image.setPixelRgba(x, y, r, g, b, a);
        p += bytesPerPixel;
      }
    }
    return image;
  }

  /// 从剪贴板取 CF_DIB 原始字节（同步；剪贴板访问需要当前线程）。
  static Uint8List? _readDibBytes() {
    if (!Platform.isWindows) return null;
    if (_openClipboard(0) == 0) return null;
    try {
      if (_isFormatAvailable(_cfDib) == 0) return null;
      final handle = _getClipboardData(_cfDib);
      if (handle == 0) return null;
      final ptr = _globalLock(handle);
      if (ptr == nullptr) return null;
      try {
        final size = _globalSize(handle);
        if (size <= 40) return null;
        return Uint8List.fromList(ptr.cast<Uint8>().asTypedList(size));
      } finally {
        _globalUnlock(handle);
      }
    } finally {
      _closeClipboard(0);
    }
  }

  static const int _cfDib = 8;
}

// ---------- Win32 绑定 ----------

typedef _ClipboardBoolNative = Int32 Function(IntPtr hWnd);
typedef _ClipboardBoolDart = int Function(int hWnd);

typedef _IsFormatAvailableNative = Int32 Function(Uint32 format);
typedef _IsFormatAvailableDart = int Function(int format);

typedef _GetClipboardDataNative = IntPtr Function(Uint32 format);
typedef _GetClipboardDataDart = int Function(int format);

typedef _GlobalLockNative = Pointer<Uint8> Function(IntPtr hMem);
typedef _GlobalLockDart = Pointer<Uint8> Function(int hMem);

typedef _GlobalUnlockNative = Int32 Function(IntPtr hMem);
typedef _GlobalUnlockDart = int Function(int hMem);

typedef _GlobalSizeNative = UintPtr Function(IntPtr hMem);
typedef _GlobalSizeDart = int Function(int hMem);

final _user32 = DynamicLibrary.open('user32.dll');
final _kernel32 = DynamicLibrary.open('kernel32.dll');

final _openClipboard = _user32.lookupFunction<_ClipboardBoolNative,
    _ClipboardBoolDart>('OpenClipboard');
final _closeClipboard = _user32.lookupFunction<_ClipboardBoolNative,
    _ClipboardBoolDart>('CloseClipboard');
final _isFormatAvailable = _user32.lookupFunction<
    _IsFormatAvailableNative,
    _IsFormatAvailableDart>('IsClipboardFormatAvailable');
final _getClipboardData = _user32.lookupFunction<_GetClipboardDataNative,
    _GetClipboardDataDart>('GetClipboardData');
final _globalLock = _kernel32
    .lookupFunction<_GlobalLockNative, _GlobalLockDart>('GlobalLock');
final _globalUnlock = _kernel32
    .lookupFunction<_GlobalUnlockNative, _GlobalUnlockDart>('GlobalUnlock');
final _globalSize = _kernel32
    .lookupFunction<_GlobalSizeNative, _GlobalSizeDart>('GlobalSize');
