import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_tv_app/widgets/net_image.dart';

/// 用 TV 版 main.dart 相同的设计尺寸初始化 ScreenUtil，否则 `.w` 无法取值。
Widget _wrap(Widget child) {
  return ScreenUtilInit(
    designSize: const Size(1920, 1080),
    builder: (context, _) => MaterialApp(home: Scaffold(body: child)),
  );
}

void main() {
  group('NetImage.resolveDecodeEdge', () {
    test('尺寸不可用时返回 null（不限制解码分辨率）', () {
      expect(NetImage.resolveDecodeEdge(null, null, 3), isNull);
      expect(NetImage.resolveDecodeEdge(0, 0, 3), isNull);
      expect(NetImage.resolveDecodeEdge(double.infinity, 100, 3), 320);
      expect(NetImage.resolveDecodeEdge(100, double.infinity, 3), 320);
    });

    test('小尺寸按渲染物理像素量化到 32 的整数倍', () {
      // 100 逻辑像素 @3x = 300 物理像素，向上取整到 320
      expect(NetImage.resolveDecodeEdge(100, 100, 3), 320);
      // 48 逻辑像素 @1x = 48 物理像素，向上取整到 64
      expect(NetImage.resolveDecodeEdge(48, 48, 1), 64);
    });

    test('超过单边上限时截断到 1080', () {
      expect(NetImage.resolveDecodeEdge(1920, 1080, 1), 1080);
      expect(NetImage.resolveDecodeEdge(800, 450, 2), 1080);
    });

    test('只按较长边计算，短边不参与', () {
      // 较长边 800 @1x 落入量化区间
      expect(NetImage.resolveDecodeEdge(800, 100, 1), 800);
    });
  });

  testWidgets('NetImage 地址为空时回退到本地占位图', (WidgetTester tester) async {
    await tester.pumpWidget(_wrap(const NetImage('')));

    expect(find.byType(NetImage), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
  });
}
