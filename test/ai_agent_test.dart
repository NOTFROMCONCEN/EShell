import 'package:eshell/services/ai_agent.dart';
import 'package:eshell/services/telnet_scanner.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('extractRunCommand', () {
    test('提取 ```run 块内容', () {
      const content = '先看版本：\n\n```run\ndisplay version\n```\n';
      expect(extractRunCommand(content), 'display version');
    });

    test('多个 run 块取最后一个', () {
      const content = '```run\nfirst\n```\n说明\n```run\nsecond\n```';
      expect(extractRunCommand(content), 'second');
    });

    test('run 块优先于后面的普通 shell 块（显式协议优先）', () {
      const content = '```run\nfirst\n```\n说明\n```bash\nls -la\n```';
      expect(extractRunCommand(content), 'first');
    });

    test('模型不守协议时回退到最后一个 shell 类代码块', () {
      const content = '采集计划：\n\n```bash\ndf -hT\n```\n预期输出：挂载点用量。';
      expect(extractRunCommand(content), 'df -hT');
    });

    test('无语言标签的裸代码块同样回退', () {
      const content = '```\ndisplay clock\n```';
      expect(extractRunCommand(content), 'display clock');
    });

    test('非 shell 语言（python 等）不回退，返回 null', () {
      const content = '```python\nprint(1)\n```';
      expect(extractRunCommand(content), isNull);
    });

    test('空内容返回 null', () {
      expect(extractRunCommand(''), isNull);
    });

    test('大小写不敏感识别语言标签', () {
      expect(extractRunCommand('```RUN\ncmd\n```'), 'cmd');
    });
  });

  group('classifyAgentCommand · 安全分级', () {
    test('查看类命令自动执行', () {
      expect(classifyAgentCommand('df -hT'), AgentCommandVerdict.auto);
      expect(classifyAgentCommand('display version'),
          AgentCommandVerdict.auto);
      expect(classifyAgentCommand('systemctl --failed --no-pager'),
          AgentCommandVerdict.auto);
      expect(classifyAgentCommand('journalctl -p err'),
          AgentCommandVerdict.auto);
      expect(classifyAgentCommand('sudo lspci -vv'), AgentCommandVerdict.auto);
      expect(classifyAgentCommand('sudo btrfs filesystem usage /'),
          AgentCommandVerdict.auto);
      expect(classifyAgentCommand('show interfaces status'),
          AgentCommandVerdict.auto);
    });

    test('复合命令逐段检查（自动）', () {
      expect(
          classifyAgentCommand(
              'systemctl --failed --no-pager; journalctl -p err'),
          AgentCommandVerdict.auto);
    });

    test('配置变更/删除类需要确认', () {
      expect(classifyAgentCommand('no shutdown'), AgentCommandVerdict.confirm);
      expect(classifyAgentCommand('undo port-security enable'),
          AgentCommandVerdict.confirm);
      expect(classifyAgentCommand('rm file.txt'), AgentCommandVerdict.confirm);
      expect(classifyAgentCommand('systemctl restart nginx'),
          AgentCommandVerdict.confirm);
      expect(classifyAgentCommand('int g0/0\nshutdown'),
          AgentCommandVerdict.confirm);
      expect(
          classifyAgentCommand(
              'copy running-config startup-config'),
          AgentCommandVerdict.confirm);
    });

    test('危险命令永不自动执行', () {
      expect(classifyAgentCommand('reload'), AgentCommandVerdict.blocked);
      expect(classifyAgentCommand('reboot'), AgentCommandVerdict.blocked);
      expect(classifyAgentCommand('undo all'), AgentCommandVerdict.blocked);
      expect(classifyAgentCommand('write erase'), AgentCommandVerdict.blocked);
      expect(classifyAgentCommand('rm -rf /'), AgentCommandVerdict.blocked);
      expect(classifyAgentCommand('dd if=/dev/zero of=/dev/sda'),
          AgentCommandVerdict.blocked);
      expect(classifyAgentCommand('mkfs.ext4 /dev/sdb1'),
          AgentCommandVerdict.blocked);
    });

    test('多行命令取最严重级别', () {
      expect(classifyAgentCommand('df -hT\nreload'),
          AgentCommandVerdict.blocked);
      expect(classifyAgentCommand('df -hT\nrm file.txt'),
          AgentCommandVerdict.confirm);
    });

    test('大小写不影响判定', () {
      expect(classifyAgentCommand('REBOOT'), AgentCommandVerdict.blocked);
      expect(classifyAgentCommand('No Shutdown'), AgentCommandVerdict.confirm);
    });

    test('管道/串联命令的任何一段命中即升级', () {
      expect(classifyAgentCommand('df -hT && rm -rf /'),
          AgentCommandVerdict.blocked);
    });
  });

  group('agentMaxSteps', () {
    test('步数上限为 12，防止失控循环', () {
      expect(agentMaxSteps, 12);
    });
  });

  group('Telnet 扫描能力（```scan）', () {
    test('提取 scan 块并解析 JSON', () {
      const content =
          '先扫描控制台端口：\n\n```scan\n{"host":"127.0.0.1","startPort":32768,"endPort":32800}\n```';
      final raw = extractScanBlock(content);
      expect(raw, isNotNull);
      final request = parseScanRequest(raw!);
      expect(request.host, '127.0.0.1');
      expect(request.startPort, 32768);
      expect(request.endPort, 32800);
      expect(request.label, '127.0.0.1:32768-32800');
    });

    test('无 scan 块返回 null；run 块不算扫描', () {
      expect(extractScanBlock('```run\ndf -hT\n```'), isNull);
    });

    test('缺省 host 回退 127.0.0.1', () {
      final request = parseScanRequest('{"startPort":1,"endPort":10}');
      expect(request.host, '127.0.0.1');
    });

    test('非法 JSON / 端口越界 / 区间过大报错', () {
      expect(() => parseScanRequest('not-json'), throwsFormatException);
      expect(() => parseScanRequest('{"startPort":"1","endPort":10}'),
          throwsFormatException);
      expect(() => parseScanRequest('{"startPort":1,"endPort":70000}'),
          throwsFormatException);
      expect(() => parseScanRequest('{"startPort":10,"endPort":1}'),
          throwsFormatException);
      expect(() => parseScanRequest('{"startPort":1,"endPort":60000}'),
          throwsFormatException);
    });

    test('本机地址判定（远程需确认）', () {
      expect(isLocalScanHost('127.0.0.1'), isTrue);
      expect(isLocalScanHost('localhost'), isTrue);
      expect(isLocalScanHost('::1'), isTrue);
      expect(isLocalScanHost('192.168.1.1'), isFalse);
    });

    test('扫描摘要格式化', () {
      final summary = formatScanSummary(const [
        TelnetScanResult(port: 32769, kind: TelnetProbeKind.telnet),
        TelnetScanResult(
            port: 32770, kind: TelnetProbeKind.console, banner: 'Switch#'),
        TelnetScanResult(port: 32771, kind: TelnetProbeKind.silent),
        TelnetScanResult(port: 32772, kind: TelnetProbeKind.nonTelnet),
      ]);
      expect(summary, contains('32769 → telnet'));
      expect(summary, contains('32770 → console｜Switch#'));
      expect(summary, contains('32771 → silent'));
      expect(summary, contains('32772 → nonTelnet'));
      expect(formatScanSummary(const []), contains('未发现'));
    });
  });
}

