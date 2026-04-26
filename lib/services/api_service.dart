import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

class ApiService {
  // Set via: --dart-define=EXAMIQ_API_BASE_URL=http://host:port
  static const String _configuredBaseUrl =
      String.fromEnvironment('EXAMIQ_API_BASE_URL', defaultValue: '');

  static const Duration _timeout = Duration(seconds: 30);
  static String? _activeBaseUrl;

  static String _normalizeBaseUrl(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return trimmed;
    return trimmed.endsWith('/') ? trimmed.substring(0, trimmed.length - 1) : trimmed;
  }

  static List<String> _candidateBaseUrls() {
    final seen = <String>{};
    final urls = <String>[];

    void add(String value) {
      final normalized = _normalizeBaseUrl(value);
      if (normalized.isEmpty || seen.contains(normalized)) return;
      seen.add(normalized);
      urls.add(normalized);
    }

    if (_activeBaseUrl != null && _activeBaseUrl!.isNotEmpty) {
      add(_activeBaseUrl!);
    }

    if (_configuredBaseUrl.isNotEmpty) {
      add(_configuredBaseUrl);
    }

    // Safe defaults for local development.
    add('http://127.0.0.1:8000');
    add('http://localhost:8000');

    // Android emulator host alias to reach machine localhost.
    if (!kIsLikelyWeb && Platform.isAndroid) {
      add('http://10.0.2.2:8000');
    }

    return urls;
  }

  // Avoid importing flutter/foundation in service layer.
  // The app is primarily mobile; this gate prevents Platform checks on web builds.
  static bool get kIsLikelyWeb {
    try {
      // dart:io Platform is unavailable on web and throws at runtime.
      // ignore: unnecessary_statements
      Platform.operatingSystem;
      return false;
    } catch (_) {
      return true;
    }
  }

  static bool _isNetworkError(Object error) {
    final msg = error.toString().toLowerCase();
    return error is SocketException ||
        error is http.ClientException ||
        msg.contains('failed to fetch') ||
        msg.contains('networkerror') ||
        msg.contains('xmlhttprequest') ||
        msg.contains('connection refused') ||
        msg.contains('timed out');
  }

  static Future<http.Response> _getWithFallback(String path) async {
    Object? lastError;
    for (final base in _candidateBaseUrls()) {
      try {
        final res = await http.get(Uri.parse('$base$path')).timeout(_timeout);
        _activeBaseUrl = base;
        return res;
      } catch (e) {
        lastError = e;
        if (!_isNetworkError(e)) rethrow;
      }
    }
    throw lastError ?? SocketException('Cannot reach backend');
  }

