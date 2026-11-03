/// AI 回复的 Markdown 解析（零第三方依赖，自研轻量子集）。
///
/// 块级：段落 / 标题 / 无序与有序列表 / 引用 / 分割线 / ``` 代码块 /
/// GFM 管道表格（表头 + 分隔行 + 数据行，支持 `:---:` 对齐与 `\|` 转义）；
/// 行内：**粗体** / *斜体* / `行内代码` / [链接](url)。
/// 面向流式输出设计：未闭合的代码块、表格与行内标记都按字面保留，不会抛异常。
/// 流式期间表格行逐条到达，解析结果逐帧变完整（分隔行到达即成表）。
/// 不支持嵌套列表。
sealed class AiBlock {
  const AiBlock();
}

/// 普通段落（行内标记在渲染时解析）。
class AiTextBlock extends AiBlock {
  const AiTextBlock(this.text);

  final String text;
}

/// 标题（level 1-6）。
class AiHeadingBlock extends AiBlock {
  const AiHeadingBlock({required this.level, required this.text});

  final int level;
  final String text;
}

/// 列表（连续行合并为一个块；ordered 区分有序/无序）。
class AiListBlock extends AiBlock {
  const AiListBlock({required this.items, required this.ordered});

  final List<String> items;
  final bool ordered;
}

/// 引用块（连续 > 行合并）。
class AiQuoteBlock extends AiBlock {
  const AiQuoteBlock(this.text);

  final String text;
}

/// 水平分割线（--- / *** / ___）。
class AiRuleBlock extends AiBlock {
  const AiRuleBlock();
}

class AiCodeBlock extends AiBlock {
  const AiCodeBlock({required this.code, this.language = ''});

  final String code;
  final String language;
}

/// 单元格水平对齐（GFM 分隔行 `:---` / `:---:` / `---:`）。
enum AiTableAlignment { left, center, right }

/// GFM 管道表格。列数以表头为准，数据行缺列补空、多列截断。
class AiTableBlock extends AiBlock {
  const AiTableBlock({
    required this.header,
    required this.rows,
    required this.alignments,
  });

  final List<String> header;
  final List<List<String>> rows;
  final List<AiTableAlignment> alignments;
}

/// 行内片段类型。
enum AiInlineKind { text, bold, italic, boldItalic, code, link }

/// 行内片段：[text] 为展示文本；link 时 [href] 是目标地址。
class AiInline {
  const AiInline(this.kind, this.text, {this.href});

  final AiInlineKind kind;
  final String text;
  final String? href;
}

final RegExp _inlinePattern = RegExp(
  r'(`[^`\n]+`)' // `行内代码`
  r'|\*\*\*([^*\n]+)\*\*\*' // ***粗斜体***
  r'|\*\*([^*\n]+)\*\*' // **粗体**
  r'|\*([^*\n]+)\*' // *斜体*
  r'|\[([^\]\n]+)\]\(([^()\s]+)\)', // [文本](url)
);

/// 解析行内标记为片段列表（不匹配的字符按普通文本保留）。
///
/// 稳妥起见不支持 `_斜体_`（下划线在主机名/标识符里太常见，易误判）。
List<AiInline> parseAiInline(String text) {
  final spans = <AiInline>[];
  var cursor = 0;
  for (final match in _inlinePattern.allMatches(text)) {
    if (match.start > cursor) {
      spans.add(AiInline(AiInlineKind.text, text.substring(cursor, match.start)));
    }
    if (match[1] != null) {
      spans.add(AiInline(AiInlineKind.code, match[1]!));
    } else if (match[2] != null) {
      spans.add(AiInline(AiInlineKind.boldItalic, match[2]!));
    } else if (match[3] != null) {
      spans.add(AiInline(AiInlineKind.bold, match[3]!));
    } else if (match[4] != null) {
      spans.add(AiInline(AiInlineKind.italic, match[4]!));
    } else if (match[5] != null) {
      spans.add(AiInline(AiInlineKind.link, match[5]!, href: match[6]));
    }
    cursor = match.end;
  }
  if (cursor < text.length) {
    spans.add(AiInline(AiInlineKind.text, text.substring(cursor)));
  }
  return spans;
}

final RegExp _headingPattern = RegExp(r'^(#{1,6})\s+(.+)$');
final RegExp _rulePattern = RegExp(r'^(-{3,}|\*{3,}|_{3,})\s*$');
final RegExp _bulletPattern = RegExp(r'^\s*[-*+]\s+(.+)$');
final RegExp _orderedPattern = RegExp(r'^\s*\d+[.)]\s+(.+)$');
final RegExp _quotePattern = RegExp(r'^>?\s?(.*)$');
final RegExp _alignCellPattern = RegExp(r'^:?-+:?$');

