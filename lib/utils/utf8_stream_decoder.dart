import 'dart:convert';

/// 增量 UTF-8 解码器。
///
/// SSH 服务器的输出按 TCP 分块到达，一个多字节字符（中文 3 字节、
/// emoji 4 字节）可能被拆在两个分块里。逐块 `utf8.decode` 会把
/// 不完整的序列替换成 U+FFFD 造成中文乱码。
///
/// 本类把每个分块尾部不完整的序列暂存，拼到下一分块开头后再解码；
/// [flush] 在流结束时输出残留字节（按 allowMalformed 容错）。
class Utf8StreamDecoder {
  final List<int> _pending = [];

  /// 解码一个分块，返回其中「完整」部分的文本。
  String convert(List<int> chunk) {
    List<int> buf;
    if (_pending.isEmpty) {
      buf = chunk;
    } else {
      _pending.addAll(chunk);
      buf = List<int>.of(_pending);
      _pending.clear();
    }
    if (buf.isEmpty) return '';

    // 从尾部回溯：跳过最多 3 个连续字节，定位最后一个序列的起始字节。
    var i = buf.length - 1;
    var continuations = 0;
    while (i >= 0 && continuations < 4 && (buf[i] & 0xC0) == 0x80) {
      i--;
      continuations++;
    }

    var cut = buf.length;
    if (i >= 0 && continuations < 4) {
      final lead = buf[i];
      // 0xxxxxxx=1 字节；110=2；1110=3；11110=4；其余为非法首字节，
      // 交给 allowMalformed 生成替换符，不做截断。
      final seqLen = lead < 0x80
          ? 1
          : (lead & 0xE0) == 0xC0
              ? 2
              : (lead & 0xF0) == 0xE0
                  ? 3
                  : (lead & 0xF8) == 0xF0
                      ? 4
                      : 1;
      // 首字节 + 已见到的后续字节数不足序列长度 → 尾部不完整，留待下块。
      if (seqLen > 1 && buf.length - i < seqLen) cut = i;
    }

    if (cut == buf.length) {
      return utf8.decode(buf, allowMalformed: true);
    }
    _pending.addAll(buf.sublist(cut));
    return utf8.decode(
      cut == 0 ? const <int>[] : buf.sublist(0, cut),
      allowMalformed: true,
    );
  }

  /// 流结束时调用：输出残留的不完整序列（容错解码）。
  String flush() {
    if (_pending.isEmpty) return '';
    final rest = utf8.decode(_pending, allowMalformed: true);
    _pending.clear();
    return rest;
  }
}
