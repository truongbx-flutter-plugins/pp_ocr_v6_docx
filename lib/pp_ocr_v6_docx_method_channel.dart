import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'pp_ocr_v6_docx_platform_interface.dart';

/// An implementation of [PpOcrV6DocxPlatform] that uses method channels.
class MethodChannelPpOcrV6Docx extends PpOcrV6DocxPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('pp_ocr_v6_docx');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>(
      'getPlatformVersion',
    );
    return version;
  }
}
