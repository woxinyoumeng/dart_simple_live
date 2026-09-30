import 'dart:async';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';
import 'package:logger/logger.dart';
import 'package:path_provider/path_provider.dart';
import 'package:simple_live_app/app/utils.dart';

class Log {
  static LogFileWriter? logFileWriter;
  static void initWriter() {
    logFileWriter = LogFileWriter();
  }

  static void disposeWriter() {
    logFileWriter?.close();
    logFileWriter = null;
  }

  static void writeLog(content, [Level level = Level.info]) {
    logFileWriter?.write(
      "[${level.name.toUpperCase()}] $_currentTime：$content",
    );
  }

  /// 播放诊断日志的文件名，与 LogFileWriter 同放在 log 目录下。
  static const String _diagnoseFileName = "playback-diagnose.log";

  /// 播放诊断日志的体积上限，超过后先清空再写，避免无限增长。
  static const int _diagnoseMaxBytes = 256 * 1024;

  /// 写入播放诊断日志。
  ///
  /// 与 writeLog 不同，这条通道不受「日志开关」设置影响：播放中断发生在用户
  /// 未开日志时，此时若没有现场证据就无法定位根因。文件位于 log 目录下的
  /// playback-diagnose.log，CacheService 清理日志时会一并删除。
  static void writeDiagnose(String content) {
    // 不阻塞调用方：诊断只是取证，失败也不应影响播放恢复流程
    unawaited(_appendDiagnose(content));
  }

  /// 追加写入诊断日志，超过上限时先清空旧内容。
  static Future<void> _appendDiagnose(String content) async {
    try {
      final logDir = Directory(
        "${(await getApplicationSupportDirectory()).path}/log",
      );
      if (!await logDir.exists()) {
        await logDir.create();
      }
      final file = File("${logDir.path}/$_diagnoseFileName");
      if (await file.exists() && await file.length() > _diagnoseMaxBytes) {
        await file.writeAsString("");
      }
      await file.writeAsString(
        "[$_currentTime] $content\n",
        mode: FileMode.append,
      );
    } catch (e) {
      Log.w("写入播放诊断日志失败：$e");
    }
  }

  static RxList<DebugLogModel> debugLogs = <DebugLogModel>[].obs;

  static void addDebugLog(String content, Color? color) {
    if (kReleaseMode) {
      return;
    }
    if (content.contains("请求响应")) {
      content = content.split("\n").join('\n💡 ');
    }
    try {
      debugLogs.insert(0, DebugLogModel(DateTime.now(), content, color: color));
    } catch (e) {
      if (kDebugMode) {
        print(e);
      }
    }
  }

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

  static void d(String message, [bool writeFile = true]) {
    addDebugLog(message, Colors.orange);
    logger.d("${DateTime.now().toString()}\n$message");
    if (writeFile) {
      writeLog(message, Level.debug);
    }
  }

  static void i(String message, [bool writeFile = true]) {
    addDebugLog(message, Colors.blue);
    logger.i("${DateTime.now().toString()}\n$message");
    if (writeFile) {
      writeLog(message, Level.info);
    }
  }

  static void e(
    String message,
    StackTrace stackTrace, [
    bool writeFile = true,
  ]) {
    addDebugLog('$message\r\n\r\n$stackTrace', Colors.red);
    logger.e("${DateTime.now().toString()}\n$message", stackTrace: stackTrace);
    if (writeFile) {
      writeLog("$message\n$stackTrace", Level.error);
    }
  }

  static void w(String message, [bool writeFile = true]) {
    addDebugLog(message, Colors.pink);
    logger.w("${DateTime.now().toString()}\n$message");
    if (writeFile) {
      writeLog(message, Level.warning);
    }
  }

  static void logPrint(dynamic obj, [bool writeFile = true]) {
    addDebugLog(obj.toString(), Colors.red);
    if (writeFile) {
      writeLog(obj, Level.info);
    }
    //logger.e(obj.toString(), obj, obj?.stackTrace);
    if (kDebugMode) {
      print(obj);
    }
  }

  static String get _currentTime => Utils.timeFormat.format(DateTime.now());
}

class LogFileWriter {
  late String fileName;
  LogFileWriter() {
    var dt = DateFormat("yyyy-MM-dd HH-mm-ss").format(DateTime.now());
    fileName = "$dt.log";
    initFile();
  }
  IOSink? fileWriter;
  void initFile() async {
    var supportDir = await getApplicationSupportDirectory();
    var logDir = Directory("${supportDir.path}/log");
    if (!await logDir.exists()) {
      await logDir.create();
    }
    var logFile = File("${logDir.path}/$fileName");
    fileWriter = logFile.openWrite(mode: FileMode.append);
    writeSystemInfo();
  }

  void write(String content) {
    fileWriter?.write(content);
    fileWriter?.write("\r\n");
  }

  Future close() async {
    await fileWriter?.close();
  }

  void writeSystemInfo() async {
    DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();
    write("System Info:");
    write("Current Time: ${DateTime.now()}");
    write("Platform: ${Platform.operatingSystem}");
    write("Version: ${Platform.operatingSystemVersion}");
    write("Local: ${Platform.localeName}");
    write(
      "App Version: ${Utils.packageInfo.version}+${Utils.packageInfo.buildNumber}",
    );
    if (Platform.isAndroid) {
      write((await deviceInfo.androidInfo).data.toString());
    } else if (Platform.isIOS) {
      write((await deviceInfo.iosInfo).data.toString());
    } else if (Platform.isLinux) {
      write((await deviceInfo.linuxInfo).data.toString());
    } else if (Platform.isMacOS) {
      write((await deviceInfo.macOsInfo).data.toString());
    } else if (Platform.isWindows) {
      write((await deviceInfo.windowsInfo).data.toString());
    }
    write("End System Info");
  }
}

class DebugLogModel {
  final String content;
  final DateTime datetime;
  final Color? color;
  DebugLogModel(this.datetime, this.content, {this.color});
}
