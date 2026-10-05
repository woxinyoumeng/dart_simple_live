import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:logger/logger.dart';

class Log {
  static RxList<DebugLogModel> debugLogs = <DebugLogModel>[].obs;

  /// 应用内保留的日志条数上限。
  ///
  /// TV 端通常接不上 adb，日志只能靠在电视上打开「运行日志」页来看；而直播
  /// 播放期间每 5 秒就会产生若干条采样日志，不设上限会无界增长。
  static const int _maxRetainedLogs = 200;

  static Logger logger = Logger(
    printer: PrettyPrinter(
      methodCount: 0,
      errorMethodCount: 8,
      lineLength: 120,
      colors: true,
      printEmojis: true,
      dateTimeFormat: DateTimeFormat.none,
    ),
  );

  /// 调试级别日志的展示颜色
  static const Color _debugColor = Colors.white70;

  /// 普通信息级别日志的展示颜色
  static const Color _infoColor = Colors.lightBlueAccent;

  /// 警告级别日志的展示颜色
  static const Color _warningColor = Colors.amber;

  /// 错误级别日志的展示颜色
  static const Color _errorColor = Colors.redAccent;

  static void d(String message) {
    _retain(message, _debugColor);
    logger.d("${DateTime.now().toString()}\n$message");
  }

  static void i(String message) {
    _retain(message, _infoColor);
    logger.i("${DateTime.now().toString()}\n$message");
  }

  static void e(String message, StackTrace stackTrace) {
    _retain(message, _errorColor);
    logger.e("${DateTime.now().toString()}\n$message", stackTrace: stackTrace);
  }

  static void w(String message) {
    _retain(message, _warningColor);
    logger.w("${DateTime.now().toString()}\n$message");
  }

  static void logPrint(dynamic obj) {
    //logger.e(obj.toString(), obj, obj?.stackTrace);
    if (kDebugMode) {
      print(obj);
    }
  }

  /// 把日志留在内存里，供应用内「运行日志」页查看。
  ///
  /// 只保留最近 [_maxRetainedLogs] 条：排查关心的是「刚刚发生了什么」，
  /// 更早的日志既翻不到，留着也只是白占内存。
  static void _retain(String message, Color color) {
    debugLogs.add(DebugLogModel(DateTime.now(), message, color: color));
    final overflow = debugLogs.length - _maxRetainedLogs;
    if (overflow > 0) {
      debugLogs.removeRange(0, overflow);
    }
  }
}

class DebugLogModel {
  final String content;
  final DateTime datetime;
  final Color? color;
  DebugLogModel(this.datetime, this.content, {this.color});
}
