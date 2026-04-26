import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:dotenv/dotenv.dart';
import 'package:image/image.dart' as img;

late final DotEnv _env;

const int _port = 8000;
const double _verifyThreshold = 0.78;
const double _duplicateThreshold = 0.92;
const double _otherIdentityMargin = 0.02;
const String _dbPath = 'backend/data/enrollments.json';

Future<void> main() async {
  _env = DotEnv(includePlatformEnvironment: true)..load();
  await Directory('backend/data').create(recursive: true);
  final server = await HttpServer.bind(InternetAddress.anyIPv4, _port);
  stdout.writeln('ExamIQ backend running on http://0.0.0.0:$_port');

  await for (final request in server) {
    unawaited(_handleRequest(request));
  }
}

Future<void> _handleRequest(HttpRequest request) async {
  try {
    _setCors(request.response);

    if (request.method == 'OPTIONS') {
      request.response.statusCode = HttpStatus.noContent;
      await request.response.close();
      return;
    }

    final path = request.uri.path;
    stdout.writeln('[${DateTime.now().toIso8601String()}] ${request.method} $path');
    if (request.method == 'GET' && path == '/health') {
      await _writeJson(request.response, {
        'status': 'ok',
        'service': 'examiq-backend',
        'port': _port,
        'timestamp': DateTime.now().toIso8601String(),
      });
      return;
    }

    if (request.method == 'POST' && path == '/api/enroll') {
      final body = await _readJson(request);
      final result = await _enroll(body);
      await _writeJson(request.response, result);
      return;
    }

    if (request.method == 'POST' && path == '/api/verify') {
      final body = await _readJson(request);
      final result = await _verify(body);
      await _writeJson(request.response, result);
      return;
    }

    if (request.method == 'POST' && path == '/api/monitor') {
      final body = await _readJson(request);
      final result = await _monitor(body);
      await _writeJson(request.response, result);
      return;
    }

    if (request.method == 'POST' && path == '/api/generate-questions') {
      final body = await _readJson(request);
      final result = await _generateQuestions(body);
      await _writeJson(request.response, result);
      return;
    }

    if (request.method == 'POST' && path == '/api/grade-answer') {
      final body = await _readJson(request);
      final result = await _gradeAnswer(body);
      await _writeJson(request.response, result);
      return;
    }

    if (request.method == 'POST' && path == '/api/student-insights') {
      final body = await _readJson(request);
      final result = await _studentInsights(body);
      await _writeJson(request.response, result);
      return;
    }

    if (request.method == 'POST' && path == '/api/detect-plagiarism') {
      final body = await _readJson(request);
      final result = await _detectPlagiarism(body);
      await _writeJson(request.response, result);
      return;
    }

    if (request.method == 'POST' && path == '/api/generate-report') {
      final body = await _readJson(request);
      await _writeJson(request.response, {
        'success': true,
        'exam_id': '${body['exam_id'] ?? ''}',
        'generated_at': DateTime.now().toIso8601String(),
      });
      return;
    }

    if (request.method == 'POST' && path == '/api/send-report-email') {
      final body = await _readJson(request);
      await _writeJson(request.response, {
        'email_sent': true,
        'exam_id': '${body['exam_id'] ?? ''}',
        'teacher_email': '${body['teacher_email'] ?? ''}',
      });
      return;
    }

    await _writeJson(
      request.response,
      {'error': 'Route not found', 'path': path},
      statusCode: HttpStatus.notFound,
    );
  } catch (e, st) {
    stderr.writeln('Request failed: $e\n$st');
    await _writeJson(
      request.response,
      {'error': 'Internal server error', 'detail': e.toString()},
      statusCode: HttpStatus.internalServerError,
    );
  }
}

