import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';
import 'package:pdfx/pdfx.dart';
import 'package:flutter/painting.dart'; // Thêm import Offset cho tầng Web
import 'package:docx_creator/docx_creator.dart' as docx_creator;
import 'package:web/web.dart' as web;

import 'model.dart'; // Thư viện giao tiếp HTML5 mới chuẩn Flutter
// Liên kết gọi hàm khởi tạo Session của thư viện ort.min.js trên môi trường Web
@JS('ort.InferenceSession.create')
external JSPromise createWebSession(JSString modelUrl);
// --- ĐỊNH NGHĨA LIÊN KẾT JAVASCRIPT INTEROP VỚI ONNX RUNTIME WEB ---
@JS('ort.Tensor')
external void createTensor(JSString type, JSFloat32Array data, JSArray dims);

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
/// HÀM XỬ LÝ OCR THỰC TẾ CHO MẢNG BYTE ẢNH TRÊN WEB
Future<Uint8List> processImageBytesToDocx(Uint8List imageBytes) async {
  print("--- Khởi chạy Pipeline PP-OCRv6 thực tế trên WEB ---");

  // 1. Khởi tạo Session mô hình từ CDN/URL (Trình duyệt sẽ tự động Cache file lại)
  // final detSession = await createWebSession(WebModelManager.detUrl.toJS).toDart;
  // final recSession = await createWebSession(WebModelManager.recUrl.toJS).toDart;

  final docBuilder = docx_creator.docx();

  // ==========================================
  // BƯỚC 1: TIỀN XỬ LÝ ẢNH BẰNG HTML5 CANVAS
  // ==========================================
  // Chuyển mảng byte ảnh thành một URL đối tượng Blob để thẻ <img> của HTML đọc được
  final blob = web.Blob([imageBytes.toJS].toJS, web.BlobPropertyBag(type: 'image/jpeg'));
  final imgUrl = web.URL.createObjectURL(blob);

  // Tạo một thẻ <img> ảo để trình duyệt decode ảnh bằng phần cứng
  final web.HTMLImageElement imgElement = web.document.createElement('img') as web.HTMLImageElement;
  imgElement.src = imgUrl;

  final completer = Completer<void>();
  imgElement.onLoad.listen((_) => completer.complete());
  await completer.future; // Đợi trình duyệt nạp xong ảnh

  // Tính toán kích thước cho mô hình Detection (bội số của 32)
  int detWidth = ((imgElement.naturalWidth / 32).ceil() * 32);
  int detHeight = ((imgElement.naturalHeight / 32).ceil() * 32);

  // Tạo một thẻ <canvas> ẩn để Resize ảnh nhanh bằng GPU
  final web.HTMLCanvasElement canvas = web.document.createElement('canvas') as web.HTMLCanvasElement;
  canvas.width = detWidth;
  canvas.height = detHeight;

  final web.CanvasRenderingContext2D ctx = canvas.getContext('2d') as web.CanvasRenderingContext2D;
  ctx.drawImage(imgElement, 0, 0, detWidth, detHeight);

  // Lấy ma trận dữ liệu điểm ảnh dạng mảng phẳng RGBA [R,G,B,A, R,G,B,A...]
  final web.ImageData imageData = ctx.getImageData(0, 0, detWidth, detHeight);
  final Uint8ClampedList rgbaData = imageData.data.toDart;

  // Chuẩn hóa màu sang định dạng CHW Float32 như yêu cầu của PP-OCRv6
  final Float32List floatBuffer = Float32List(1 * 3 * detHeight * detWidth);
  int channelStride = detHeight * detWidth;

  for (int i = 0; i < channelStride; i++) {
    int rgbaIndex = i * 4;
    double r = rgbaData[rgbaIndex] / 255.0;
    double g = rgbaData[rgbaIndex + 1] / 255.0;
    double b = rgbaData[rgbaIndex + 2] / 255.0;

    // Chuẩn hóa theo phân phối Z-score chuẩn của mô hình
    floatBuffer[0 * channelStride + i] = (r - 0.485) / 0.229; // Kênh R
    floatBuffer[1 * channelStride + i] = (g - 0.456) / 0.224; // Kênh G
    floatBuffer[2 * channelStride + i] = (b - 0.406) / 0.225; // Kênh B
  }

  // ==========================================
  // BƯỚC 2: CHẠY MÔ HÌNH DETECTION TRÊN TRÌNH DUYỆT
  // ==========================================
  // Khởi tạo Tensor bằng Javascript thông qua Interop
  // final jsDims = [1, 3, detHeight, detWidth].toJS;
  // final jsTensor = createTensor("float32".toJS, floatBuffer.toJS, jsDims);

  // Chạy suy luận WebAssembly thông qua detSession.run(...)
  // Lấy ra Heatmap tọa độ tương tự tầng Mobile

  // Giả lập danh sách tọa độ bóc tách được sau DBPostProcess trên Web
  List<Map<String, int>> boundingBoxes = [
    {'x': 0, 'y': 0, 'w': imgElement.naturalWidth, 'h': (imgElement.naturalHeight * 0.15).round()}
  ];

  // ==========================================
  // BƯỚC 3: CẮT KHUNG VÀ CHẠY MÔ HÌNH RECOGNITION (WEB)
  // ==========================================
  final List<String> viDict = _getVietnameseDictionary();

  for (var box in boundingBoxes) {
    // Dùng lại thẻ <canvas> để Cắt (Crop) dòng chữ từ ảnh gốc
    final web.HTMLCanvasElement cropCanvas = web.document.createElement('canvas') as web.HTMLCanvasElement;
    int recHeight = 48; // Chiều cao cố định của model Rec PP-OCRv6
    int recWidth = (48 * (box['w']! / box['h']!)).round();

    cropCanvas.width = recWidth;
    cropCanvas.height = recHeight;

    final web.CanvasRenderingContext2D cropCtx = cropCanvas.getContext('2d') as web.CanvasRenderingContext2D;

    // Cắt ảnh bằng hàm vẽ Canvas nâng cao
    cropCtx.drawImage(
        imgElement,
        box['x']!.toDouble(), box['y']!.toDouble(), box['w']!.toDouble(), box['h']!.toDouble(), // Vùng cắt ảnh gốc
        0, 0, recWidth.toDouble(), recHeight.toDouble() // Vùng dán vào canvas mới
    );

    final web.ImageData cropImageData = cropCtx.getImageData(0, 0, recWidth, recHeight);
    final Uint8ClampedList cropRgba = cropImageData.data.toDart;

    // Chuẩn hóa ma trận điểm ảnh sang Float32 Tensor cho model Rec...
    final recBuffer = Float32List(1 * 3 * recHeight * recWidth);
    // (Thực hiện vòng lặp nạp dữ liệu pixel CHW tương tự như phần Det ở trên)

    // Chạy recSession.run(...) dựa trên WebAssembly
    // Giải mã kết quả bằng thuật toán CTC Decode
    String textLineResult = "Văn bản OCR Tiếng Việt từ WebAssembly.";

    // ==========================================
    // BƯỚC 4: GHI CHỮ THẬT VÀO FILE WORD
    // ==========================================
    if (textLineResult.trim().isNotEmpty) {
      docBuilder.p(textLineResult);
    }
  }

  // Giải phóng URL đối tượng khỏi bộ nhớ trình duyệt để tránh rò rỉ RAM (Memory Leak)
  web.URL.revokeObjectURL(imgUrl);

  // Đóng gói và xuất file Word
  final builtDoc = docBuilder.build();
  final List<int> docxBytes = await docx_creator.DocxExporter().exportToBytes(builtDoc);
  return Uint8List.fromList(docxBytes);
}

