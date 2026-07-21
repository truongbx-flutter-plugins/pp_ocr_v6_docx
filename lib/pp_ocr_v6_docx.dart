
import 'dart:typed_data';
import 'pp_ocr_v6_docx_mobile.dart' if (dart.library.js_interop) 'pp_ocr_v6_docx_web.dart' as worker;

class PpOcrV6Docx {
  /// Hàm chuyển đổi file PDF sang định dạng Word (.docx)
  /// Nhận vào byte dữ liệu của file PDF để chạy chung cho cả 3 nền tảng (Web không có đường dẫn File vật lý trực tiếp như Mobile)
  static Future<Uint8List?> convertPdfBytesToDocx(Uint8List pdfBytes) async {
    return await worker.processPdfToDocx(pdfBytes);
  }
}
