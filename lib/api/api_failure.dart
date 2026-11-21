/// 服务端拒绝或响应解析失败。继承 FormatException，调度器会直接展示 message。
class ApiFailure extends FormatException {
  ApiFailure(super.message, {this.status, this.fromHttpResponse = false, this.remoteTerminal = false});

  final bool remoteTerminal;

  final int? status;

  /// 仅当响应状态码非 2xx 时为 true，可用于判断是否允许在生成前兼容重试。
  final bool fromHttpResponse;
}
