import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// Windows DPAPI（CryptProtectData）口令加密。
///
/// 口令不再明文落盘：密文绑定当前 Windows 用户账户，复制配置文件或
/// 换用户登录都无法解出。存储格式为 `dpapi:v1:<base64>`；
/// 无前缀的历史明文按兼容模式读取，下次保存时自动升级为密文。
/// 非 Windows 平台（仅开发环境）原样透传。
class SecretStore {
  SecretStore._();

  static const _prefix = 'dpapi:v1:';

  /// 额外熵：防止其他程序用 DPAPI 碰撞解密我们存储的值。
  static const _entropy = 'EShell.secret.v1';

  static const _uiForbidden = 0x1;

  /// 明文 → 密文。Windows 加密失败时抛错，禁止把秘密明文写盘。
  static String? protect(String? plain) {
    if (plain == null || plain.isEmpty) return plain;
    if (plain.startsWith(_prefix)) return plain;
    if (!Platform.isWindows) return plain;
    try {
      final encrypted = _crypt(utf16Bytes(plain), encrypt: true);
      return _prefix + base64Encode(encrypted);
    } catch (e) {
      throw StateError('无法加密秘密，已取消保存：$e');
    }
  }

  /// 密文 → 明文（非密文原样返回；解密失败视为未设置）。
  static String? reveal(String? stored) {
    if (stored == null || stored.isEmpty) return stored;
    if (!stored.startsWith(_prefix)) return stored;
    if (!Platform.isWindows) return stored;
    try {
      final bytes = base64Decode(stored.substring(_prefix.length));
      return utf16String(_crypt(bytes, encrypt: false));
    } catch (_) {
      return null;
    }
  }

  /// 把字符串编码为 UTF-16LE 字节（与 Win32 宽字符一致）。
  static Uint8List utf16Bytes(String s) {
    final units = s.codeUnits;
    final bytes = Uint8List(units.length * 2);
    final bd = ByteData.sublistView(bytes);
    for (var i = 0; i < units.length; i++) {
      bd.setUint16(i * 2, units[i], Endian.little);
    }
    return bytes;
  }

  /// UTF-16LE 字节 → 字符串。
  static String utf16String(Uint8List bytes) {
    final bd = ByteData.sublistView(bytes);
    final units = Uint16List(bytes.length ~/ 2);
    for (var i = 0; i < units.length; i++) {
      units[i] = bd.getUint16(i * 2, Endian.little);
    }
    return String.fromCharCodes(units);
  }

  static Uint8List _crypt(Uint8List input, {required bool encrypt}) {
    final localFree = DynamicLibrary.open('kernel32.dll').lookupFunction<
        Pointer<Void> Function(Pointer<Void>),
        Pointer<Void> Function(Pointer<Void>)>('LocalFree');

    final pIn = calloc<_Blob>();
    final pOut = calloc<_Blob>();
    final pEntropy = calloc<_Blob>();
    final inBuf = calloc<Uint8>(input.length);
    inBuf.asTypedList(input.length).setAll(0, input);
    final entropyUnits = _entropy.codeUnits;
    final entropyBuf = calloc<Uint16>(entropyUnits.length);
    for (var i = 0; i < entropyUnits.length; i++) {
      entropyBuf[i] = entropyUnits[i];
    }

    pIn.ref
      ..cbData = input.length
      ..pbData = inBuf;
    pEntropy.ref
      ..cbData = entropyUnits.length * 2
      ..pbData = entropyBuf.cast<Uint8>();
    pOut.ref
      ..cbData = 0
      ..pbData = nullptr;

    try {
      final ok = encrypt ? _protect(pIn, pEntropy, pOut) : _unprotect(pIn, pEntropy, pOut);
      if (ok == 0) {
        throw StateError(encrypt ? 'CryptProtectData 失败' : 'CryptUnprotectData 失败');
      }
      return Uint8List.fromList(pOut.ref.pbData.asTypedList(pOut.ref.cbData));
    } finally {
      if (pOut.ref.pbData != nullptr) {
        localFree(pOut.ref.pbData.cast());
      }
      calloc.free(pIn);
      calloc.free(pOut);
      calloc.free(pEntropy);
      calloc.free(inBuf);
      calloc.free(entropyBuf);
    }
  }

  static int _protect(Pointer<_Blob> pIn, Pointer<_Blob> pEntropy, Pointer<_Blob> pOut) =>
      _cryptProtect(pIn, nullptr, pEntropy, nullptr, nullptr, _uiForbidden, pOut);

  static int _unprotect(Pointer<_Blob> pIn, Pointer<_Blob> pEntropy, Pointer<_Blob> pOut) =>
      _cryptUnprotect(pIn, nullptr, pEntropy, nullptr, nullptr, _uiForbidden, pOut);

  static final _cryptProtect = crypt32.lookupFunction<_CryptDataNative, _CryptDataDart>('CryptProtectData');
  static final _cryptUnprotect = crypt32.lookupFunction<_CryptDataNative, _CryptDataDart>('CryptUnprotectData');
  static final crypt32 = DynamicLibrary.open('crypt32.dll');
}

/// CRYPTOAPI_BLOB（DWORD cbData; BYTE* pbData）。
final class _Blob extends Struct {
  @Uint32()
  external int cbData;

  external Pointer<Uint8> pbData;
}

typedef _CryptDataNative = Int32 Function(
  Pointer<_Blob> pDataIn,
  Pointer<Uint16> szDataDescr,
  Pointer<_Blob> pOptionalEntropy,
  Pointer<Void> pvReserved,
  Pointer<Void> pPromptStruct,
  Uint32 dwFlags,
  Pointer<_Blob> pDataOut,
);

typedef _CryptDataDart = int Function(
  Pointer<_Blob> pDataIn,
  Pointer<Uint16> szDataDescr,
  Pointer<_Blob> pOptionalEntropy,
  Pointer<Void> pvReserved,
  Pointer<Void> pPromptStruct,
  int dwFlags,
  Pointer<_Blob> pDataOut,
);