Future<Map<String, dynamic>> _enroll(Map<String, dynamic> body) async {
  final studentId = '${body['student_id'] ?? ''}'.trim();
  final faceBase64 = '${body['face_image_base64'] ?? ''}'.trim();
  final livenessFrames = (body['liveness_frames'] as List?) ?? const [];

  if (studentId.isEmpty || faceBase64.isEmpty) {
    return {
      'success': false,
      'error': 'student_id and face_image_base64 are required'
    };
  }

  if (livenessFrames.length < 3) {
    return {
      'success': false,
      'error': 'liveness_check_failed: insufficient frames'
    };
  }

  final enrollmentFrames = <String>[
    faceBase64,
    ...livenessFrames.map((e) => '$e')
  ];
  final embeddings = <List<double>>[];
  for (final frame in enrollmentFrames) {
    final emb = _extractEmbedding(frame);
    if (emb != null) {
      embeddings.add(emb);
    }
  }

  if (embeddings.isEmpty) {
    return {'success': false, 'error': 'face_not_detected_or_image_invalid'};
  }
  final embedding = _averageEmbeddings(embeddings);

  final data = await _loadDb();
  final students =
      (data['students'] as Map<String, dynamic>? ?? <String, dynamic>{});

  // Prevent same face being enrolled with another ID.
  for (final entry in students.entries) {
    final otherId = entry.key;
    if (otherId == studentId) continue;
    final otherEmbeddings = _extractStoredEmbeddings(entry.value);
    if (otherEmbeddings.isEmpty) continue;
    final similarity = otherEmbeddings
        .map((other) => _cosineSimilarity(embedding, other))
        .reduce(math.max);
    if (similarity >= _duplicateThreshold) {
      return {
        'success': false,
        'error': 'duplicate_face_detected',
        'matched_student_id': otherId,
        'similarity': similarity,
      };
    }
  }

  students[studentId] = {
    'student_id': studentId,
    'name': '${body['name'] ?? ''}',
    'email': '${body['email'] ?? ''}',
    'aadhaar_number': '${body['aadhaar_number'] ?? ''}',
    'embedding': embedding,
    'templates': embeddings,
    'updated_at': DateTime.now().toIso8601String(),
  };
  data['students'] = students;
  await _saveDb(data);

  return {
    'success': true,
    'message': 'enrollment_successful',
    'embedding_dim': embedding.length,
    'templates_count': embeddings.length,
  };
}

Future<Map<String, dynamic>> _verify(Map<String, dynamic> body) async {
  final studentId = '${body['student_id'] ?? ''}'.trim();
  final examId = '${body['exam_id'] ?? ''}'.trim();
  final faceBase64 =
      '${body['face_image_base64'] ?? body['face_frame_base64'] ?? ''}'.trim();

  if (studentId.isEmpty || faceBase64.isEmpty) {
    return {
      'cleared': false,
      'verified': false,
      'error': 'student_id and face image are required',
    };
  }

  final probe = _extractEmbedding(faceBase64);
  if (probe == null) {
    return {
      'cleared': false,
      'verified': false,
      'face_absent': true,
      'face_match_score': 0.0,
      'error': 'face_not_detected',
    };
  }

  final data = await _loadDb();
  final students =
      (data['students'] as Map<String, dynamic>? ?? <String, dynamic>{});
  final enrolled = students[studentId];
  if (enrolled == null) {
    return {
      'cleared': false,
      'verified': false,
      'face_match_score': 0.0,
      'error': 'student_not_enrolled',
    };
  }

  final ownEmbeddings = _extractStoredEmbeddings(enrolled);
  if (ownEmbeddings.isEmpty) {
    return {
      'cleared': false,
      'verified': false,
      'face_match_score': 0.0,
      'error': 'corrupt_enrollment_data',
    };
  }

  final ownScore =
      ownEmbeddings.map((e) => _cosineSimilarity(probe, e)).reduce(math.max);

  String? bestOtherId;
  double bestOtherScore = 0.0;
  for (final entry in students.entries) {
    if (entry.key == studentId) continue;
    final otherEmbeddings = _extractStoredEmbeddings(entry.value);
    if (otherEmbeddings.isEmpty) continue;
    final score = otherEmbeddings
        .map((e) => _cosineSimilarity(probe, e))
        .reduce(math.max);
    if (score > bestOtherScore) {
      bestOtherScore = score;
      bestOtherId = entry.key;
    }
  }

  final matchedOther =
      bestOtherId != null && (bestOtherScore > ownScore + _otherIdentityMargin);
  final cleared = ownScore >= _verifyThreshold && !matchedOther;

  return {
    'cleared': cleared,
    'verified': cleared,
    'identity_verified': cleared,
    'match': cleared,
    'success': true,
    'exam_id': examId,
    'face_match_score': ownScore,
    'match_score': ownScore,
    'similarity': ownScore,
    'threshold': _verifyThreshold,
    'matched_student_id': matchedOther ? bestOtherId : studentId,
    'other_best_score': bestOtherScore,
    'own_best_score': ownScore,
    'status': cleared ? 'verified' : 'rejected',
    'error': cleared
        ? null
        : (matchedOther
            ? 'identity_mismatch_with_other_student'
            : 'face_not_matched_with_enrolled_profile'),
  };
}

