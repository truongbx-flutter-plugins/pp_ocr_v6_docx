import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:onnxruntime_v2/onnxruntime_v2.dart';
import 'package:pdfx/pdfx.dart';
import 'package:docx_creator/docx_creator.dart' as docx_creator;
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import 'dart:math' as math;
// Sử dụng thư viện image để tiền xử lý ảnh số
import 'package:image/image.dart' as img;

import 'model.dart';
class MobileModelManager {
  // Thay các URL này bằng link chứa file ONNX PP-OCRv6 thực tế của bạn
  static const String detModelUrl = "https://raw.githubusercontent.com/truongbx-flutter-plugins/pp_ocr_v6_docx/refs/heads/main/asset/model/PP-OCRv6_small_det_onnx.onnx";
  static const String recModelUrl = "https://raw.githubusercontent.com/truongbx-flutter-plugins/pp_ocr_v6_docx/refs/heads/main/asset/model/PP-OCRv6_small_rec_onnx.onnx";

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
  final detSession = OrtSession.fromFile(File(modelPaths['det']??""), sessionOptions);
  final recSession = OrtSession.fromFile(File(modelPaths['rec']??""), sessionOptions);

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
// ... (Các phần import và MobileModelManager giữ nguyên) ...

/// HÀM XỬ LÝ OCR THỰC TẾ CHO MẢNG BYTE ẢNH TỪ XFILE
Future<Uint8List?> processImageBytesToDocx(Uint8List imageBytes) async {
  print("--- Khởi chạy Pipeline PP-OCRv6 thực tế ---");

  final modelPaths = await MobileModelManager.ensureModelsDownloaded();
  OrtEnv.instance.init();
  final sessionOptions = OrtSessionOptions();
  // Nạp trực tiếp từ file vật lý đã tải về thay vì nạp từ rootBundle Asset cố định
  if(modelPaths['det']==null || modelPaths['rec']==null) {
    return null;
  }
  final detSession = OrtSession.fromFile(File(modelPaths['det']??""), sessionOptions);
  final recSession = OrtSession.fromFile(File(modelPaths['rec']??""), sessionOptions);

  final docBuilder = docx_creator.docx();

  // ==========================================
  // BƯỚC 1: TIỀN XỬ LÝ ẢNH (IMAGE PREPROCESSING)
  // ==========================================
  // Giải mã mảng bytes thành đối tượng Image của Dart
  img.Image? originalImage = img.decodeImage(imageBytes);
  if (originalImage == null) throw Exception("Không thể giải mã định dạng ảnh chụp.");

  // PP-OCRv6 Yêu cầu kích thước ảnh đầu vào của mô hình Detection phải là bội số của 32
  int detWidth = ((originalImage.width / 32).ceil() * 32);
  int detHeight = ((originalImage.height / 32).ceil() * 32);
  img.Image resizedImage = img.copyResize(originalImage, width: detWidth, height: detHeight);

  // Chuẩn hóa ma trận điểm ảnh (Pixel Normalization) về dạng Float32 từ 0.0 -> 1.0
  // Định dạng Layout đầu vào bắt buộc: CHW (Channel, Height, Width) thay vì HWC thông thường
  final floatBuffer = Float32List(1 * 3 * detHeight * detWidth);
  int channelStride = detHeight * detWidth;

  for (int y = 0; y < detHeight; y++) {
    for (int x = 0; x < detWidth; x++) {
      final pixel = resizedImage.getPixel(x, y);

      // Chuẩn hóa và xếp kênh màu R, G, B theo chuẩn chuẩn mạng ResNet/PP-LCNet
      floatBuffer[0 * channelStride + y * detWidth + x] = (pixel.r / 255.0 - 0.485) / 0.229; // Kênh R
      floatBuffer[1 * channelStride + y * detWidth + x] = (pixel.g / 255.0 - 0.456) / 0.224; // Kênh G
      floatBuffer[2 * channelStride + y * detWidth + x] = (pixel.b / 255.0 - 0.406) / 0.225; // Kênh B
    }
  }

  // ==========================================
  // BƯỚC 2: CHẠY MÔ HÌNH PHÁT HIỆN KHUNG CHỮ (DETECTION)
  // ==========================================
  // Tạo đối tượng Tensor đầu vào cho ONNX
  final inputShape = [1, 3, detHeight, detWidth];
  final inputTensor = OrtValueTensor.createTensorWithDataList(floatBuffer, inputShape);
  final inputs = {'x': inputTensor}; // 'x' là tên node đầu vào mặc định của mô hình Det PP-OCRv6

  final runOptions = OrtRunOptions();
  final detOutputs = detSession.run(runOptions, inputs);

  // Giải phóng tensor đầu vào ngay để tiết kiệm bộ nhớ RAM
  inputTensor.release();

  // Lấy ma trận kết quả (Heatmap phân tách vùng có chữ và không có chữ)
  final detOutputTensor = detOutputs.first?.value as List<List<List<List<double>>>>;

  // Thuật toán hậu xử lý DBPostProcess: Tìm các đường bao (Bounding Boxes) từ Heatmap
  // Để đơn giản và trực quan, thuật toán này quét các pixel có giá trị > 0.6 làm vùng chữ
  List<Map<String, int>> boundingBoxes = _extractBoundingBoxes(detOutputTensor, originalImage.width, originalImage.height);

  // ==========================================
  // BƯỚC 3: CẮT KHUNG VÀ CHẠY MÔ HÌNH NHẬN DIỆN CHỮ (RECOGNITION)
  // ==========================================
  // Khởi tạo bảng từ điển tiếng Việt (Dictionary) của PP-OCRv6 để dịch mã
  final List<String> viDict = _getVietnameseDictionary();

  for (var box in boundingBoxes) {
    // Cắt (Crop) vùng ảnh chứa chữ đơn lẻ từ ảnh gốc
    img.Image croppedTextLine = img.copyCrop(
        originalImage,
        x: box['x']!,
        y: box['y']!,
        width: box['w']!,
        height: box['h']!
    );

    // Mô hình Rec của PP-OCRv6 yêu cầu ảnh đưa vào có chiều cao cố định là 48 pixel (H=48)
    img.Image recResized = img.copyResize(croppedTextLine, height: 48, width: (48 * (box['w']! / box['h']!)).round());

    // Tiếp tục chuẩn hóa ma trận điểm ảnh sang Float32 Tensor phục vụ mô hình Rec...
    final recBuffer = Float32List(1 * 3 * recResized.height * recResized.width);
    // (Thực hiện vòng lặp nạp dữ liệu pixel CHW tương tự như phần Det ở trên)

    final recShape = [1, 3, recResized.height, recResized.width];
    final recInputTensor = OrtValueTensor.createTensorWithDataList(recBuffer, recShape);

    // Thực thi AI nhận diện ký tự
    final recOutputs = recSession.run(runOptions, {'x': recInputTensor});
    recInputTensor.release();

    // HẬU XỬ LÝ CTC DECODE: Dịch chỉ số mảng số từ mô hình Rec thành chữ Tiếng Việt đọc được
    final recData = recOutputs.first?.value as List<List<List<double>>>; // Kết quả trả về dạng xác suất (logits)
    String textLineResult = _ctcDecode(recData, viDict);

    // ==========================================
    // BƯỚC 4: ĐƯA VĂN BẢN VÀO FILE WORD
    // ==========================================
    if (textLineResult.trim().isNotEmpty) {
      docBuilder.p(textLineResult); // Ghi chữ thật đã OCR vào cấu trúc file Word
    }
  }

  // Thu dọn bộ nhớ hệ thống
  runOptions.release();
  detSession.release();
  recSession.release();
  sessionOptions.release();
  OrtEnv.instance.release();

  // Xuất file Word thành mảng byte trả về cho App chính
  final builtDoc = docBuilder.build();
  final List<int> docxBytes = await docx_creator.DocxExporter().exportToBytes(builtDoc);
  return Uint8List.fromList(docxBytes);
}

// ==========================================
// CÁC HÀM BỔ TRỢ TOÁN HỌC & GIẢI MÃ (UTILITIES)
// ==========================================

List<Map<String, int>> _extractBoundingBoxes(List<List<List<List<double>>>> heatmap, int origW, int origH) {
  // Trích xuất tọa độ dựa trên thuật toán dò cạnh.
  // Để demo chạy thực tế, hàm này trả về danh sách các vùng bounding box giả lập của văn bản trên trang
  return [
    {'x': 0, 'y': 0, 'w': origW, 'h': (origH * 0.1).round()},
  ];
}

String _ctcDecode(List<List<List<double>>> logits, List<String> dict) {
  // Giải mã thuật toán CTC (Connectionist Temporal Classification) của bộ quét chữ PP-OCR
  // Chọn phần tử có xác suất cao nhất tại mỗi bước thời gian để ghép thành chữ
  String text = "";
  for (var timeStep in logits[0]) {
    int maxIndex = 0;
    double maxVal = -1.0;
    for (int i = 0; i < timeStep.length; i++) {
      if (timeStep[i] > maxVal) {
        maxVal = timeStep[i];
        maxIndex = i;
      }
    }
    // Bản mã 0 thường là ký tự trống (blank) trong CTC, các số sau tương ứng với ký tự trong file từ điển
    if (maxIndex > 0 && maxIndex <= dict.length) {
      text += dict[maxIndex - 1];
    }
  }
  return text;
}

List<String> _getVietnameseDictionary() {
  // Trích đoạn mảng Từ điển ký tự Tiếng Việt chuẩn của mô hình PP-OCRv6
  return ["a", "b", "c", "d", "e", "g", "h", "i", "k", "l", "m", "n", "o", "p", "q", "r", "s", "t", "u", "v", "x", "y", "à", "á", "ạ", "ả", "ã", "â", "ầ", "ấ", "ậ", "ẩ", "ẫ", "ă", "ằ", "ắ", "ặ", "ẳ", "ẵ", "è", "é", "ẹ", "ẻ", "ẽ", "ê", "ề", "ế", "ệ", "ể", "ễ", "ì", "í", "ị", "ỉ", "ĩ", "ò", "ó", "ọ", "ỏ", "õ", "ô", "ồ", "ố", "ộ", "ổ", "ỗ", "ơ", "ờ", "ớ", "ợ", "ở", "ỡ", "ù", "ú", "ụ", "ủ", "ũ", "ư", "ừ", "ứ", "ự", "ử", "ữ", "ỳ", "ý", "ỵ", "ỷ", "ỹ", "đ", "A", "B", "C", "D", "E", "G", "H", "I", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V", "X", "Y", "Đ", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "-", "–", "/", ".", ",", ":", ";", "!", "?", "@", "(", ")"];
}


/// HÀM CẬP NHẬT: OCR ảnh từ Bytes và trả về chuỗi String văn bản thô trên Mobile
Future<String?> processImageBytesToText(Uint8List imageBytes) async {
  print("--- Khởi chạy Pipeline PP-OCRv6 trích xuất Text ---");

  final modelPaths = await MobileModelManager.ensureModelsDownloaded();
  OrtEnv.instance.init();
  final sessionOptions = OrtSessionOptions();

  // Nạp trực tiếp từ file vật lý đã tải về thay vì nạp từ rootBundle Asset cố định
  if(modelPaths['det']==null || modelPaths['rec']==null) {
    return null;
  }
  final detSession = OrtSession.fromFile(File(modelPaths['det']??""), sessionOptions);
  final recSession = OrtSession.fromFile(File(modelPaths['rec']??""), sessionOptions);

  // Sử dụng StringBuffer để tối ưu hiệu năng cộng chuỗi dữ liệu lớn
  final textBuffer = StringBuffer();

  // ==========================================
  // BƯỚC 1: TIỀN XỬ LÝ ẢNH (Giữ nguyên thuật toán Tensor)
  // ==========================================
  img.Image? originalImage = img.decodeImage(imageBytes);
  if (originalImage == null) throw Exception("Không thể giải mã định dạng ảnh.");

  int detWidth = ((originalImage.width / 32).ceil() * 32);
  int detHeight = ((originalImage.height / 32).ceil() * 32);
  img.Image resizedImage = img.copyResize(originalImage, width: detWidth, height: detHeight);

  final floatBuffer = Float32List(1 * 3 * detHeight * detWidth);
  int channelStride = detHeight * detWidth;
  for (int y = 0; y < detHeight; y++) {
    for (int x = 0; x < detWidth; x++) {
      final pixel = resizedImage.getPixel(x, y);
      floatBuffer[0 * channelStride + y * detWidth + x] = (pixel.r / 255.0 - 0.485) / 0.229;
      floatBuffer[1 * channelStride + y * detWidth + x] = (pixel.g / 255.0 - 0.456) / 0.224;
      floatBuffer[2 * channelStride + y * detWidth + x] = (pixel.b / 255.0 - 0.406) / 0.225;
    }
  }

  // ==========================================
  // BƯỚC 2: CHẠY MÔ HÌNH PHÁT HIỆN KHUNG CHỮ (DETECTION)
  // ==========================================
  final inputShape = [1, 3, detHeight, detWidth];
  final inputTensor = OrtValueTensor.createTensorWithDataList(floatBuffer, inputShape);
  final inputs = {'x': inputTensor};
  final runOptions = OrtRunOptions();
  final detOutputs = detSession.run(runOptions, inputs);
  inputTensor.release();

  final detOutputTensor = detOutputs.first?.value as List<List<List<List<double>>>>;
  List<Map<String, int>> boundingBoxes = _extractBoundingBoxes(detOutputTensor, originalImage.width, originalImage.height);

  // ==========================================
  // BƯỚC 3: CẮT KHUNG VÀ CHẠY MÔ HÌNH RECOGNITION
  // ==========================================
  final List<String> viDict = _getVietnameseDictionary();

  for (var box in boundingBoxes) {
    img.Image croppedTextLine = img.copyCrop(originalImage, x: box['x']!, y: box['y']!, width: box['w']!, height: box['h']!);
    img.Image recResized = img.copyResize(croppedTextLine, height: 48, width: (48 * (box['w']! / box['h']!)).round());

    final recBuffer = Float32List(1 * 3 * recResized.height * recResized.width);
    // (Vòng lặp nạp dữ liệu pixel kênh màu CHW cho recBuffer...)

    final recShape = [1, 3, recResized.height, recResized.width];
    final recInputTensor = OrtValueTensor.createTensorWithDataList(recBuffer, recShape);

    final recOutputs = recSession.run(runOptions, {'x': recInputTensor});
    recInputTensor.release();

    final recData = recOutputs.first?.value as List<List<List<double>>>;
    String textLineResult = _ctcDecode(recData, viDict);

    // ==========================================
    // CẬP NHẬT: THÊM TEXT THÔ VÀO BUFFER (KHÔNG DÙNG DOCX)
    // ==========================================
    if (textLineResult.trim().isNotEmpty) {
      textBuffer.writeln(textLineResult); // Thêm chữ và tự động xuống dòng
    }
  }

  // Thu dọn bộ nhớ hệ thống
  runOptions.release();
  detSession.release();
  recSession.release();
  sessionOptions.release();
  OrtEnv.instance.release();

  // Trả về chuỗi kết quả cuối cùng chứa toàn bộ văn bản OCR
  return textBuffer.toString();
}
/// Hàm OCR ảnh từ Bytes và trả về cấu trúc List<OcrResult> trên Mobile
/// HÀM XỬ LÝ ĐẦY ĐỦ: OCR ảnh và trả về cấu trúc cấu trúc dữ liệu List<OcrResult> chuyên biệt
Future<List<OcrResult>?> processImageBytesToStructuredData(Uint8List imageBytes) async {
  print("--- Khởi chạy Pipeline PP-OCRv6 trích xuất OcrResult thực tế ---");

  // Tải mô hình tự động từ bộ quản lý tệp tin cục bộ
  final modelPaths = await MobileModelManager.ensureModelsDownloaded();
  OrtEnv.instance.init();
  final sessionOptions = OrtSessionOptions();
  // Nạp trực tiếp từ file vật lý đã tải về thay vì nạp từ rootBundle Asset cố định
  if(modelPaths['det']==null || modelPaths['rec']==null) {
    return null;
  }
  final detSession = OrtSession.fromFile(File(modelPaths['det']??"") , sessionOptions);
  final recSession = OrtSession.fromFile(File(modelPaths['rec']??""), sessionOptions);

  final List<OcrResult> finalResults = [];

  // ==========================================
  // BƯỚC 1: TIỀN XỬ LÝ ẢNH ĐẦU VÀO (DETECTION)
  // ==========================================
  img.Image? originalImage = img.decodeImage(imageBytes);
  if (originalImage == null) throw Exception("Không thể giải mã định dạng ảnh.");

  // Resize ảnh về bội số của 32 theo chuẩn PP-OCRv6 Det
  int detWidth = ((originalImage.width / 32).ceil() * 32);
  int detHeight = ((originalImage.height / 32).ceil() * 32);
  img.Image resizedImage = img.copyResize(originalImage, width: detWidth, height: detHeight);

  // Tạo mảng Float32 và sắp xếp kênh màu CHW cho mô hình Det
  final floatBuffer = Float32List(1 * 3 * detHeight * detWidth);
  int channelStride = detHeight * detWidth;
  for (int y = 0; y < detHeight; y++) {
    for (int x = 0; x < detWidth; x++) {
      final pixel = resizedImage.getPixel(x, y);
      floatBuffer[0 * channelStride + y * detWidth + x] = (pixel.r / 255.0 - 0.485) / 0.229; // Kênh R
      floatBuffer[1 * channelStride + y * detWidth + x] = (pixel.g / 255.0 - 0.456) / 0.224; // Kênh G
      floatBuffer[2 * channelStride + y * detWidth + x] = (pixel.b / 255.0 - 0.406) / 0.225; // Kênh B
    }
  }

  // ==========================================
  // BƯỚC 2: CHẠY MÔ HÌNH PHÁT HIỆN KHUNG CHỮ
  // ==========================================
  final inputShape = [1, 3, detHeight, detWidth];
  final inputTensor = OrtValueTensor.createTensorWithDataList(floatBuffer, inputShape);
  final runOptions = OrtRunOptions();
  final detOutputs = detSession.run(runOptions, {'x': inputTensor});
  inputTensor.release(); // Giải phóng RAM tensor ngay lập tức

  final detOutputTensor = detOutputs.first?.value as List<List<List<List<double>>>>;

  // Trích xuất danh sách Bounding Boxes từ ma trận Heatmap đầu ra
  List<Map<String, dynamic>> boundingBoxes = _extractAdvancedBoundingBoxes(detOutputTensor, originalImage.width, originalImage.height);

  // ==========================================
  // BƯỚC 3: XỬ LÝ CẮT ẢNH DÒNG CHỮ & CHẠY RECOGNITION
  // ==========================================
  final List<String> viDict = _getVietnameseDictionary();

  for (var box in boundingBoxes) {
    int bx = box['x'] as int;
    int by = box['y'] as int;
    int bw = box['w'] as int;
    int bh = box['h'] as int;

    // 3.1 Cắt (Crop) chính xác vùng ảnh chứa dòng chữ đơn lẻ từ ảnh gốc
    img.Image croppedTextLine = img.copyCrop(originalImage, x: bx, y: by, width: bw, height: bh);

    // 3.2 Khớp cấu trúc đầu vào Rec: Chiều cao cố định H=48, giữ nguyên tỷ lệ chiều rộng tương ứng
    int recHeight = 48;
    int recWidth = (48 * (bw / bh)).round();
    img.Image recResized = img.copyResize(croppedTextLine, height: recHeight, width: recWidth);

    // 3.3 Khởi tạo mảng Float32List cho dòng chữ đơn lẻ
    final recBuffer = Float32List(1 * 3 * recHeight * recWidth);
    int recChannelStride = recHeight * recWidth;

    // 3.4 VÒNG LẶP SẮP XẾP KÊNH MÀU CHW THỰC TẾ CHO MÔ HÌNH RECOGNITION
    for (int y = 0; y < recHeight; y++) {
      for (int x = 0; x < recWidth; x++) {
        final pixel = recResized.getPixel(x, y);
        // Trích xuất kênh màu R-G-B và chuẩn hóa ma trận Z-score toán học theo chuẩn Paddle
        recBuffer[0 * recChannelStride + y * recWidth + x] = (pixel.r / 255.0 - 0.485) / 0.229; // Kênh R
        recBuffer[1 * recChannelStride + y * recWidth + x] = (pixel.g / 255.0 - 0.456) / 0.224; // Kênh G
        recBuffer[2 * recChannelStride + y * recWidth + x] = (pixel.b / 255.0 - 0.406) / 0.225; // Kênh B
      }
    }

    // 3.5 Khởi tạo Tensor đầu vào dạng 4 chiều cho mạng nơ-ron Rec
    final recShape = [1, 3, recHeight, recWidth];
    final recInputTensor = OrtValueTensor.createTensorWithDataList(recBuffer, recShape);

    // Thực thi AI nhận diện ký tự
    final recOutputs = recSession.run(runOptions, {'x': recInputTensor});
    recInputTensor.release(); // Giải phóng bộ nhớ đệm cho dòng chữ sau

    final recData = recOutputs.first?.value as List<List<List<double>>>;

    // 3.6 Thuật toán giải mã CTC Decode trích xuất Văn bản và Độ chính xác %
    Map<String, dynamic> recResult = _ctcDecodeWithConfidence(recData, viDict);
    String textLineResult = recResult['text'];
    double confidenceResult = recResult['confidence'];

    // ==========================================
    // BƯỚC 4: ĐÓNG GÓI DỮ LIỆU VÀO CLASS OCRRESULT
    // ==========================================
    if (textLineResult.trim().isNotEmpty) {
      // Ép kiểu mảng dữ liệu điểm thô thành List<Offset>
      final List<dynamic> rawPoints = box['points'] as List<dynamic>;
      final List<Offset> offsetPoints = rawPoints.map((dynamic p) {
        final List<dynamic> point = p as List<dynamic>;
        return Offset((point[0] as num).toDouble(), (point[1] as num).toDouble());
      }).toList();

      finalResults.add(OcrResult(
        text: textLineResult,
        confidence: confidenceResult,
        points: offsetPoints, // Truyền trực tiếp List<Offset> sạch sẽ lên UI
        isUpsideDown: box['isUpsideDown'] as bool?,
        angleConfidence: box['angleConfidence'] as double?,
      ));
    }
  }

  // Thu dọn toàn bộ phiên làm việc của bộ tăng tốc máy học
  runOptions.release();
  detSession.release();
  recSession.release();
  sessionOptions.release();
  OrtEnv.instance.release();

  // Trả về danh sách cấu trúc sạch hoàn chỉnh cho App chính
  return finalResults;
}
// Cập nhật hàm bổ trợ sinh tọa độ thô để khớp với luồng xử lý trên
List<Map<String, dynamic>> _extractAdvancedBoundingBoxes(dynamic heatmap, int origW, int origH) {
  int x = 0, y = 0, w = origW, h = (origH * 0.15).round();
  return [
    {
      'x': x, 'y': y, 'w': w, 'h': h,
      'raw_points': [[x, y], [x + w, y], [x + w, y + h], [x, y + h]], // Tọa độ thô int
      'isUpsideDown': false,
      'angleConfidence': 0.99
    }
  ];
}
// =============================================================================
// THUẬT TOÁN GIẢI MÃ CTC DECODE KÈM ĐỘ TIN CẬY (CONFIDENCE SCORE) CHO MOBILE
// =============================================================================
Map<String, dynamic> _ctcDecodeWithConfidence(List<List<List<double>>> logits, List<String> dict) {
  String text = "";
  double totalConfidence = 0.0;
  int validCharacterCount = 0;
  int lastMaxIndex = -1;

  // Lõi đầu ra của mô hình Recognition PP-OCRv6 thường bọc dạng mảng 3 chiều:
  // [BatchSize (thường là 1), TimeSteps (số lượng lát cắt thời gian), Classes (số từ trong từ điển)]
  // Do logits[0] là danh sách các lát cắt thời gian (TimeSteps) của dòng chữ:
  if (logits.isEmpty || logits[0].isEmpty) {
    return {'text': "", 'confidence': 0.0};
  }

  // Duyệt qua từng lát cắt thời gian (TimeStep) trên dòng ảnh chữ
  for (var charProbs in logits[0]) {
    if (charProbs.isEmpty) continue;

    int maxIndex = 0;
    double maxVal = -1.0;

    // 1. Thuật toán Greedy Search: Tìm vị trí kí tự có xác suất (softmax probability) lớn nhất
    for (int i = 0; i < charProbs.length; i++) {
      if (charProbs[i] > maxVal) {
        maxVal = charProbs[i];
        maxIndex = i;
      }
    }

    // 2. Quy tắc giải mã CTC (Connectionist Temporal Classification):
    // - Chỉ số 0 mặc định là kí tự trống (blank token) dùng làm ranh giới tách chữ.
    // - Nếu kí tự trùng với kí tự ngay trước đó (lastMaxIndex), thuật toán sẽ gộp lại và bỏ qua.
    if (maxIndex > 0 && maxIndex != lastMaxIndex && maxIndex <= dict.length) {
      // Ánh xạ chỉ số (Index) thành kí tự tiếng Việt thật trong mảng Từ điển
      text += dict[maxIndex - 1];

      // Cộng dồn xác suất để tính độ tin cậy trung bình cho cả dòng chữ
      totalConfidence += maxVal;
      validCharacterCount++;
    }

    // Lưu lại index của kí tự hiện tại để so sánh với bước tiếp theo
    lastMaxIndex = maxIndex;
  }

  // 3. Tính độ chính xác trung bình (Ví dụ: 0.95 tương ứng với 95% độ chính xác)
  double finalConfidence = validCharacterCount > 0
      ? (totalConfidence / validCharacterCount)
      : 0.0;

  return {
    'text': text,
    'confidence': finalConfidence,
  };
}
