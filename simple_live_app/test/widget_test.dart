import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/widgets/net_image.dart';

void main() {
  testWidgets('NetImage 地址为空时回退到本地占位图', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: NetImage(''),
        ),
      ),
    );

    expect(find.byType(NetImage), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('NetImage 支持固定尺寸与圆角参数', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: NetImage('', width: 48, height: 48, borderRadius: 24),
        ),
      ),
    );

    expect(find.byType(NetImage), findsOneWidget);
  });
}