/// 切分表格行：`\|` 转义先占位，去掉首尾未转义管道后按 `|` 分列。
/// 不含 `|` 的行返回空列表（裸 `---` 由此不会误判为分隔行）。
List<String> _splitTableRow(String line) {
  var s = line.trim().replaceAll(r'\|', '\x00');
  if (!s.contains('|')) return const [];
  if (s.startsWith('|')) s = s.substring(1);
  if (s.endsWith('|')) s = s.substring(0, s.length - 1);
  return [
    for (final cell in s.split('|')) cell.trim().replaceAll('\x00', '|'),
  ];
}

/// 分隔行（`| --- | :---: | ---: |`）→ 各列对齐；非分隔行返回 null。
List<AiTableAlignment>? _parseTableSeparator(String line) {
  final cells = _splitTableRow(line);
  if (cells.isEmpty) return null;
  final aligns = <AiTableAlignment>[];
  for (final cell in cells) {
    final c = cell.trim();
    if (!_alignCellPattern.hasMatch(c)) return null;
    aligns.add(
      c.startsWith(':') && c.endsWith(':')
          ? AiTableAlignment.center
          : c.endsWith(':')
              ? AiTableAlignment.right
              : AiTableAlignment.left,
    );
  }
  return aligns;
}

/// 解析文本为块列表；未闭合的代码块也会保留。
List<AiBlock> parseAiMarkdown(String text) {
  final blocks = <AiBlock>[];
  final buffer = StringBuffer();
  final lines = text.split('\n');
  var index = 0;

  void flushText() {
    final content = buffer.toString().trimRight();
    buffer.clear();
    if (content.isNotEmpty) blocks.add(AiTextBlock(content));
  }

  while (index < lines.length) {
    final line = lines[index];
    final trimmed = line.trim();

    if (trimmed.startsWith('```')) {
      flushText();
      final language = trimmed.substring(3).trim();
      final code = StringBuffer();
      index++;
      while (index < lines.length && !lines[index].trimLeft().startsWith('```')) {
        code.writeln(lines[index]);
        index++;
      }
      // 跳过收尾的 ```
      if (index < lines.length) index++;
      blocks.add(AiCodeBlock(
        code: code.toString().trimRight(),
        language: language,
      ));
      continue;
    }

    if (trimmed.isEmpty) {
      buffer.writeln(line);
      index++;
      continue;
    }

    final heading = _headingPattern.firstMatch(trimmed);
    if (heading != null) {
      flushText();
      blocks.add(AiHeadingBlock(
        level: heading[1]!.length,
        text: heading[2]!.trim(),
      ));
      index++;
      continue;
    }

    if (_rulePattern.hasMatch(trimmed)) {
      flushText();
      blocks.add(const AiRuleBlock());
      index++;
      continue;
    }

    // 表格：当前行（表头）含 | 且下一行是分隔行（GFM 管道表格）。
    if (trimmed.contains('|') && index + 1 < lines.length) {
      final separator = _parseTableSeparator(lines[index + 1]);
      if (separator != null) {
        flushText();
        final header = _splitTableRow(trimmed);
        // 列数取表头与分隔行的较大者（AI 输出偶有两者不一致）。
        final columnCount =
            header.length > separator.length ? header.length : separator.length;
        while (header.length < columnCount) {
          header.add('');
        }
        final alignments = <AiTableAlignment>[
          for (var i = 0; i < columnCount; i++)
            i < separator.length ? separator[i] : AiTableAlignment.left,
        ];
        index += 2;
        final rows = <List<String>>[];
        while (index < lines.length) {
          final rowLine = lines[index].trim();
          if (rowLine.isEmpty || !rowLine.contains('|')) break;
          final cells = _splitTableRow(rowLine);
          while (cells.length < columnCount) {
            cells.add('');
          }
          rows.add(cells.sublist(0, columnCount));
          index++;
        }
        blocks.add(AiTableBlock(
          header: header,
          rows: rows,
          alignments: alignments,
        ));
        continue;
      }
    }

    final bullet = _bulletPattern.firstMatch(line);
    final ordered = _orderedPattern.firstMatch(line);
    if (bullet != null || ordered != null) {
      flushText();
      final isOrdered = bullet == null;
      final items = <String>[];
      while (index < lines.length) {
        final itemLine = lines[index];
        final b = _bulletPattern.firstMatch(itemLine);
        final o = _orderedPattern.firstMatch(itemLine);
        if (isOrdered ? o == null : b == null) break;
        items.add((isOrdered ? o![1] : b![1])!.trim());
        index++;
      }
      blocks.add(AiListBlock(items: items, ordered: isOrdered));
      continue;
    }

    if (trimmed.startsWith('>')) {
      flushText();
      final quoteLines = <String>[];
      while (index < lines.length && lines[index].trimLeft().startsWith('>')) {
        quoteLines.add(
            _quotePattern.firstMatch(lines[index].trimLeft())![1]!.trimRight());
        index++;
      }
      blocks.add(AiQuoteBlock(quoteLines.join('\n')));
      continue;
    }

    buffer.writeln(line);
    index++;
  }
  flushText();
  return blocks;
}