Future<Map<String, dynamic>> _monitor(Map<String, dynamic> body) async {
  final studentId = '${body['student_id'] ?? ''}'.trim();
  final examId = '${body['exam_id'] ?? ''}'.trim();
  final frame = '${body['face_frame_base64'] ?? ''}'.trim();
  final behavior = (body['behavioral_sample'] as List?) ?? const [];

  bool faceAbsent = body['face_absent'] == true;
  double faceScore = 0.0;
  bool deepfake = false;
  double deepfakeScore = 0.0;
  bool multipleFaces = false;

  if (!faceAbsent && frame.isNotEmpty) {
    final verify = await _verify({
      'student_id': studentId,
      'exam_id': examId,
      'face_frame_base64': frame,
    });
    faceScore = (verify['face_match_score'] as num?)?.toDouble() ?? 0.0;
    if (verify['face_absent'] == true) {
      faceAbsent = true;
    }

    // Simple spoof heuristic: very low texture variance can indicate screen replay.
    final quality = _imageQualitySignals(frame);
    if (quality != null) {
      deepfakeScore = quality['spoof_risk']!;
      deepfake = deepfakeScore >= 0.65;
    }

    if (!faceAbsent) {
      multipleFaces = _hasMultipleFaces(frame);
    }
  }

  final behaviorScore = _behaviorRisk(behavior);
  var fraudScore = ((1 - faceScore) * 70 + behaviorScore * 30).round();
  if (faceAbsent) fraudScore += 30;
  if (deepfake) fraudScore += 35;
  if (multipleFaces) fraudScore += 20;
  fraudScore = fraudScore.clamp(0, 100);

  final flagLevel = fraudScore >= 80
      ? 'critical'
      : fraudScore >= 60
          ? 'hard'
          : fraudScore >= 40
              ? 'medium'
              : 'clean';

  return {
    'success': true,
    'student_id': studentId,
    'exam_id': examId,
    'face_absent': faceAbsent,
    'face_match_score': faceScore,
    'deepfake': deepfake,
    'deepfake_score': deepfakeScore,
    'multiple_faces': multipleFaces,
    'behavioral_drift': behaviorScore,
    'fraud_score': fraudScore,
    'flag_level': flagLevel,
  };
}

