import 'package:jsf/jsf.dart';

/// 测试机没有打包原生库时需要 JSF_LIBRARY_PATH；缺失就明确跳过，不静默当通过。
bool jsfAvailable() {
  try {
    JsRuntime().dispose();
    return true;
  } on Object {
    return false;
  }
}

const String jsfSkipReason = '缺少 libjsf 原生库：设置 JSF_LIBRARY_PATH 后重跑';
