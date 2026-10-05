import 'dart:io';

import 'package:extended_image/extended_image.dart';
import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';
import 'package:simple_live_tv_app/app/log.dart';

/// 缓存清理结果，用于向用户反馈实际释放的空间。
class CacheCleanResult {
  /// 清理前的缓存占用（字节）
  final int beforeBytes;

  /// 清理后的缓存占用（字节）
  final int afterBytes;

  const CacheCleanResult({required this.beforeBytes, required this.afterBytes});

  /// 本次释放的字节数
  int get releasedBytes => beforeBytes - afterBytes;
}

/// 缓存管理。
///
/// 只清理可再生的数据：网络图片磁盘缓存、图片解码内存缓存、运行日志。
/// 关注列表、历史记录等用户数据不在此列。
class CacheService extends GetxService {
  static CacheService get instance => Get.find<CacheService>();

  /// 日志目录名。TV 端目前日志只写内存，此处保留与桌面版一致的位置约定，
  /// 后续若接入日志落盘无需再改这里。
  static const String _logDirectoryName = 'log';

  /// 日志文件后缀，仅清理该后缀的文件，避免误删同目录下的其他文件
  static const String _logFileSuffix = '.log';

  /// 1KB 对应的字节数
  static const int _bytesPerKilobyte = 1024;

  /// 1MB 对应的字节数
  static const int _bytesPerMegabyte = _bytesPerKilobyte * 1024;

  /// 统计当前缓存占用（字节）
  Future<int> currentBytes() async {
    final imageBytes = await _directoryBytes(await _imageCacheDirectoryPath());
    final logBytes = await _directoryBytes(await _logDirectoryPath());
    return imageBytes + logBytes;
  }

  /// 清理全部缓存，返回清理前后的占用情况
  Future<CacheCleanResult> clean() async {
    final beforeBytes = await currentBytes();
    await _clearImageCache();
    await _clearLogs();
    final afterBytes = await currentBytes();
    Log.i("缓存清理完成：${_toMegabytes(beforeBytes)} -> ${_toMegabytes(afterBytes)}");
    return CacheCleanResult(beforeBytes: beforeBytes, afterBytes: afterBytes);
  }

  /// 把字节数格式化成便于阅读的文本
  String formatBytes(int bytes) {
    if (bytes < _bytesPerMegabyte) {
      return "${(bytes / _bytesPerKilobyte).toStringAsFixed(0)} KB";
    }
    return "${(bytes / _bytesPerMegabyte).toStringAsFixed(1)} MB";
  }

  /// 清理图片缓存。
  ///
  /// 内存与磁盘都要清：只清磁盘的话，已解码的位图仍会继续占用大量内存，
  /// 而直播封面原图单张解码后可达数 MB。
  Future<void> _clearImageCache() async {
    clearMemoryImageCache();
    try {
      await clearDiskCachedImages();
    } catch (e) {
      // 单项失败不阻断整体清理，但必须留痕以便排查
      Log.w("清理图片磁盘缓存失败：$e");
    }
  }

  /// 清理运行日志文件。
  ///
  /// 逐个删除文件而不是整个目录：日志开关开启时文件正被写入，
  /// 删除整个目录会让后续写入落到已失效的路径上。
  Future<void> _clearLogs() async {
    final directory = Directory(await _logDirectoryPath());
    if (!await directory.exists()) {
      return;
    }
    try {
      await for (final entity in directory.list()) {
        if (entity is File && entity.path.endsWith(_logFileSuffix)) {
          await entity.delete();
        }
      }
    } catch (e) {
      Log.w("清理日志缓存失败：$e");
    }
  }

  /// 图片磁盘缓存目录，与 extended_image 的约定保持一致
  Future<String> _imageCacheDirectoryPath() async {
    return "${(await getTemporaryDirectory()).path}/$cacheImageFolderName";
  }

  /// 日志目录，与日志落盘位置保持一致
  Future<String> _logDirectoryPath() async {
    return "${(await getApplicationSupportDirectory()).path}/$_logDirectoryName";
  }

  /// 递归统计目录占用字节数
  Future<int> _directoryBytes(String directoryPath) async {
    final directory = Directory(directoryPath);
    if (!await directory.exists()) {
      return 0;
    }
    var total = 0;
    try {
      await for (final entity in directory.list(recursive: true)) {
        if (entity is File) {
          total += await entity.length();
        }
      }
    } catch (e) {
      // 目录可能正在被写入或刚被删除，统计失败时按已累计部分返回
      Log.w("统计缓存目录 $directoryPath 占用失败：$e");
    }
    return total;
  }

  String _toMegabytes(int bytes) =>
      "${(bytes / _bytesPerMegabyte).toStringAsFixed(1)}MB";
}
