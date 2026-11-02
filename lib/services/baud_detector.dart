import 'dart:convert';

/// 串口自动波特率探测（软件试探法）。
///
/// Win32 串口 API 不暴露芯片级自动波特率能力（常见 USB 转串芯片也普遍
/// 不支持），通用做法是逐候选波特率试探：切波特率 → 清缓冲 → 写回车
/// 触发提示符 → 等待回显 → 按「可打印字符占比 + 控制台特征横幅」打分。
/// 正确波特率下控制台输出几乎全为可打印字符；错误波特率下是随机垃圾
/// 字节（可打印占比通常 <40%），区分度极高。
class BaudDetector {
  BaudDetector._();

  /// 候选序列按运维场景 likelihood 排列：9600 是网络设备 Console 默认值，
  /// 115200 常见于 Linux 主机/新设备。
  static const List<int> candidates = [
    9600,
    115200,
    57600,
    19200,
    38400,
    4800,
    2400,
  ];

  /// 高置信度早退阈值：接近满分的样本不必继续试探。
  static const double _earlyAcceptScore = 0.97;

  /// 采纳阈值：远高于垃圾样本（约 0.3-0.4）、低于完美样本。
  static const double _acceptScore = 0.85;

  /// 早退/采纳所需的最小样本字节数（避免单字节偶然满分）。
  static const int _minSampleBytes = 12;

  /// 可打印字符占比得分：0.0（全垃圾）~ 1.0（全可打印）。
  ///
  /// 可打印 = ASCII 可见区 + \r \n \t + ESC + **合法 UTF-8 多字节序列**
  ///（中文控制台输出按整序列计可打印，否则中文界面会被误判为垃圾）；
  /// 随机垃圾几乎拼不出合法多字节序列，得分依旧很低。
  static double scoreSample(List<int> bytes) {
    if (bytes.isEmpty) return 0;
    var good = 0;
    var i = 0;
    final n = bytes.length;
    bool cont(int b) => (b & 0xC0) == 0x80;

    while (i < n) {
      final b = bytes[i];
      if (b == 0x0D || b == 0x0A || b == 0x09 || (b >= 0x20 && b < 0x7F)) {
        good++;
        i++;
      } else if (b == 0x1B) {
        // ESC：转义序列起始，按可打印计（正确波特率下常见）。
        good++;
        i++;
      } else if (b >= 0xC2 && b <= 0xDF && i + 1 < n && cont(bytes[i + 1])) {
        good += 2;
        i += 2;
      } else if (b >= 0xE0 &&
          b <= 0xEF &&
          i + 2 < n &&
          cont(bytes[i + 1]) &&
          cont(bytes[i + 2])) {
        good += 3;
        i += 3;
      } else if (b >= 0xF0 &&
          b <= 0xF4 &&
          i + 3 < n &&
          cont(bytes[i + 1]) &&
          cont(bytes[i + 2]) &&
          cont(bytes[i + 3])) {
        good += 4;
        i += 4;
      } else {
        i++; // 坏字节
      }
    }
    return good / n;
  }

  /// 控制台特征横幅（网络设备登录提示/主机名提示符等），命中说明样本
  /// 几乎必然来自真实控制台。注意：Dart RegExp 不支持 (?i) 内联开关，
  /// 统一用 caseSensitive: false。
  static final List<RegExp> _bannerPatterns = [
    RegExp(r'user\s+access\s+verification', caseSensitive: false),
    RegExp(r'(username|password|login)\s*[:：]', caseSensitive: false),
    RegExp(r'press\s+(return|enter|any\s+key)', caseSensitive: false),
    RegExp(r'quidway|huawei|h3c|cisco|radius|console', caseSensitive: false),
    RegExp(r'<[A-Za-z0-9._-]+>'), // <H3C> / <Quidway> 用户视图提示符
    RegExp(r'\[[A-Za-z0-9._~-]+\]'), // [switch] 系统视图提示符
  ];

  static bool hasBanner(List<int> bytes) {
    // latin1 宽松解码：只做模式匹配，不用于展示。
    final text = latin1.decode(bytes, allowInvalid: true);
    return _bannerPatterns.any((p) => p.hasMatch(text));
  }

  /// 综合得分：可打印占比为主，横幅命中加成（封顶 1.0）。
  static double score(List<int> bytes) {
    final base = scoreSample(bytes);
    if (base < 0.5) return base; // 明显是垃圾，横幅加分无意义
    return hasBanner(bytes) ? (base + 0.05).clamp(0.0, 1.0) : base;
  }

  /// 探测驱动。串口操作全部经回调注入，便于单测（假时钟/脚本化样本）。
  ///
  /// 返回探测到的波特率；全部候选都不达标返回 null（调用方落到兜底
  /// 波特率并提示手动指定）。
  static Future<int?> detect({
    required Future<void> Function(int baud) applyBaud,
    required Future<void> Function() clearBuffers,
    required Future<void> Function() sendProbe,
    required List<int> Function() readAvailable,
    required Future<void> Function(Duration d) wait,
    void Function(int baud, int attempt, int total)? onProgress,
    List<int> candidates = candidates,
    Duration settle = const Duration(milliseconds: 350),
  }) async {
    var bestBaud = 0;
    var bestScore = 0.0;
    var attempt = 0;

    for (final baud in candidates) {
      attempt++;
      onProgress?.call(baud, attempt, candidates.length);
      await applyBaud(baud);
      await clearBuffers();
      await sendProbe();
      await wait(settle);

      var sample = readAvailable();
      // 提示符可能分批到达：样本过短时再补一小拍。
      if (sample.length < _minSampleBytes) {
        await wait(const Duration(milliseconds: 150));
        sample = [...sample, ...readAvailable()];
      }
      if (sample.length < _minSampleBytes) continue; // 静默线路

      final s = score(sample);
      if (s > bestScore) {
        bestScore = s;
        bestBaud = baud;
      }
      if (s >= _earlyAcceptScore && sample.length >= _minSampleBytes) {
        return baud; // 高置信度早退
      }
    }
    return bestScore >= _acceptScore ? bestBaud : null;
  }
}
