/// 终端会话配置模型（SSH 或串口）。
///
/// 不可变模型（M3）：所有字段 final，跨处共享同一实例不会被就地改写；
/// 变更一律通过 [copyWith] 生成新实例后走 `AppState.upsert` 替换。
///
/// 串口会话的字段复用约定（serial）：
/// - `host` = 串口名（如 COM3）
/// - `port` = 波特率（如 9600）；`autoBaud` 为 true 时作为探测失败兜底值
/// - `username` / 认证字段不使用（保存时清空）
enum SessionTransport { ssh, serial }

/// SSH 认证方式（仅 transport = ssh 时有效）。
enum SshAuthType { password, publicKey }

class Session {
  Session({
    required this.id,
    required this.name,
    required this.host,
    this.port = 22,
    this.transport = SessionTransport.ssh,
    this.autoBaud = false,
    required this.username,
    this.authType = SshAuthType.password,
    this.password,
    this.passphrase,
    this.privateKeyPath,
    this.tag,
    this.lastConnectedAt,
    this.isTemporary = false,
  });

  static const Object _unset = Object();

  final String id;
  final String name;
  final String host;

  /// SSH：端口号；串口：波特率。
  final int port;

  final SessionTransport transport;

  /// 串口自动探测波特率（port 字段作为探测失败时的兜底值）。
  final bool autoBaud;
  final String username;
  final SshAuthType authType;

  /// 密码认证的口令；或（历史数据中）私钥口令的兜底来源。
  final String? password;

  /// 私钥口令（S4：不再与登录密码共用字段）。
  final String? passphrase;
  final String? privateKeyPath;
  final String? tag;
  final DateTime? lastConnectedAt;

  /// 临时会话（快速连接，不落盘）。
  final bool isTemporary;

  String get displayName {
    if (name.isNotEmpty) return name;
    return transport == SessionTransport.serial ? host : '$username@$host';
  }

  String get address => transport == SessionTransport.serial
      ? (autoBaud ? '$host · 自动波特率' : '$host · $port bps')
      : '$username@$host:$port';

  /// 生成副本。需要把字段清空为 null 时显式传 `null`；
  /// 不传（保持默认哨兵值）则沿用原值。
  Session copyWith({
    Object? id = _unset,
    Object? name = _unset,
    Object? host = _unset,
    Object? port = _unset,
    Object? transport = _unset,
    Object? autoBaud = _unset,
    Object? username = _unset,
    Object? authType = _unset,
    Object? password = _unset,
    Object? passphrase = _unset,
    Object? privateKeyPath = _unset,
    Object? tag = _unset,
    Object? lastConnectedAt = _unset,
    Object? isTemporary = _unset,
  }) =>
      Session(
        id: id == _unset ? this.id : id as String,
        name: name == _unset ? this.name : name as String,
        host: host == _unset ? this.host : host as String,
        port: port == _unset ? this.port : port as int,
        transport: transport == _unset
            ? this.transport
            : transport as SessionTransport,
        autoBaud: autoBaud == _unset ? this.autoBaud : autoBaud as bool,
        username:
            username == _unset ? this.username : username as String,
        authType:
            authType == _unset ? this.authType : authType as SshAuthType,
        password:
            password == _unset ? this.password : password as String?,
        passphrase:
            passphrase == _unset ? this.passphrase : passphrase as String?,
        privateKeyPath: privateKeyPath == _unset
            ? this.privateKeyPath
            : privateKeyPath as String?,
        tag: tag == _unset ? this.tag : tag as String?,
        lastConnectedAt: lastConnectedAt == _unset
            ? this.lastConnectedAt
            : lastConnectedAt as DateTime?,
        isTemporary:
            isTemporary == _unset ? this.isTemporary : isTemporary as bool,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'host': host,
        'port': port,
        'transport': transport.name,
        if (autoBaud) 'autoBaud': true,
        'username': username,
        'authType': authType.name,
        'password': password,
        'passphrase': passphrase,
        'privateKeyPath': privateKeyPath,
        'tag': tag,
        'lastConnectedAt': lastConnectedAt?.toIso8601String(),
      };

  factory Session.fromJson(Map<String, dynamic> json) => Session(
        id: json['id'] as String,
        name: (json['name'] ?? '') as String,
        host: (json['host'] ?? '') as String,
        port: json['port'] is num ? (json['port'] as num).toInt() : 22,
        transport: json['transport'] == 'serial'
            ? SessionTransport.serial
            : SessionTransport.ssh,
        autoBaud: json['autoBaud'] == true,
        username: (json['username'] ?? 'root') as String,
        authType: json['authType'] == 'publicKey'
            ? SshAuthType.publicKey
            : SshAuthType.password,
        password: json['password'] as String?,
        passphrase: json['passphrase'] as String?,
        privateKeyPath: json['privateKeyPath'] as String?,
        tag: json['tag'] as String?,
        lastConnectedAt: json['lastConnectedAt'] == null
            ? null
            : DateTime.parse(json['lastConnectedAt'] as String),
      );
}