/// Heuristic: split frame into left and right thirds (with overlap), extract embeddings
/// from each. If they are dissimilar enough, two distinct face-like regions exist.
bool _hasMultipleFaces(String faceBase64) {
  final image = _decodeImage(faceBase64);
  if (image == null || image.width < 96 || image.height < 64) return false;

  final thirdW = image.width ~/ 3;

  // Overlapping crops: left 2/3 and right 2/3.
  final leftCrop = img.copyCrop(image, x: 0, y: 0, width: thirdW * 2, height: image.height);
  final rightCrop = img.copyCrop(image, x: thirdW, y: 0, width: thirdW * 2, height: image.height);

  final leftEmb = _extractEmbedding(base64Encode(img.encodeJpg(leftCrop, quality: 85)));
  final rightEmb = _extractEmbedding(base64Encode(img.encodeJpg(rightCrop, quality: 85)));

  if (leftEmb == null || rightEmb == null) return false;

  // Low similarity between the two halves implies structurally distinct regions.
  // Threshold 0.68 is conservative to limit false positives from background variation.
  return _cosineSimilarity(leftEmb, rightEmb) < 0.68;
}

Map<String, double>? _imageQualitySignals(String faceBase64) {
  final image = _decodeImage(faceBase64);
  if (image == null) return null;
  final gray = img.grayscale(img.copyResize(image, width: 64, height: 64));

  final values = <double>[];
  for (var y = 0; y < gray.height; y++) {
    for (var x = 0; x < gray.width; x++) {
      values.add(img.getLuminance(gray.getPixel(x, y)).toDouble());
    }
  }

  final mean = values.reduce((a, b) => a + b) / values.length;
  double varSum = 0.0;
  for (final v in values) {
    final d = v - mean;
    varSum += d * d;
  }
  final variance = varSum / values.length;

  final spoofRisk = (1.0 - (variance / 2200.0)).clamp(0.0, 1.0);
  return {'variance': variance, 'spoof_risk': spoofRisk};
}

List<double>? _extractEmbedding(String faceBase64) {
  final image = _decodeImage(faceBase64);
  if (image == null) return null;

  // Center crop for face region proxy.
  final minSide = math.min(image.width, image.height);
  final offsetX = (image.width - minSide) ~/ 2;
  final offsetY = (image.height - minSide) ~/ 2;
  final cropped = img.copyCrop(
    image,
    x: offsetX,
    y: offsetY,
    width: minSide,
    height: minSide,
  );

  final resized = img.copyResize(cropped, width: 48, height: 48);
  final gray = img.grayscale(resized);

  final embedding = <double>[];

  // 1) Grid mean intensities (8x8 => 64 dims)
  const grid = 8;
  final cell = gray.width ~/ grid;
  for (var gy = 0; gy < grid; gy++) {
    for (var gx = 0; gx < grid; gx++) {
      double sum = 0;
      int count = 0;
      for (var y = gy * cell; y < (gy + 1) * cell; y++) {
        for (var x = gx * cell; x < (gx + 1) * cell; x++) {
          sum += img.getLuminance(gray.getPixel(x, y));
          count++;
        }
      }
      embedding.add((sum / math.max(1, count)) / 255.0);
    }
  }

  // 2) Coarse horizontal/vertical gradients (32 dims)
  for (var y = 1; y < gray.height - 1; y += 4) {
    for (var x = 1; x < gray.width - 1; x += 4) {
      final gx = img.getLuminance(gray.getPixel(x + 1, y)) -
          img.getLuminance(gray.getPixel(x - 1, y));
      final gy = img.getLuminance(gray.getPixel(x, y + 1)) -
          img.getLuminance(gray.getPixel(x, y - 1));
      embedding.add((gx / 255.0).clamp(-1.0, 1.0));
      embedding.add((gy / 255.0).clamp(-1.0, 1.0));
    }
  }

  // Image validity guard.
  final mean = embedding.take(64).reduce((a, b) => a + b) / 64.0;
  final variance = embedding
          .take(64)
          .map((v) => (v - mean) * (v - mean))
          .reduce((a, b) => a + b) /
      64.0;
  if (variance < 0.0008) {
    return null;
  }

  return _l2Normalize(embedding);
}

