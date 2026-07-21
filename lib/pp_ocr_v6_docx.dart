
import 'dart:typed_data';
import 'package:image_picker/image_picker.dart';

import 'pp_ocr_v6_docx_mobile.dart' if (dart.library.js_interop) 'pp_ocr_v6_docx_web.dart' as worker;

class PpOcrV6Docx {
  /// Hàm chuyển đổi file PDF sang định dạng Word (.docx)
  /// Nhận vào byte dữ liệu của file PDF để chạy chung cho cả 3 nền tảng (Web không có đường dẫn File vật lý trực tiếp như Mobile)
  static Future<Uint8List?> convertPdfBytesToDocx(Uint8List pdfBytes) async {
    return await worker.processPdfToDocx(pdfBytes);
  }
  /// HÀM MỚI: Xử lý trực tiếp XFile (Ảnh chụp Camera hoặc Ảnh từ thư viện)
  static Future<Uint8List?> convertXFileToDocx(XFile xFile) async {
    // Đọc ảnh thành mảng bytes độc lập với nền tảng (Web/Mobile đều chạy được)
    final Uint8List imageBytes = await xFile.readAsBytes();
    return await worker.processImageBytesToDocx(imageBytes);
  }

}
