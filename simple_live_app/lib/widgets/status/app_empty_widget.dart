import 'package:flutter/material.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:lottie/lottie.dart';

class AppEmptyWidget extends StatelessWidget {
  final Function()? onRefresh;

  /// 空态文案；列表搜索无结果等场景需要比默认文案更具体的提示
  final String text;
  const AppEmptyWidget({
    this.onRefresh,
    this.text = "这里什么都没有",
    Key? key,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Center(
      child: GestureDetector(
        onTap: () {
          onRefresh?.call();
        },
        child: Padding(
          padding: AppStyle.edgeInsetsA12,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LottieBuilder.asset(
                'assets/lotties/empty.json',
                width: 200,
                height: 200,
                repeat: false,
              ),
              Text(
                text,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
