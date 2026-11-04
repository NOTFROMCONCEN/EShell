import 'package:eshell/utils/ai_markdown.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseAiMarkdown', () {
    test('纯文本', () {
      final blocks = parseAiMarkdown('结论：缺默认路由。\n请检查网关。');
      expect(blocks, hasLength(1));
      expect(blocks.single, isA<AiTextBlock>());
      expect((blocks.single as AiTextBlock).text, contains('缺默认路由'));
    });

    test('文本 + 代码块 + 文本', () {
      final blocks = parseAiMarkdown(
          '先确认接口：\n```bash\ndisplay interface brief\n```\n再检查路由。');
      expect(blocks, hasLength(3));
      expect(blocks[0], isA<AiTextBlock>());
      final code = blocks[1] as AiCodeBlock;
      expect(code.language, 'bash');
      expect(code.code, 'display interface brief');
      expect((blocks[2] as AiTextBlock).text, contains('路由'));
    });

    test('未闭合代码块也保留', () {
      final blocks = parseAiMarkdown('```\nip route-static 0.0.0.0 0 198.51.100.1');
      expect(blocks, hasLength(1));
      expect((blocks.single as AiCodeBlock).code,
          contains('ip route-static 0.0.0.0 0 198.51.100.1'));
    });

    test('空文本返回空列表', () {
      expect(parseAiMarkdown('   '), isEmpty);
    });

    test('多个代码块', () {
      final blocks = parseAiMarkdown(
          '```\nshow version\n```\n---\n```\nshow run\n```');
      expect(blocks.whereType<AiCodeBlock>().length, 2);
    });

    test('标题按级别解析', () {
      final blocks = parseAiMarkdown('## 排查步骤\n正文\n### 细节');
      expect(blocks, hasLength(3));
      final h2 = blocks[0] as AiHeadingBlock;
      expect(h2.level, 2);
      expect(h2.text, '排查步骤');
      expect(blocks[1], isA<AiTextBlock>());
      expect((blocks[2] as AiHeadingBlock).level, 3);
    });

    test('无序与有序列表各成一个块', () {
      final blocks = parseAiMarkdown('- 第一项\n- 第二项\n\n1. 步骤一\n2. 步骤二');
      expect(blocks, hasLength(2));
      final ul = blocks[0] as AiListBlock;
      expect(ul.ordered, isFalse);
      expect(ul.items, ['第一项', '第二项']);
      final ol = blocks[1] as AiListBlock;
      expect(ol.ordered, isTrue);
      expect(ol.items, ['步骤一', '步骤二']);
    });

    test('引用块合并连续行并去掉 > 前缀', () {
      final blocks = parseAiMarkdown('> 第一行\n> 第二行\n正文');
      expect(blocks, hasLength(2));
      expect((blocks[0] as AiQuoteBlock).text, '第一行\n第二行');
      expect(blocks[1], isA<AiTextBlock>());
    });

    test('分割线识别（--- / ***），不影响粗斜体文本', () {
      final blocks = parseAiMarkdown('---\n***bold italic***\n___');
      expect(blocks[0], isA<AiRuleBlock>());
      expect(blocks[1], isA<AiTextBlock>());
      expect(blocks[2], isA<AiRuleBlock>());
    });
  });

  group('parseAiInline', () {
    test('纯文本', () {
      final spans = parseAiInline('普通内容');
      expect(spans, hasLength(1));
      expect(spans.single.kind, AiInlineKind.text);
      expect(spans.single.text, '普通内容');
    });

    test('粗体 / 斜体 / 粗斜体 / 行内代码', () {
      final spans = parseAiInline('**加粗** 与 *斜体* 与 `code` 与 ***都占***');
      expect(spans.map((s) => s.kind).toList(), [
        AiInlineKind.bold,
        AiInlineKind.text,
        AiInlineKind.italic,
        AiInlineKind.text,
        AiInlineKind.code,
        AiInlineKind.text,
        AiInlineKind.boldItalic,
      ]);
      expect(spans[0].text, '加粗');
      expect(spans[2].text, '斜体');
      expect(spans[4].text, '`code`');
      expect(spans[6].text, '都占');
    });

    test('链接提取文本与地址', () {
      final spans = parseAiInline('见 [文档](https://example.com/a) 说明');
      expect(spans, hasLength(3));
      final link = spans[1];
      expect(link.kind, AiInlineKind.link);
      expect(link.text, '文档');
      expect(link.href, 'https://example.com/a');
    });

    test('未闭合标记按字面保留（流式安全）', () {
      final spans = parseAiInline('正在**加粗中');
      expect(spans.single.kind, AiInlineKind.text);
      expect(spans.single.text, '正在**加粗中');
    });

    test('snake_case 标识符不误判为斜体', () {
      final spans = parseAiInline('字段 reasoning_content 表示思考');
      expect(spans.single.kind, AiInlineKind.text);
    });
  });