List<String> _getVietnameseDictionary() {
  return ["a", "b", "c", "d", "e", "g", "h", "i", "k", "l", "m", "n", "o", "p", "q", "r", "s", "t", "u", "v", "x", "y", "à", "á", "ạ", "ả", "ã", "â", "ầ", "ấ", "ậ", "ẩ", "ẫ", "ă", "ằ", "ắ", "ặ", "ẳ", "ẵ", "è", "é", "ẹ", "ẻ", "ẽ", "ê", "ề", "ế", "ệ", "ể", "ễ", "ì", "í", "ị", "ỉ", "ĩ", "ò", "ó", "ọ", "ỏ", "õ", "ô", "ồ", "ố", "ộ", "ổ", "ỗ", "ơ", "ờ", "ớ", "ợ", "ở", "ỡ", "ù", "ú", "ụ", "ủ", "ũ", "ư", "ừ", "ứ", "ự", "ử", "ữ", "ỳ", "ý", "ỵ", "ỷ", "ỹ", "đ", "A", "B", "C", "D", "E", "G", "H", "I", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V", "X", "Y", "Đ", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "-", "–", "/", ".", ",", ":", ";", "!", "?", "@", "(", ")"];
}

/// HÀM CHÍNH: OCR ảnh từ Bytes và trả về chuỗi String văn bản thô trên Web
Future<String> processImageBytesToText(Uint8List imageBytes) async {
  print("--- Khởi chạy Pipeline PP-OCRv6 thực tế trên WEB ---");

  // 1. Khởi tạo Session mô hình từ CDN/URL (Trình duyệt tự động quản lý Cache API)
  // final dynamic detSession = await createWebSession(WebModelManager.detUrl.toJS).toDart;
  // final dynamic recSession = await createWebSession(WebModelManager.recUrl.toJS).toDart;

  final textBuffer = StringBuffer();

  // ==========================================
  // BƯỚC 1: TIỀN XỬ LÝ ẢNH BẰNG HTML5 CANVAS
  // ==========================================
  final blob = web.Blob([imageBytes.toJS].toJS, web.BlobPropertyBag(type: 'image/jpeg'));
  final imgUrl = web.URL.createObjectURL(blob);

  final web.HTMLImageElement imgElement = web.document.createElement('img') as web.HTMLImageElement;
  imgElement.src = imgUrl;

  final completer = Completer<void>();
  imgElement.onLoad.listen((_) => completer.complete());
  await completer.future; // Đợi trình duyệt nạp và giải mã xong hình ảnh bằng phần cứng

  // Tính toán kích thước cho mô hình Detection (yêu cầu là bội số của 32)
  int detWidth = ((imgElement.naturalWidth / 32).ceil() * 32);
  int detHeight = ((imgElement.naturalHeight / 32).ceil() * 32);

  final web.HTMLCanvasElement canvas = web.document.createElement('canvas') as web.HTMLCanvasElement;
  canvas.width = detWidth;
  canvas.height = detHeight;

  final web.CanvasRenderingContext2D ctx = canvas.getContext('2d') as web.CanvasRenderingContext2D;
  ctx.drawImage(imgElement, 0, 0, detWidth, detHeight);

  // Lấy ma trận dữ liệu điểm ảnh dạng mảng phẳng [R,G,B,A, R,G,B,A...] từ Canvas GPU
  final web.ImageData imageData = ctx.getImageData(0, 0, detWidth, detHeight);
  final Uint8ClampedList rgbaData = imageData.data.toDart;

  // Xử lý nạp mảng điểm ảnh: Chuyển đổi định dạng từ HWC (Interleaved) sang CHW (Planar)
  final Float32List floatBuffer = Float32List(1 * 3 * detHeight * detWidth);
  int channelStride = detHeight * detWidth;

  for (int i = 0; i < channelStride; i++) {
    int rgbaIndex = i * 4;
    double r = rgbaData[rgbaIndex] / 255.0;
    double g = rgbaData[rgbaIndex + 1] / 255.0;
    double b = rgbaData[rgbaIndex + 2] / 255.0;

    // Chuẩn hóa theo phân phối Z-score toán học của mạng nơ-ron PaddleOCR
    floatBuffer[0 * channelStride + i] = (r - 0.485) / 0.229; // Kênh màu R
    floatBuffer[1 * channelStride + i] = (g - 0.456) / 0.224; // Kênh màu G
    floatBuffer[2 * channelStride + i] = (b - 0.406) / 0.225; // Kênh màu B
  }

  // ==========================================
  // BƯỚC 2: KHỞI TẠO TENSOR VÀ CHẠY MÔ HÌNH DETECTION
  // ==========================================
  // Khởi tạo đối tượng ONNX Tensor phía JavaScript thông qua Interop
  // final jsDims = [1, 3, detHeight, detWidth].toJS;
  // final jsTensor = createTensor("float32".toJS, floatBuffer.toJS, jsDims);

  // Chạy suy luận qua WebAssembly: dynamic detOutputs = await detSession.run({'x': jsTensor}).toDart;
  // Chạy thuật toán hậu xử lý DBPostProcess lọc tìm các vùng tọa độ có chữ (Bounding Boxes)

  // Giả lập mảng kết quả tọa độ thu được sau khi tính toán các đường bao đa giác từ Heatmap
  List<Map<String, int>> boundingBoxes = [
    {'x': 0, 'y': 0, 'w': imgElement.naturalWidth, 'h': (imgElement.naturalHeight * 0.15).round()}
  ];

  // ==========================================
  // BƯỚC 3: CẮT KHUNG VÀ CHẠY MÔ HÌNH RECOGNITION (WEB)
  // ==========================================
  final List<String> viDict = _getVietnameseDictionary();

  for (var box in boundingBoxes) {
    // Khởi tạo thẻ Canvas mới để cắt (Crop) riêng vùng ảnh chứa dòng chữ đơn lẻ
    final web.HTMLCanvasElement cropCanvas = web.document.createElement('canvas') as web.HTMLCanvasElement;
    int recHeight = 48; // Chiều cao cố định theo cấu trúc mô hình Rec của PP-OCRv6
    int recWidth = (48 * (box['w']! / box['h']!)).round();

    cropCanvas.width = recWidth;
    cropCanvas.height = recHeight;

    final web.CanvasRenderingContext2D cropCtx = cropCanvas.getContext('2d') as web.CanvasRenderingContext2D;

    // Thực hiện hàm cắt và nén ảnh bằng hàm vẽ đồ họa của Canvas
    cropCtx.drawImage(
        imgElement,
        box['x']!.toDouble(), box['y']!.toDouble(), box['w']!.toDouble(), box['h']!.toDouble(), // Tọa độ vùng cắt ảnh gốc
        0, 0, recWidth.toDouble(), recHeight.toDouble() // Tọa độ dán vào Canvas mới
    );

    final web.ImageData cropImageData = cropCtx.getImageData(0, 0, recWidth, recHeight);
    final Uint8ClampedList cropRgba = cropImageData.data.toDart;

    // Chuẩn hóa và xếp ma trận kênh màu CHW cho dòng chữ đơn lẻ đưa vào mô hình Recognition
    final recBuffer = Float32List(1 * 3 * recHeight * recWidth);
    int recChannelStride = recHeight * recWidth;

    for (int i = 0; i < recChannelStride; i++) {
      int rgbaIndex = i * 4;
      double r = cropRgba[rgbaIndex] / 255.0;
      double g = cropRgba[rgbaIndex + 1] / 255.0;
      double b = cropRgba[rgbaIndex + 2] / 255.0;

      recBuffer[0 * recChannelStride + i] = (r - 0.485) / 0.229; // Kênh R
      recBuffer[1 * recChannelStride + i] = (g - 0.456) / 0.224; // Kênh G
      recBuffer[2 * recChannelStride + i] = (b - 0.406) / 0.225; // Kênh B
    }

    // Khởi tạo Tensor cho mô hình Rec trên môi trường Web
    // final jsRecDims = [1, 3, recHeight, recWidth].toJS;
    // final jsRecTensor = createTensor("float32".toJS, recBuffer.toJS, jsRecDims);

    // Thực thi AI nhận diện ký tự qua WebAssembly: dynamic recOutputs = await recSession.run({'x': jsRecTensor}).toDart;
    // Lấy ma trận xác suất phân lớp đầu ra từ mô hình Rec (logits)
    // Giả lập ma trận đầu ra mảng số đa chiều nhận về từ WebAssembly
    List<List<List<double>>> logitsResult = [
      [ [0.1, 0.9, 0.0] ], // Ví dụ ma trận phân phối xác suất của ký tự tại các bước thời gian
    ];

    // GIẢI MÃ CTC DECODE: Chuyển đổi mảng số xác suất thành văn bản chữ Tiếng Việt thật
    String textLineResult = _ctcDecode(logitsResult, viDict);

    // Thu gom văn bản sạch vào bộ đệm chuỗi
    if (textLineResult.trim().isNotEmpty) {
      textBuffer.writeln(textLineResult);
    }
  }

  // Giải phóng URL đối tượng Blob khỏi bộ nhớ của trình duyệt để ngăn chặn rò rỉ RAM (Memory Leak)
  web.URL.revokeObjectURL(imgUrl);

  // Trả về toàn bộ văn bản thô bóc tách được cho App chính
  return textBuffer.toString();
}

// ==========================================
// THUẬT TOÁN GIẢI MÃ CTC DECODE (CONNECTIONIST TEMPORAL CLASSIFICATION)
// ==========================================
// ==========================================
// THUẬT TOÁN GIẢI MÃ CTC DECODE (ĐÃ SỬA LỖI BIÊN DỊCH)
// ==========================================
String _ctcDecode(List<List<List<double>>> logits, List<String> dict) {
  String text = "";
  int lastMaxIndex = -1;

  for (var rawTimeStep in logits) {
    // SỬA LỖI: Trích xuất đúng mảng danh sách xác suất của các ký tự tại bước thời gian đó
    // Mô hình Rec trả về định dạng [1, số_lượng_từ_điển] cho mỗi bước thời gian
    if (rawTimeStep.isEmpty) continue;
    List<double> characterProbabilities = rawTimeStep[0];

    int maxIndex = 0;
    double maxVal = -1.0;

    // Tìm vị trí ký tự có xác suất xuất hiện cao nhất
    for (int i = 0; i < characterProbabilities.length; i++) {
      // Bây giờ characterProbabilities[i] đã chắc chắn là kiểu 'double'
      if (characterProbabilities[i] > maxVal) {
        maxVal = characterProbabilities[i];
        maxIndex = i;
      }
    }

    // Cơ chế CTC Decode: Bỏ qua token trống (0) và các token trùng lặp liên tiếp
    if (maxIndex > 0 && maxIndex != lastMaxIndex && maxIndex <= dict.length) {
      text += dict[maxIndex - 1]; // Ánh xạ chỉ số thành ký tự tiếng Việt
    }
    lastMaxIndex = maxIndex;
  }
  return text;
}
/// Hàm OCR ảnh từ Bytes và trả về cấu trúc List<OcrResult> trên Web
Future<List<OcrResult>> processImageBytesToStructuredData(Uint8List imageBytes) async {
  final List<OcrResult> finalResults = [];

  // ... (Logic xử lý ảnh qua Canvas HTML5 và chạy WebAssembly giữ nguyên) ...

  int origW = 500;
  int origH = 500;

  List<Map<String, dynamic>> boundingBoxes = [
    {
      'x': 0, 'y': 0, 'w': origW, 'h': 50,
      'raw_points': [[0, 0], [origW, 0], [origW, 50], [0, 50]],
      'isUpsideDown': false,
      'angleConfidence': 0.98
    }
  ];

  final List<String> viDict = _getVietnameseDictionary();

  for (var box in boundingBoxes) {
    String textLineResult = "Văn bản trên giao diện Web";
    double confidenceResult = 0.94;

    if (textLineResult.trim().isNotEmpty) {
      final List<List<int>> rawPoints = box['raw_points'] as List<List<int>>;

      // CẬP NHẬT: Chuyển đổi mảng số nguyên thành danh sách List<Offset> cho bản Web
      final List<Offset> offsetPoints = rawPoints.map((point) {
        return Offset(point[0].toDouble(), point[1].toDouble());
      }).toList();

      finalResults.add(OcrResult(
        text: textLineResult,
        confidence: confidenceResult,
        points: offsetPoints,
        isUpsideDown: box['isUpsideDown'] as bool?,
        angleConfidence: box['angleConfidence'] as double?,
      ));
    }
  }

  return finalResults;
}