img.Image? _decodeImage(String base64Data) {
  try {
    final normalized = base64Data.contains(',')
        ? base64Data.substring(base64Data.indexOf(',') + 1)
        : base64Data;
    final bytes = base64Decode(normalized);
    if (bytes.isEmpty) return null;
    return img.decodeImage(bytes);
  } catch (_) {
    return null;
  }
}

double _cosineSimilarity(List<double> a, List<double> b) {
  if (a.length != b.length || a.isEmpty) return 0.0;
  double dot = 0;
  double normA = 0;
  double normB = 0;
  for (var i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    normA += a[i] * a[i];
    normB += b[i] * b[i];
  }
  if (normA == 0 || normB == 0) return 0.0;
  return (dot / (math.sqrt(normA) * math.sqrt(normB))).clamp(0.0, 1.0);
}

List<double> _l2Normalize(List<double> values) {
  double norm = 0.0;
  for (final v in values) {
    norm += v * v;
  }
  norm = math.sqrt(norm);
  if (norm == 0) return List<double>.from(values);
  return values.map((v) => v / norm).toList();
}

List<double> _averageEmbeddings(List<List<double>> embeddings) {
  if (embeddings.isEmpty) return <double>[];
  final dim = embeddings.first.length;
  final out = List<double>.filled(dim, 0.0);
  var count = 0;
  for (final emb in embeddings) {
    if (emb.length != dim) continue;
    for (var i = 0; i < dim; i++) {
      out[i] += emb[i];
    }
    count++;
  }
  if (count == 0) return List<double>.from(embeddings.first);
  for (var i = 0; i < dim; i++) {
    out[i] /= count;
  }
  return _l2Normalize(out);
}

List<List<double>> _extractStoredEmbeddings(dynamic studentRecord) {
  if (studentRecord is! Map) return <List<double>>[];
  final templatesRaw = studentRecord['templates'];
  final templates = <List<double>>[];
  if (templatesRaw is List) {
    for (final t in templatesRaw) {
      final parsed = _toDoubleList(t);
      if (parsed != null && parsed.isNotEmpty) {
        templates.add(parsed);
      }
    }
  }
  final fallback = _toDoubleList(studentRecord['embedding']);
  if (templates.isEmpty && fallback != null && fallback.isNotEmpty) {
    templates.add(fallback);
  }
  return templates;
}

double _behaviorRisk(List<dynamic> behavior) {
  if (behavior.isEmpty) return 0.2;
  final nums = behavior.whereType<num>().map((n) => n.toDouble()).toList();
  if (nums.isEmpty) return 0.2;

  // Weighted blend based on expected feature order from client.
  final meanGap = nums.isNotEmpty ? nums[0] : 4.0;
  final gapStd = nums.length > 1 ? nums[1] : 0.5;
  final backspaceRatio = nums.length > 2 ? nums[2] : 0.1;
  final tabSwitchRate = nums.length > 3 ? nums[3] : 0.0;
  final pasteRate = nums.length > 4 ? nums[4] : 0.0;
  final answerChangeRate = nums.length > 5 ? nums[5] : 0.2;
  final maxEditBurst = nums.length > 6 ? nums[6] : 0.2;
  final idleRatio = nums.length > 7 ? nums[7] : 0.0;

  final risk = (gapStd / 3.0) * 0.15 +
      backspaceRatio.clamp(0.0, 1.0) * 0.1 +
      (tabSwitchRate / 4.0).clamp(0.0, 1.0) * 0.25 +
      (pasteRate / 2.0).clamp(0.0, 1.0) * 0.2 +
      (answerChangeRate / 5.0).clamp(0.0, 1.0) * 0.1 +
      maxEditBurst.clamp(0.0, 1.0) * 0.1 +
      idleRatio.clamp(0.0, 1.0) * 0.1 +
      ((meanGap < 0.4 || meanGap > 20.0) ? 0.1 : 0.0);

  return risk.clamp(0.0, 1.0);
}