// ---- 表格（2026-11-03：AI 排查报告常用 GFM 表格，此前按纯文本渲染）----

group('表格解析', () {
  test('基本表格：表头 + 分隔行 + 数据行', () {
    final blocks = parseAiMarkdown(
        '| 层级 | 关注点 |\n'
        '|---|---|\n'
        '| 物理层 | 端口 up/down、速率双工 |\n'
        '| 链路层 | VLAN、STP 状态 |');
    expect(blocks, hasLength(1));
    final table = blocks.single as AiTableBlock;
    expect(table.header, ['层级', '关注点']);
    expect(table.rows, hasLength(2));
    expect(table.rows[0], ['物理层', '端口 up/down、速率双工']);
    expect(table.rows[1], ['链路层', 'VLAN、STP 状态']);
    expect(table.alignments, everyElement(AiTableAlignment.left));
  });

  test('对齐标记 :--- / :---: / ---:', () {
    final blocks = parseAiMarkdown(
        '| a | b | c |\n|:---|:---:|---:|\n| 1 | 2 | 3 |');
    final table = blocks.single as AiTableBlock;
    expect(table.alignments, [
      AiTableAlignment.left,
      AiTableAlignment.center,
      AiTableAlignment.right,
    ]);
  });

  test('无分隔行不误判为表格（整段按文本保留）', () {
    final blocks = parseAiMarkdown('| a | b |\n| c | d |');
    expect(blocks.single, isA<AiTextBlock>());
  });

  test('裸 --- 不误判为单列分隔行', () {
    final blocks = parseAiMarkdown('上文\n---\n下文');
    expect(blocks.whereType<AiTableBlock>(), isEmpty);
  });

  test(r'单元格内 \| 转义不切列', () {
    final blocks = parseAiMarkdown(
        r'| 命令 | 说明 |' '\n' r'|---|---|' '\n' r'| a \| b | 注释 |');
    final table = blocks.single as AiTableBlock;
    expect(table.rows[0], ['a | b', '注释']);
  });

  test('流式中途：分隔行已到、数据行未到也成表', () {
    final blocks = parseAiMarkdown('| 层级 | 关注点 |\n|---|---|');
    final table = blocks.single as AiTableBlock;
    expect(table.header, ['层级', '关注点']);
    expect(table.rows, isEmpty);
  });

  test('流式中途：最后半行也收进表格', () {
    final blocks = parseAiMarkdown(
        '| 层级 | 关注点 |\n|---|---|\n| 物理层 | 端口 up');
    final table = blocks.single as AiTableBlock;
    expect(table.rows.single, ['物理层', '端口 up']);
  });

  test('数据行列数不齐：缺列补空、多列截断', () {
    final blocks = parseAiMarkdown(
        '| a | b | c |\n|---|---|---|\n| 1 |\n| 1 | 2 | 3 | 4 |');
    final table = blocks.single as AiTableBlock;
    expect(table.rows[0], ['1', '', '']);
    expect(table.rows[1], ['1', '2', '3']);
  });

  test('表头与分隔行列数不一致时取较大者', () {
    final blocks = parseAiMarkdown('| a | b |\n|---|---|---|\n| 1 | 2 | 3 |');
    final table = blocks.single as AiTableBlock;
    expect(table.header, ['a', 'b', '']);
    expect(table.rows.single, ['1', '2', '3']);
  });

  test('表格前后的段落各自成块', () {
    final blocks = parseAiMarkdown(
        '结论如下：\n| a | b |\n|---|---|\n| 1 | 2 |\n\n补充说明。');
    expect(blocks, hasLength(3));
    expect(blocks[0], isA<AiTextBlock>());
    expect(blocks[1], isA<AiTableBlock>());
    expect(blocks[2], isA<AiTextBlock>());
  });

  test('数据行遇空行或非管道行结束', () {
    final blocks = parseAiMarkdown(
        '| a | b |\n|---|---|\n| 1 | 2 |\n\n- 列表项');
    expect(blocks, hasLength(2));
    final table = blocks[0] as AiTableBlock;
    expect(table.rows, hasLength(1));
    expect(blocks[1], isA<AiListBlock>());
  });
});
}
