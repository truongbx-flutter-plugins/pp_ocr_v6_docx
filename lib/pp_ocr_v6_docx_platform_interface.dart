import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'pp_ocr_v6_docx_method_channel.dart';

abstract class PpOcrV6DocxPlatform extends PlatformInterface {
  /// Constructs a PpOcrV6DocxPlatform.
  PpOcrV6DocxPlatform() : super(token: _token);

  static final Object _token = Object();

  static PpOcrV6DocxPlatform _instance = MethodChannelPpOcrV6Docx();

  /// The default instance of [PpOcrV6DocxPlatform] to use.
  ///
  /// Defaults to [MethodChannelPpOcrV6Docx].
  static PpOcrV6DocxPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [PpOcrV6DocxPlatform] when
  /// they register themselves.
  static set instance(PpOcrV6DocxPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