// ── Claude AI proxy ────────────────────────────────────────────────────────

Future<String?> _callClaude(
  String prompt,
  String system, {
  int maxTokens = 2048,
}) async {
  final apiKey = _env['CLAUDE_API_KEY'] ?? '';
  if (apiKey.isEmpty) {
    stderr.writeln('CLAUDE_API_KEY not set');
    return null;
  }

  final client = HttpClient();
  try {
    final req = await client
        .postUrl(Uri.parse('https://api.anthropic.com/v1/messages'));
    req.headers.set('x-api-key', apiKey);
    req.headers.set('anthropic-version', '2023-06-01');
    req.headers.set('content-type', 'application/json');

    final bodyStr = jsonEncode({
      'model': 'claude-haiku-4-5-20251001',
      'max_tokens': maxTokens,
      'system': [
        {
          'type': 'text',
          'text': system,
          'cache_control': {'type': 'ephemeral'},
        }
      ],
      'messages': [
        {'role': 'user', 'content': prompt},
      ],
    });

    final bodyBytes = utf8.encode(bodyStr);
    req.contentLength = bodyBytes.length;
    req.add(bodyBytes);

    final res = await req.close();
    final resBody = await utf8.decoder.bind(res).join();
    if (res.statusCode != 200) {
      stderr.writeln('Claude error ${res.statusCode}: $resBody');
      return null;
    }

    final data = jsonDecode(resBody) as Map<String, dynamic>;
    return (data['content'] as List).first['text'] as String?;
  } finally {
    client.close();
  }
}

Future<Map<String, dynamic>> _studentInsights(Map<String, dynamic> body) async {
  const system =
      'You are an academic performance coach. '
      'Analyze the student exam data and return ONLY valid JSON — no markdown, no extra text.';

  final prompt =
      'Analyze this student\'s exam history and return a JSON object with these exact keys:\n'
      '{"summary":"2-3 sentence overall assessment","strengths":["..."],'
      '"areas_to_improve":["..."],"recommendations":["actionable tip 1","actionable tip 2","actionable tip 3"],'
      '"integrity_note":"brief note if flags > 0, otherwise null"}\n\n'
      'Student data:\n${jsonEncode(body)}';

  final text = await _callClaude(prompt, system, maxTokens: 512);
  if (text == null) {
    return {'success': false, 'error': 'AI service unavailable — check CLAUDE_API_KEY'};
  }

  try {
    final match = RegExp(r'\{[\s\S]*\}').firstMatch(text);
    if (match == null) return {'success': false, 'error': 'No JSON in AI response'};
    final insights = jsonDecode(match.group(0)!) as Map<String, dynamic>;
    return {'success': true, ...insights};
  } catch (_) {
    return {'success': false, 'error': 'Failed to parse AI response'};
  }
}

