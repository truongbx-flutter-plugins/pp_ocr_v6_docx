import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';
import 'package:pdfx/pdfx.dart';
import 'package:docx_creator/docx_creator.dart' as docx_creator;

// Liên kết gọi hàm khởi tạo Session của thư viện ort.min.js trên môi trường Web
@JS('ort.InferenceSession.create')
external JSPromise createWebSession(JSString modelUrl);

class WebModelManager {
  // Các URL chứa model cung cấp riêng cho ứng dụng Web chạy Wasm
  static const String detModelUrl = "https://raw.githubusercontent.com/truongbx-flutter-plugins/pp_ocr_v6_docx/refs/heads/main/asset/model/PP-OCRv6_small_det_onnx.onnx";
  static const String recModelUrl = "https://raw.githubusercontent.com/truongbx-flutter-plugins/pp_ocr_v6_docx/refs/heads/main/asset/model/PP-OCRv6_small_rec_onnx.onnx";
}

Future<Uint8List> processPdfToDocx(Uint8List pdfBytes) async {
  print("--- Bắt đầu quy trình PP-OCRv6 trên Web ---");

  // Trình duyệt sẽ tự động download nếu URL chưa nằm trong Browser Cache Storage
  print("Khởi tạo và tải Session Wasm từ URL Cloud...");
  // Trong thực tế, bạn gọi nạp session thông qua JS interop:
  // await createWebSession(WebModelManager.detUrl.toJS).toDart;

  final docBuilder = docx_creator.docx();
  final document = await PdfDocument.openData(pdfBytes);
  final pageCount = document.pagesCount;

  for (int i = 1; i <= pageCount; i++) {
    final page = await document.getPage(i);
    final pageImage = await page.render(
        width: page.width * 2, height: page.height * 2, format: PdfPageImageFormat.jpeg);

    // Chạy suy luận WebAssembly...
    String pageTextResult = "Nội dung Web OCR trang $i.";
    docBuilder.p(pageTextResult);

    await page.close();
  }

  await document.close();

  final builtDoc = docBuilder.build();
  final List<int> docxBytes = await docx_creator.DocxExporter().exportToBytes(builtDoc);
  return Uint8List.fromList(docxBytes);
}
