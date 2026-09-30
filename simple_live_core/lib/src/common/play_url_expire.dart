/// 绝对 Unix 秒与相对剩余秒数的分界值（一天的秒数）。
///
/// 同一个字段名在不同平台语义不同，判语义只能看数值大小：相对剩余秒数不可能
/// 超过一天，超过这个数值的只可能是绝对过期时刻。
const int _absoluteExpireThresholdSeconds = 86400;

/// 从播放地址中解析「还剩多少秒过期」，无法解析或已经过期时返回 null。
///
/// 各平台语义不同：斗鱼给相对剩余秒数，虎牙用十六进制的 wsTime 表示绝对过期
/// 时刻，B站/抖音给绝对 Unix 秒。绝对时刻不换算成剩余秒数，会算出一个远超
/// Timer 上限的延时，主动刷新永远不会发生；已经过期的地址则返回 null。
///
/// 放在顶层而不是某个站点类里，是因为这条规则被 App 与 TV 端共用：写两份拷贝
/// 时平台规则一改就要改两处，而漏改一端只会表现为「偶发不刷新地址」，很难发现。
int? parsePlayUrlExpireSeconds(String? url) {
  if (url == null) {
    return null;
  }
  // 斗鱼等平台用十进制的 expire，虎牙用十六进制的 wsTime
  final decimalMatch = RegExp(r"[?&]expire=(\d+)").firstMatch(url);
  final hexMatch = RegExp(r"[?&]wsTime=([0-9a-fA-F]+)").firstMatch(url);
  // expire 优先：地址同时带两者时按平台惯例取 expire
  final expire = decimalMatch != null
      ? int.tryParse(decimalMatch.group(1) ?? "")
      : int.tryParse(hexMatch?.group(1) ?? "", radix: 16);
  if (expire == null) {
    return null;
  }
  final nowSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  // 超过一天只能是绝对过期时刻，换算后才是剩余秒数
  final remainingSeconds = expire > _absoluteExpireThresholdSeconds
      ? expire - nowSeconds
      : expire;
  // 已经过期时返回 null，交给恢复链，避免安排一个立即触发的刷新
  return remainingSeconds > 0 ? remainingSeconds : null;
}
