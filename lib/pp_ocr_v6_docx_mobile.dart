import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:onnxruntime/onnxruntime.dart';
import 'package:pdfx/pdfx.dart';
import 'package:docx_creator/docx_creator.dart' as docx_creator;
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;

class MobileModelManager {
  // Thay các URL này bằng link chứa file ONNX PP-OCRv6 thực tế của bạn
  static const String detModelUrl = "https://your-server.com";
  static const String recModelUrl = "https://your-server.com";

  /// Hàm kiểm tra và tải model về máy nếu chưa tồn tại
  static Future<Map<String, String>> ensureModelsDownloaded() async {
    final docDir = await getApplicationDocumentsDirectory();
    final modelDir = Directory('${docDir.path}/ocr_models');

    if (!await modelDir.exists()) {
      await modelDir.create(recursive: true);
    }

    final String detPath = '${modelDir.path}/det_model.onnx';
    final String recPath = '${modelDir.path}/rec_model.onnx';

    await _downloadFileIfMissing(detModelUrl, detPath, "Mô hình Phát hiện Khung chữ (Det)");
    await _downloadFileIfMissing(recModelUrl, recPath, "Mô hình Nhận diện Tiếng Việt (Rec)");

    return {'det': detPath, 'rec': recPath};
  }

  static Future<void> _downloadFileIfMissing(String url, String localPath, String modelName) async {
    final file = File(localPath);
    if (await file.exists() && await file.length() > 0) {
      print("$modelName đã tồn tại cục bộ.");
      return;
    }

    print("Đang tiến hành tải $modelName từ Cloud...");
    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        await file.writeAsBytes(response.bodyBytes);
        print("Tải thành công: $modelName");
      } else {
        throw Exception("Server trả về mã lỗi: ${response.statusCode}");
      }
    } catch (e) {
      print("Lỗi trong quá trình tải $modelName: $e");
      throw Exception("Không thể tải cấu trúc mô hình OCR. Vui lòng kiểm tra kết nối mạng.");
    }
  }
}

// Cập nhật hàm xử lý OCR trên Mobile
Future<Uint8List?> processPdfToDocx(Uint8List pdfBytes) async {
  print("--- Bắt đầu quy trình PP-OCRv6 trên Mobile ---");

  // 1. Tự động kiểm tra / tải model trước khi chạy Session AI
  final modelPaths = await MobileModelManager.ensureModelsDownloaded();

  OrtEnv.instance.init();
  final sessionOptions = OrtSessionOptions();

  // Nạp trực tiếp từ file vật lý đã tải về thay vì nạp từ rootBundle Asset cố định
  if(modelPaths['det']==null || modelPaths['rec']==null) {
    return null;
  }
  final detSession = OrtSession.fromFile(modelPaths['det'] as File, sessionOptions);
  final recSession = OrtSession.fromFile(modelPaths['rec'] as File, sessionOptions);

  final docBuilder = docx_creator.docx();
  final document = await PdfDocument.openData(pdfBytes);
  final pageCount = document.pagesCount;

  for (int i = 1; i <= pageCount; i++) {
    final page = await document.getPage(i);
    final pageImage = await page.render(
        width: page.width * 2, height: page.height * 2, format: PdfPageImageFormat.jpeg);

    Uint8List imgBytes = pageImage!.bytes;

    // Logic xử lý ONNX Runtime dự đoán dữ liệu (Inference)...
    String pageTextResult = "Nội dung OCR trang $i.";
    docBuilder.p(pageTextResult);

    await page.close();
  }

  detSession.release();
  recSession.release();
  sessionOptions.release();
  OrtEnv.instance.release();
  await document.close();

  final builtDoc = docBuilder.build();
  final List<int> docxBytes = await docx_creator.DocxExporter().exportToBytes(builtDoc);
  return Uint8List.fromList(docxBytes);
}