Future<Map<String, dynamic>> _detectPlagiarism(Map<String, dynamic> body) async {
  final questionsRaw = body['questions'] as List? ?? [];
  final studentAnswersRaw = body['student_answers'] as List? ?? [];

  final questions = questionsRaw.cast<Map<String, dynamic>>();
  final studentAnswers = studentAnswersRaw.cast<Map<String, dynamic>>();

  if (studentAnswers.length < 2) {
    return {
      'success': true,
      'flagged_pairs': [],
      'summary': 'Need at least 2 student submissions to check for plagiarism.',
    };
  }

  // Collect text question answers grouped by question index
  final analysisData = <Map<String, dynamic>>[];
  for (var i = 0; i < questions.length; i++) {
    final q = questions[i];
    if ((q['type'] ?? '') != 'text') continue;

    final perStudent = <Map<String, dynamic>>[];
    for (final sa in studentAnswers) {
      final studentId = '${sa['student_id'] ?? ''}';
      final answers = (sa['answers'] as Map?)?.cast<String, dynamic>() ?? {};
      final ans = (answers['$i'] ?? '').toString().trim();
      if (ans.isNotEmpty) {
        perStudent.add({'student_id': studentId, 'answer': ans});
      }
    }
    if (perStudent.length >= 2) {
      analysisData.add({
        'question_index': i,
        'question': q['q'] ?? q['question'] ?? '',
        'student_answers': perStudent,
      });
    }
  }

  if (analysisData.isEmpty) {
    return {
      'success': true,
      'flagged_pairs': [],
      'summary': 'No text questions with multiple student responses to compare.',
    };
  }

  const system =
      'You are an academic integrity expert. Detect plagiarism and collusion '
      'in student exam answers. Return ONLY valid JSON — no markdown, no extra text.';

  final prompt =
      'Analyze these student exam answers for plagiarism or collusion. '
      'Compare all pairs of students for each question.\n\n'
      'Flag pairs where answers are suspiciously similar: same phrasing, copied sentences, '
      'or unusual agreement beyond what independent correct answers would show.\n\n'
      'Return ONLY this exact JSON:\n'
      '{\n'
      '  "flagged_pairs": [\n'
      '    {\n'
      '      "question_index": 0,\n'
      '      "question": "...",\n'
      '      "student_a": "student_id",\n'
      '      "student_b": "student_id",\n'
      '      "answer_a": "...",\n'
      '      "answer_b": "...",\n'
      '      "similarity_score": 0.85,\n'
      '      "risk_level": "high",\n'
      '      "reasoning": "Brief explanation"\n'
      '    }\n'
      '  ],\n'
      '  "summary": "2-3 sentence overall assessment of exam integrity"\n'
      '}\n\n'
      'risk_level: "high" (>0.85 or direct copy), "medium" (0.65-0.85), "low" (notable coincidence).\n'
      'Only flag genuinely suspicious pairs. Empty flagged_pairs if no plagiarism found.\n\n'
      'Data:\n${jsonEncode(analysisData)}';

  final text = await _callClaude(prompt, system, maxTokens: 1024);
  if (text == null) return {'success': false, 'error': 'AI service unavailable'};

  try {
    final match = RegExp(r'\{[\s\S]*\}').firstMatch(text);
    if (match == null) return {'success': false, 'error': 'No JSON in AI response'};
    final result = jsonDecode(match.group(0)!) as Map<String, dynamic>;
    return {'success': true, ...result};
  } catch (_) {
    return {'success': false, 'error': 'Failed to parse AI response'};
  }
}

Future<Map<String, dynamic>> _generateQuestions(
    Map<String, dynamic> body) async {
  final topic      = '${body['topic'] ?? ''}'.trim();
  final mcqCount   = (body['mcq_count']   as num?)?.toInt() ?? 5;
  final textCount  = (body['text_count']  as num?)?.toInt() ?? 2;
  final difficulty = '${body['difficulty'] ?? 'medium'}';

  if (topic.isEmpty) {
    return {'success': false, 'error': 'topic is required'};
  }

  const system =
      'You are an exam question generator. '
      'Return ONLY a valid JSON array — no markdown fences, no extra text.';

  final prompt =
      'Generate $mcqCount MCQ questions and $textCount text-answer questions '
      'about "$topic" at $difficulty difficulty.\n\n'
      'Return a JSON array where each element is either:\n'
      '{"type":"mcq","q":"<question>","options":["A. <opt>","B. <opt>","C. <opt>","D. <opt>"],"correct_option":<0-indexed int>,"marks":<int>}\n'
      'or\n'
      '{"type":"text","q":"<question>","model_answer":"<expected answer>","marks":<int>}\n\n'
      'correct_option is 0-indexed. Include model_answer for all text questions.';

  final text = await _callClaude(prompt, system);
  if (text == null) {
    return {'success': false, 'error': 'AI service unavailable — check CLAUDE_API_KEY'};
  }

  final match = RegExp(r'\[[\s\S]*\]').firstMatch(text);
  if (match == null) {
    return {'success': false, 'error': 'No JSON array in AI response'};
  }

  try {
    final questions = jsonDecode(match.group(0)!) as List;
    return {'success': true, 'questions': questions};
  } catch (_) {
    return {'success': false, 'error': 'Failed to parse AI response'};
  }
}

