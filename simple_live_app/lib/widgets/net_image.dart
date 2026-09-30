import 'dart:math' as math;

import 'package:extended_image/extended_image.dart';
import 'package:flutter/material.dart';

/// 网络图片。
///
/// 会按实际渲染尺寸约束解码分辨率：直播封面原图常见 1280x720 与 1920x1080，
/// 不做限制时单张解码后约占 3.7~8.3MB 内存，而列表卡片只需几十 KB，
/// 滚动列表会迅速撑满图片缓存，触发反复驱逐与重新解码。
class NetImage extends StatelessWidget {
  /// 单边解码上限（像素）。已覆盖 Retina 屏全屏网格的显示需求，再高无收益。
  static const int _maxDecodeEdge = 1080;

  /// 解码边长量化步长，避免容器尺寸微调时反复重新解码。
  static const int _decodeEdgeStep = 32;

  final String picUrl;
  final double? width;
  final double? height;
  final BoxFit? fit;
  final double borderRadius;
  const NetImage(
    this.picUrl, {
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.borderRadius = 0,
    Key? key,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    if (picUrl.isEmpty) {
      return Image.asset(
        'assets/images/logo.png',
        width: width,
        height: height,
      );
    }
    var pic = picUrl;
    if (pic.startsWith("//")) {
      pic = 'https:$pic';
    }
    // 显式尺寸已知时直接计算，省掉一次布局回调
    if (_hasFixedSize) {
      return _buildImage(context, pic, width, height);
    }
    // 尺寸由父级约束决定（如网格卡片），从布局约束取实际渲染尺寸
    return LayoutBuilder(
      builder: (context, constraints) => _buildImage(
        context,
        pic,
        constraints.hasBoundedWidth ? constraints.maxWidth : null,
        constraints.hasBoundedHeight ? constraints.maxHeight : null,
      ),
    );
  }

  /// 是否已给出可用的显式尺寸。
  ///
  /// [width] / [height] 为 [double.infinity] 表示由父级决定，须走布局约束分支。
  bool get _hasFixedSize =>
      _usableSize(width) != null && _usableSize(height) != null;

  /// 构建图片，并按实际渲染尺寸限制解码分辨率。
  Widget _buildImage(
    BuildContext context,
    String pic,
    double? layoutWidth,
    double? layoutHeight,
  ) {
    final decodeEdge = _resolveDecodeEdge(
      layoutWidth,
      layoutHeight,
      MediaQuery.of(context).devicePixelRatio,
    );
    // 只约束较长的一边：同时传入 width 与 height 会把图片拉伸到该尺寸
    final constrainWidth =
        decodeEdge != null && (layoutWidth ?? 0) >= (layoutHeight ?? 0);
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: ExtendedImage.network(
        pic,
        fit: fit,
        height: height,
        width: width,
        shape: BoxShape.rectangle,
        borderRadius: BorderRadius.circular(borderRadius),
        cacheWidth: constrainWidth ? decodeEdge : null,
        cacheHeight: constrainWidth ? null : decodeEdge,
        loadStateChanged: (e) {
          if (e.extendedImageLoadState == LoadState.loading) {
            return const Icon(Icons.image, color: Colors.grey, size: 24);
          }
          if (e.extendedImageLoadState == LoadState.failed) {
            return const Icon(Icons.broken_image, color: Colors.grey, size: 24);
          }
          return null;
        },
      ),
    );
  }

  /// 计算解码边长上限，返回 null 表示尺寸无法确定、不限制解码分辨率。
  ///
  /// 取较长边即可，另一边会随原图宽高比等比缩放。
  static int? _resolveDecodeEdge(
    double? layoutWidth,
    double? layoutHeight,
    double devicePixelRatio,
  ) {
    final usableWidth = _usableSize(layoutWidth);
    final usableHeight = _usableSize(layoutHeight);
    if (usableWidth == null && usableHeight == null) {
      return null;
    }
    final longestLogicalEdge = math.max(
      usableWidth ?? 0.0,
      usableHeight ?? 0.0,
    );
    final pixels = (longestLogicalEdge * devicePixelRatio).ceil();
    if (pixels >= _maxDecodeEdge) {
      return _maxDecodeEdge;
    }
    // 量化到固定步长，使容器尺寸微调时复用同一份解码缓存
    final quantized = (pixels / _decodeEdgeStep).ceil() * _decodeEdgeStep;
    return quantized < _decodeEdgeStep ? null : quantized;
  }

  /// 返回可用于计算的尺寸值，无法使用时返回 null。
  static double? _usableSize(double? value) {
    if (value == null || !value.isFinite || value <= 0) {
      return null;
    }
    return value;
  }
}
