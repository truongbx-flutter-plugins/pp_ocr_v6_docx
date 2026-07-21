import 'package:flutter_test/flutter_test.dart';
import 'package:pp_ocr_v6_docx/pp_ocr_v6_docx.dart';
import 'package:pp_ocr_v6_docx/pp_ocr_v6_docx_platform_interface.dart';
import 'package:pp_ocr_v6_docx/pp_ocr_v6_docx_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockPpOcrV6DocxPlatform
    with MockPlatformInterfaceMixin
    implements PpOcrV6DocxPlatform {
  @override
  Future<String?> getPlatformVersion() => Future.value('42');
}

void main() {
  final PpOcrV6DocxPlatform initialPlatform = PpOcrV6DocxPlatform.instance;

  test('$MethodChannelPpOcrV6Docx is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelPpOcrV6Docx>());
  });

  test('getPlatformVersion', () async {
    PpOcrV6Docx ppOcrV6DocxPlugin = PpOcrV6Docx();
    MockPpOcrV6DocxPlatform fakePlatform = MockPpOcrV6DocxPlatform();
    PpOcrV6DocxPlatform.instance = fakePlatform;

    expect(await ppOcrV6DocxPlugin.getPlatformVersion(), '42');
  });
}
