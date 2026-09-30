import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/services/cache_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group("CacheService.formatBytes", () {
    final service = CacheService();

    test("缓存为空时显示 0 KB", () {
      expect(service.formatBytes(0), "0 KB");
    });

    test("不足 1MB 时以 KB 为单位", () {
      expect(service.formatBytes(2048), "2 KB");
    });

    test("达到 1MB 时切换为 MB 单位", () {
      expect(service.formatBytes(1024 * 1024), "1.0 MB");
    });

    test("非整数 MB 保留一位小数", () {
      expect(service.formatBytes(1024 * 1024 * 3 ~/ 2), "1.5 MB");
    });
  });

  group("CacheCleanResult.releasedBytes", () {
    test("返回清理前后的差值", () {
      const result = CacheCleanResult(beforeBytes: 1000, afterBytes: 400);
      expect(result.releasedBytes, 600);
    });

    test("没有可清理内容时为零", () {
      const result = CacheCleanResult(beforeBytes: 800, afterBytes: 800);
      expect(result.releasedBytes, 0);
    });
  });
}