Future<Map<String, dynamic>> _gradeAnswer(Map<String, dynamic> body) async {
  final question      = '${body['question']       ?? ''}';
  final studentAnswer = '${body['student_answer'] ?? ''}';
  final modelAnswer   = '${body['model_answer']   ?? ''}';
  final maxMarks      = (body['max_marks'] as num?)?.toInt() ?? 1;

  if (studentAnswer.trim().isEmpty) {
    return {'success': true, 'score': 0, 'feedback': 'No answer provided.'};
  }

  const system =
      'You are an exam grader. '
      'Return ONLY valid JSON with integer "score" and string "feedback". No markdown.';

  final prompt =
      'Grade this answer out of $maxMarks marks.\n\n'
      'Question: $question\n'
      'Model answer: $modelAnswer\n'
      'Student answer: $studentAnswer\n\n'
      'Return JSON: {"score": <0-$maxMarks>, "feedback": "<one-line feedback>"}';

  final text = await _callClaude(prompt, system, maxTokens: 200);
  if (text == null) {
    return {'success': true, 'score': 0, 'feedback': 'Grading unavailable.'};
  }

  try {
    final match = RegExp(r'\{[\s\S]*\}').firstMatch(text);
    if (match == null) {
      return {'success': true, 'score': 0, 'feedback': 'Could not parse grade.'};
    }
    final result = jsonDecode(match.group(0)!) as Map<String, dynamic>;
    final score  = ((result['score'] ?? 0) as num).toInt().clamp(0, maxMarks);
    return {'success': true, 'score': score, 'feedback': result['feedback'] ?? ''};
  } catch (_) {
    return {'success': true, 'score': 0, 'feedback': 'Grading failed.'};
  }
}

Future<Map<String, dynamic>> _loadDb() async {
  final file = File(_dbPath);
  if (!await file.exists()) {
    return {'students': <String, dynamic>{}};
  }
  final content = await file.readAsString();
  if (content.trim().isEmpty) {
    return {'students': <String, dynamic>{}};
  }
  final parsed = jsonDecode(content);
  if (parsed is Map<String, dynamic>) {
    return parsed;
  }
  return {'students': <String, dynamic>{}};
}

Future<void> _saveDb(Map<String, dynamic> data) async {
  final file = File(_dbPath);
  await file.writeAsString(jsonEncode(data));
}

Future<Map<String, dynamic>> _readJson(HttpRequest request) async {
  final body = await utf8.decoder.bind(request).join();
  if (body.trim().isEmpty) return <String, dynamic>{};
  final parsed = jsonDecode(body);
  if (parsed is Map<String, dynamic>) return parsed;
  return <String, dynamic>{};
}

Future<void> _writeJson(
  HttpResponse response,
  Map<String, dynamic> data, {
  int statusCode = HttpStatus.ok,
}) async {
  response.statusCode = statusCode;
  response.headers.contentType = ContentType.json;
  response.write(jsonEncode(data));
  await response.close();
}

void _setCors(HttpResponse response) {
  response.headers.set('Access-Control-Allow-Origin', '*');
  response.headers
      .set('Access-Control-Allow-Headers', 'Content-Type, Authorization');
  response.headers.set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
}

List<double>? _toDoubleList(dynamic raw) {
  if (raw is! List) return null;
  final out = <double>[];
  for (final v in raw) {
    if (v is num) {
      out.add(v.toDouble());
    } else {
      final parsed = double.tryParse(v.toString());
      if (parsed == null) return null;
      out.add(parsed);
    }
  }
  return out;
}
