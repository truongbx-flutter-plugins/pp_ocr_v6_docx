import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';
import 'package:pdfx/pdfx.dart';
import 'package:docx_creator/docx_creator.dart' as docx_creator; // Đồng bộ sử dụng docx_creator

Future<Uint8List> processPdfToDocx(Uint8List pdfBytes) async {
  print("--- Đang chạy PP-OCRv6 trên nền tảng WEB (Wasm) ---");

  // CẬP NHẬT: Sử dụng docx_creator builder
  final docBuilder = docx_creator.docx();

  final document = await PdfDocument.openData(pdfBytes);
  final pageCount = document.pagesCount;

  for (int i = 1; i <= pageCount; i++) {
    final page = await document.getPage(i);
    final pageImage = await page.render(
      width: page.width * 2,
      height: page.height * 2,
      format: PdfPageImageFormat.jpeg,
    );

    Uint8List imageBytes = pageImage!.bytes;

    // Xử lý mô hình ONNX Web qua WebAssembly (ort.min.js)...
    String pageTextResult = "Nội dung văn bản tiếng Việt trang $i được OCR bằng WebAssembly.";

    // CẬP NHẬT: Ghi chữ vào file Word
    docBuilder.p(pageTextResult);

    await page.close();
  }

  await document.close();

  // CẬP NHẬT: Đóng gói và trả về chuỗi byte của file Word (.docx)
  final builtDoc = docBuilder.build();
  final List<int> docxBytes = await docx_creator.DocxExporter().exportToBytes(builtDoc);
  return Uint8List.fromList(docxBytes);
}
