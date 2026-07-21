import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pp_ocr_v6_docx/pp_ocr_v6_docx_method_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  MethodChannelPpOcrV6Docx platform = MethodChannelPpOcrV6Docx();
  const MethodChannel channel = MethodChannel('pp_ocr_v6_docx');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
          return '42';
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('getPlatformVersion', () async {
    expect(await platform.getPlatformVersion(), '42');
  });
}