  static Future<http.Response> _postWithFallback(
    String path,
    Map<String, dynamic> payload, {
    Duration? timeout,
  }) async {
    Object? lastError;
    for (final base in _candidateBaseUrls()) {
      try {
        final res = await http
            .post(
              Uri.parse('$base$path'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode(payload),
            )
            .timeout(timeout ?? _timeout);
        _activeBaseUrl = base;
        return res;
      } catch (e) {
        lastError = e;
        if (!_isNetworkError(e)) rethrow;
      }
    }
    throw lastError ?? SocketException('Cannot reach backend');
  }

  static String get baseUrl {
    final urls = _candidateBaseUrls();
    return urls.isEmpty ? 'http://127.0.0.1:8000' : urls.first;
  }

  // ── Health check ───────────────────────────────────────────────────────────
  static Future<bool> isServerReachable() async {
    try {
      final res = await _getWithFallback('/health');
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  // ── Enroll student ─────────────────────────────────────────────────────────
  static Future<Map<String, dynamic>> enrollStudent({
    required String studentId,
    required String name,
    required String email,
    required String college,
    required String course,
    required String aadhaarNumber,
    required String faceImageBase64,
    required List<String> livenessFrames,
    required List<List<double>> behavioralSamples,
  }) async {
    try {
      final res = await _postWithFallback('/api/enroll', {
        'student_id': studentId,
        'name': name,
        'email': email,
        'college': college,
        'course': course,
        'aadhaar_number': aadhaarNumber,
        'face_image_base64': faceImageBase64,
        'liveness_frames': livenessFrames,
        'behavioral_samples': behavioralSamples,
      });

      return jsonDecode(res.body) as Map<String, dynamic>;
    } catch (e) {
      if (_isNetworkError(e)) {
        return {
          'success': false,
          'error': 'Cannot reach server. Tried: ${_candidateBaseUrls().join(', ')}'
        };
      }
      return {'success': false, 'error': e.toString()};
    }
  }

  // ── Verify student at exam entry ───────────────────────────────────────────
  static Future<Map<String, dynamic>> verifyStudent({
    required String studentId,
    required String examId,
    required String faceImageBase64,
  }) async {
    try {
      final res = await _postWithFallback('/api/verify', {
        'student_id': studentId,
        'exam_id': examId,
        'face_image_base64': faceImageBase64,
        // Compatibility key for backends that expect frame naming.
        'face_frame_base64': faceImageBase64,
      });

      return jsonDecode(res.body) as Map<String, dynamic>;
    } catch (e) {
      if (_isNetworkError(e)) {
        return {
          'cleared': false,
          'error': 'Cannot reach server. Tried: ${_candidateBaseUrls().join(', ')}'
        };
      }
      return {'cleared': false, 'error': e.toString()};
    }
  }

  // ── Monitor student during exam (called every 10 min) ──────────────────────
  static Future<Map<String, dynamic>> monitorStudent({
    required String studentId,
    required String examId,
    required String faceFrameBase64,
    required List<double> behavioralSample,
    bool faceAbsent = false,
    bool multipleFaces = false,
  }) async {
    try {
      final res = await _postWithFallback('/api/monitor', {
        'student_id': studentId,
        'exam_id': examId,
        'face_frame_base64': faceFrameBase64,
        'behavioral_sample': behavioralSample,
        'face_absent': faceAbsent,
        'multiple_faces': multipleFaces,
      });

      return jsonDecode(res.body) as Map<String, dynamic>;
    } catch (e) {
      if (_isNetworkError(e)) {
        return {
          'fraud_score': 0,
          'flag_level': 'clean',
          'error': 'server_unreachable: tried ${_candidateBaseUrls().join(', ')}'
        };
      }
      return {'fraud_score': 0, 'flag_level': 'clean', 'error': e.toString()};
    }
  }

  // ── Generate report after exam ends ───────────────────────────────────────
  static Future<Map<String, dynamic>> generateReport({
    required String examId,
  }) async {
    try {
      final res = await _postWithFallback(
        '/api/generate-report',
        {'exam_id': examId},
        timeout: const Duration(seconds: 60),
      );

      return jsonDecode(res.body) as Map<String, dynamic>;
    } catch (e) {
      if (_isNetworkError(e)) {
        return {
          'success': false,
          'error': 'Cannot reach server. Tried: ${_candidateBaseUrls().join(', ')}'
        };
      }
      return {'success': false, 'error': e.toString()};
    }
  }

  // ── AI: generate questions ────────────────────────────────────────────────
  static Future<List<Map<String, dynamic>>> generateQuestions({
    required String topic,
    int mcqCount    = 5,
    int textCount   = 2,
    String difficulty = 'medium',
  }) async {
    final res = await _postWithFallback(
      '/api/generate-questions',
      {
        'topic':      topic,
        'mcq_count':  mcqCount,
        'text_count': textCount,
        'difficulty': difficulty,
      },
      timeout: const Duration(seconds: 60),
    );
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    if (data['success'] != true) {
      throw Exception(data['error'] ?? 'Question generation failed');
    }
    return List<Map<String, dynamic>>.from(
      (data['questions'] as List).map((q) => Map<String, dynamic>.from(q as Map)),
    );
  }

  // ── AI: grade a single text answer ────────────────────────────────────────
  static Future<Map<String, dynamic>> gradeAnswer({
    required String question,
    required String studentAnswer,
    required String modelAnswer,
    required int maxMarks,
  }) async {
    try {
      final res = await _postWithFallback(
        '/api/grade-answer',
        {
          'question':       question,
          'student_answer': studentAnswer,
          'model_answer':   modelAnswer,
          'max_marks':      maxMarks,
        },
        timeout: const Duration(seconds: 30),
      );
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final score = ((data['score'] ?? 0) as num).toInt().clamp(0, maxMarks);
      return {'score': score, 'feedback': data['feedback'] ?? ''};
    } catch (_) {
      return {'score': 0, 'feedback': 'Grading unavailable.'};
    }
  }

  // ── AI: student performance insights ─────────────────────────────────────
  static Future<Map<String, dynamic>> getStudentInsights({
    required Map<String, dynamic> performanceData,
  }) async {
    try {
      final res = await _postWithFallback(
        '/api/student-insights',
        performanceData,
        timeout: const Duration(seconds: 45),
      );
      return jsonDecode(res.body) as Map<String, dynamic>;
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  // ── AI: class performance summary for teacher ─────────────────────────────
  static Future<Map<String, dynamic>> getClassSummary({
    required String examId,
    required String examTitle,
    required int studentCount,
    required double classAvg,
    required double passRate,
    required List<Map<String, dynamic>> questionStats,
  }) async {
    try {
      final res = await _postWithFallback(
        '/api/class-summary',
        {
          'exam_id':       examId,
          'exam_title':    examTitle,
          'student_count': studentCount,
          'class_avg':     classAvg,
          'pass_rate':     passRate,
          'question_stats': questionStats,
        },
        timeout: const Duration(seconds: 60),
      );
      return jsonDecode(res.body) as Map<String, dynamic>;
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  // ── AI: detect plagiarism across student answers ──────────────────────────
  static Future<Map<String, dynamic>> detectPlagiarism({
    required String examId,
    required List<Map<String, dynamic>> questions,
    required List<Map<String, dynamic>> studentAnswers,
  }) async {
    try {
      final res = await _postWithFallback(
        '/api/detect-plagiarism',
        {
          'exam_id': examId,
          'questions': questions,
          'student_answers': studentAnswers,
        },
        timeout: const Duration(seconds: 60),
      );
      return jsonDecode(res.body) as Map<String, dynamic>;
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  // ── Send report email to teacher ───────────────────────────────────────────
  static Future<Map<String, dynamic>> sendReportEmail({
    required String examId,
    required String teacherEmail,
  }) async {
    try {
      final res = await _postWithFallback('/api/send-report-email', {
        'exam_id': examId,
        'teacher_email': teacherEmail,
      });

      return jsonDecode(res.body) as Map<String, dynamic>;
    } catch (e) {
      return {'email_sent': false, 'error': e.toString()};
    }
  }
}
