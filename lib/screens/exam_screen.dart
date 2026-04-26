import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import '../services/api_service.dart';
import '../services/web_exam_guard.dart';
import 'report_screen.dart';

class ExamScreen extends StatefulWidget {
  final String examId;
  final String studentId;
  final String examTitle;

  const ExamScreen({
    super.key,
    required this.examId,
    required this.studentId,
    required this.examTitle,
  });

  @override
  State<ExamScreen> createState() => _ExamScreenState();
}

class _ExamScreenState extends State<ExamScreen> with WidgetsBindingObserver {
  final _db = FirebaseFirestore.instance;

  // ── Camera ─────────────────────────────────────────────────────────────────
  CameraController? _cameraController;
  final GlobalKey _verifyPreviewKey = GlobalKey();
  bool _cameraReady = false;

  // ── Exam state ─────────────────────────────────────────────────────────────
  List<Map<String, dynamic>> _questions = [];
  Map<int, dynamic> _answers = {}; // questionIndex → answer (int for mcq, String for text)
  final Map<int, TextEditingController> _textAnswerControllers = {};
  final FocusNode _webAnswerFocusNode = FocusNode(debugLabel: 'web_answer_focus');
  int  _currentQuestion      = 0;
  bool _examLoading          = true;
  bool _examSubmitted        = false;
  bool _isSubmitting         = false;

  // ── Timer ──────────────────────────────────────────────────────────────────
  int    _totalSeconds    = 90 * 60; // default 90 min
  int    _secondsLeft     = 90 * 60;
  Timer? _examTimer;

  // ── Monitoring ─────────────────────────────────────────────────────────────
  Timer?  _monitorTimer;
  int     _currentFraudScore = 0;
  String  _currentFlagLevel  = 'clean';
  bool    _showFraudAlert    = false;
  String  _fraudAlertMessage = '';
  int     _monitorInterval   = 600; // 10 min in seconds — for demo set to 60
  int     _noFaceStreak      = 0;
  int     _identityRiskStreak = 0;

  // Behavioral tracking (dynamic)
  DateTime? _examStartedAt;
  DateTime? _lastActionAt;
  final List<double> _actionGaps = [];
  int _answerChangeCount = 0;
  int _textEditEvents = 0;
  int _backspaceCount = 0;
  int _pasteLikeEvents = 0;
  int _tabSwitchCount = 0;
  double _maxCharsInOneEdit = 0;
  DateTime? _lastClipboardWarnAt;
  bool _wasBackgroundedDuringExam = false;
  bool _tabSwitchDialogOpen = false;
  bool _tabSwitchTerminationDialogOpen = false;
  bool _pendingTabSwitchWarning = false;
  bool _showTabSwitchOverlay = false;
  String _tabSwitchOverlayMessage = '';
  static const int _maxAllowedTabSwitches = 3;
  DateTime? _lastTabSwitchAt;
  Timer? _visibilityGuardTimer;
  DateTime? _lastVisibilityTick;
  final WebExamGuard _webExamGuard = WebExamGuard();
  bool _webGuardActive = false;

  // ── Audio monitoring ───────────────────────────────────────────────────────
  final AudioRecorder _audioRecorder = AudioRecorder();
  Timer? _audioMonitorTimer;
  int _highAudioStreak = 0;
  static const double _audioAlertThreshold = -30.0; // dBFS — sustained noise

  // ── Entry verify state ─────────────────────────────────────────────────────
  bool   _entryVerified   = false;
  bool   _verifyingEntry  = true;
  String _verifyMessage   = 'Verifying your identity...';
  String? _cameraError;
  int _verifyAttempts = 3;
  int _verifyMinPositiveAttempts = 2;
  double _verifyMinScore = 0.72;
  bool _requireExplicitVerifyDecision = false;
  bool _allowServerFallbackWhenDown = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startWebGuard();
    _initCamera().then((_) => _verifyEntry());
    _loadExam();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _examTimer?.cancel();
    _monitorTimer?.cancel();
    _visibilityGuardTimer?.cancel();
    _stopAudioMonitoring();
    _audioRecorder.dispose();
    _webExamGuard.stop();
    _webGuardActive = false;
    _webAnswerFocusNode.dispose();
    _cameraController?.dispose();
    for (final c in _textAnswerControllers.values) {
      c.dispose();
    }
    _textAnswerControllers.clear();
    super.dispose();
  }

  TextEditingController _textControllerFor(int index) {
    return _textAnswerControllers.putIfAbsent(
      index,
      () => TextEditingController(
        text: (_answers[index] ?? '').toString(),
      ),
    );
  }

  int get _answeredCount {
    int count = 0;
    for (final q in _questions.asMap().entries) {
      final index = q.key;
      final question = q.value;
      final type = (question['type'] ?? '').toString();
      final answer = _answers[index];
      if (type == 'text') {
        if (answer is String && answer.trim().isNotEmpty) count++;
      } else {
        if (answer is int) count++;
      }
    }
    return count;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_entryVerified || _examSubmitted) return;

    // If student leaves app/tab during exam, log as suspicious.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      _registerTabSwitch(source: 'lifecycle');
      return;
    }

    // When they return, show an explicit warning popup.
    if (state == AppLifecycleState.resumed && _wasBackgroundedDuringExam) {
      _wasBackgroundedDuringExam = false;
      if (_tabSwitchCount >= _maxAllowedTabSwitches) {
        _showTabSwitchTerminationDialog();
        return;
      }
      _showTabSwitchWarningDialog();
    }
  }

  void _registerTabSwitch({required String source}) {
    final now = DateTime.now();
    if (_lastTabSwitchAt != null &&
        now.difference(_lastTabSwitchAt!).inSeconds < 2) {
      return; // debounce duplicate signals
    }
    _lastTabSwitchAt = now;
    setState(() {
      _tabSwitchCount++;
      _showTabSwitchOverlay = true;
      _tabSwitchOverlayMessage =
          'Tab/app switch detected ($_tabSwitchCount). This attempt is logged.';
    });
    _wasBackgroundedDuringExam = true;
    _pendingTabSwitchWarning = true;
    _logEvent('tab_switched', extraData: {
      'suspicious': true,
      'source': source,
      'tab_switch_count': _tabSwitchCount,
      'flag_level': 'soft',
      'fraud_score': _currentFraudScore,
    });
  }

  Future<void> _showTabSwitchWarningDialog() async {
    if (!mounted || _tabSwitchDialogOpen) return;
    if (_showTabSwitchOverlay) {
      setState(() => _showTabSwitchOverlay = false);
    }
    _tabSwitchDialogOpen = true;
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => AlertDialog(
          title: const Text('Warning'),
          content: Text(
            'Tab/app switch detected during exam. '
            'This has been logged (${_tabSwitchCount} time${_tabSwitchCount == 1 ? '' : 's'}) '
            'and will appear in your report.',
          ),
          actions: [
            ElevatedButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Continue Exam'),
            ),
          ],
        ),
      );
    } finally {
      _tabSwitchDialogOpen = false;
    }
  }

  Future<void> _showTabSwitchTerminationDialog() async {
    if (!mounted || _examSubmitted || _tabSwitchTerminationDialogOpen) return;
    _tabSwitchTerminationDialogOpen = true;
    await _logEvent('exam_terminated_tab_switch', extraData: {
      'tab_switch_count': _tabSwitchCount,
      'max_allowed_tab_switches': _maxAllowedTabSwitches,
      'flag_level': 'critical',
      'fraud_score': (_currentFraudScore + 35).clamp(0, 100),
    });
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => AlertDialog(
          title: const Text('Exam Terminated'),
          content: Text(
            'You switched tab/app $_tabSwitchCount times. '
            'Maximum allowed is $_maxAllowedTabSwitches. '
            'Your exam is being auto-submitted and flagged in the report.',
          ),
          actions: [
            ElevatedButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    } finally {
      _tabSwitchTerminationDialogOpen = false;
    }
    if (!_examSubmitted) {
      _doSubmit();
    }
  }

  void _recordAction({
    bool changedAnswer = false,
    int charsDelta = 0,
    bool isBackspace = false,
    bool isPasteLike = false,
  }) {
    final now = DateTime.now();
    if (_lastActionAt != null) {
      final gapSec = now.difference(_lastActionAt!).inMilliseconds / 1000.0;
      _actionGaps.add(gapSec);
      if (_actionGaps.length > 120) {
        _actionGaps.removeAt(0);
      }
    }
    _lastActionAt = now;
    if (changedAnswer) _answerChangeCount++;
    if (isBackspace) _backspaceCount++;
    if (isPasteLike) _pasteLikeEvents++;
    if (charsDelta.abs() > _maxCharsInOneEdit) {
      _maxCharsInOneEdit = charsDelta.abs().toDouble();
    }
  }

  List<double> _buildBehavioralSample() {
    final now = DateTime.now();
    final startedAt = _examStartedAt ?? now;
    final elapsedSec = now.difference(startedAt).inSeconds.clamp(1, 24 * 3600);
    final elapsedMin = elapsedSec / 60.0;

    final meanGap = _actionGaps.isEmpty
        ? 4.0
        : _actionGaps.reduce((a, b) => a + b) / _actionGaps.length;

    double gapStd = 0.0;
    if (_actionGaps.length > 1) {
      final variance = _actionGaps
              .map((g) => (g - meanGap) * (g - meanGap))
              .reduce((a, b) => a + b) /
          (_actionGaps.length - 1);
      gapStd = math.sqrt(variance);
    }

    final textEvents = _textEditEvents == 0 ? 1 : _textEditEvents;
    final backspaceRatio = _backspaceCount / textEvents;
    final pasteRatePerMin = _pasteLikeEvents / elapsedMin;
    final tabSwitchRatePerMin = _tabSwitchCount / elapsedMin;
    final answerChangeRatePerMin = _answerChangeCount / elapsedMin;
    final idleRatio = (_lastActionAt == null)
        ? 1.0
        : (now.difference(_lastActionAt!).inSeconds / _monitorInterval)
            .clamp(0.0, 1.0);

    // Keep same 8-feature shape expected by backend.
    return [
      meanGap.clamp(0.0, 30.0),
      gapStd.clamp(0.0, 15.0),
      backspaceRatio.clamp(0.0, 1.0),
      tabSwitchRatePerMin.clamp(0.0, 10.0),
      pasteRatePerMin.clamp(0.0, 10.0),
      answerChangeRatePerMin.clamp(0.0, 10.0),
      (_maxCharsInOneEdit / 20.0).clamp(0.0, 5.0),
      idleRatio.toDouble(),
    ];
  }

  // ── Camera init ────────────────────────────────────────────────────────────
  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        if (mounted) setState(() => _cameraError = 'No camera found on this device.');
        return;
      }

      final frontCamera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );

      _cameraController = CameraController(
        frontCamera,
        kIsWeb ? ResolutionPreset.low : ResolutionPreset.medium,
        enableAudio: false,
      );
      await _cameraController!.initialize();
      if (mounted) setState(() { _cameraReady = true; _cameraError = null; });
    } catch (e) {
      debugPrint('Camera init failed: $e');
      if (mounted) setState(() => _cameraError = e.toString());
    }
  }

  Future<void> _recoverCamera() async {
    try { await _cameraController?.dispose(); } catch (_) {}
    _cameraController = null;
    if (mounted) setState(() => _cameraReady = false);
    await Future.delayed(const Duration(milliseconds: 300));
    await _initCamera();
  }

  // ── Load exam questions ────────────────────────────────────────────────────
  Future<void> _loadExam() async {
    try {
      final doc = await _db.collection('exams').doc(widget.examId).get();
      if (doc.exists) {
        final data      = doc.data()!;
        final duration  = data['duration_mins'] ?? 90;
        final questions = List<Map<String, dynamic>>.from(
          (data['questions'] as List? ?? []).map((q) => Map<String, dynamic>.from(q)),
        );
        setState(() {
          _questions    = questions;
          _totalSeconds = duration * 60;
          _secondsLeft  = duration * 60;
          _examLoading  = false;
        });
      }
    } catch (e) {
      setState(() => _examLoading = false);
    }
  }

  // ── Entry face verification ────────────────────────────────────────────────
  Future<void> _verifyEntry() async {
    await Future.delayed(const Duration(seconds: 1)); // let camera warm up
    if (_cameraError != null && !_cameraReady) {
      await _recoverCamera();
    }
    await _waitForVerifyPreviewReady();

    bool captureFailed = false;
    String lastError = 'Face not matched with enrolled profile';
    double bestScore = 0.0;

    int positiveAttempts = 0;
    int successfulResponses = 0;
    double scoreSum = 0.0;

    for (int attempt = 1; attempt <= _verifyAttempts; attempt++) {
      if (!mounted) return;
      setState(() {
        _verifyMessage = 'Verifying your identity (attempt $attempt/$_verifyAttempts)...';
      });
      final frame = await _captureFrame();
      if (frame == null) {
        captureFailed = true;
        await Future.delayed(const Duration(milliseconds: 450));
        continue;
      }

      captureFailed = false;
      var result = await ApiService.verifyStudent(
        studentId:        widget.studentId,
        examId:           widget.examId,
        faceImageBase64:  frame,
      );
      if (_isStudentNotEnrolled(result)) {
        final repaired = await _repairBackendEnrollment(frame);
        if (repaired) {
          result = await ApiService.verifyStudent(
            studentId: widget.studentId,
            examId: widget.examId,
            faceImageBase64: frame,
          );
        }
      }
      debugPrint('Verify response (attempt $attempt): $result');

      final serverUnreachable = _isServerUnreachable(result);
      if (serverUnreachable && _allowServerFallbackWhenDown) {
        if (!mounted) return;
        setState(() {
          _entryVerified  = true;
          _verifyingEntry = false;
          _verifyMessage  = 'Verification server unreachable. Starting exam in fallback mode.';
        });
        await _logEvent('entry_verify_server_unreachable', extraData: {
          'exam_id': widget.examId,
          'attempt': attempt,
        });
        await Future.delayed(const Duration(milliseconds: 700));
        _startExamTimer();
        _startMonitoring();
        return;
      }

      final score = _extractVerifyScore(result);
      if (score > bestScore) bestScore = score;
      successfulResponses++;
      scoreSum += score;

      final cleared = _isVerifyCleared(result, score);
      if (cleared) {
        positiveAttempts++;
      }

      if (positiveAttempts >= _verifyMinPositiveAttempts) {
        break;
      }

      final err = (result['error'] ?? result['detail'] ?? '').toString().trim();
      if (err.isNotEmpty) lastError = err;
      await Future.delayed(const Duration(milliseconds: 450));
    }

    if (!mounted) return;

    final avgScore = successfulResponses == 0 ? 0.0 : (scoreSum / successfulResponses);
    final consensusCleared =
        positiveAttempts >= _verifyMinPositiveAttempts ||
        (!_requireExplicitVerifyDecision && avgScore >= _verifyMinScore);

    if (consensusCleared) {
      setState(() {
        _entryVerified  = true;
        _verifyingEntry = false;
        _verifyMessage  = 'Identity verified. Exam starting...';
      });
      await Future.delayed(const Duration(seconds: 1));
      _startExamTimer();
      _startMonitoring();
      return;
    }

    String message;
    if (captureFailed) {
      message = 'Camera capture failed. Please allow camera and try again.';
    } else if (bestScore > 0) {
      message =
          'Face not matched (score: ${bestScore.toStringAsFixed(2)}). Please center your face and try again.';
    } else {
      message = lastError;
    }

    setState(() {
      _entryVerified  = false;
      _verifyingEntry = false;
      _verifyMessage  = 'Verification failed: $message';
    });
  }

  Future<void> _waitForVerifyPreviewReady() async {
    for (int i = 0; i < 20; i++) {
      final controller = _cameraController;
      final initialized = controller != null && controller.value.isInitialized;
      final previewReady = _verifyPreviewKey.currentContext != null;
      if (initialized && previewReady) return;
      await Future.delayed(const Duration(milliseconds: 150));
    }
  }

  bool _isVerifyCleared(Map<String, dynamic> result, double score) {
    final data = result['data'];
    final dataMap = data is Map<String, dynamic> ? data : const <String, dynamic>{};
    final faceAbsent = _truthy(result['face_absent']) || _truthy(dataMap['face_absent']);
    if (faceAbsent) return false;

    final matchedId = (result['matched_student_id'] ??
            result['verified_student_id'] ??
            dataMap['matched_student_id'] ??
            dataMap['verified_student_id'])
        ?.toString();
    if (matchedId != null && matchedId.isNotEmpty && matchedId != widget.studentId) {
      return false;
    }

    final hasExplicitDecision = result.containsKey('cleared') ||
        result.containsKey('verified') ||
        result.containsKey('identity_verified') ||
        result.containsKey('match') ||
        result.containsKey('is_match') ||
        dataMap.containsKey('cleared') ||
        dataMap.containsKey('verified') ||
        dataMap.containsKey('identity_verified') ||
        dataMap.containsKey('match') ||
        dataMap.containsKey('is_match');

    final explicitPositive =
        _truthy(result['cleared']) ||
        _truthy(result['verified']) ||
        _truthy(result['identity_verified']) ||
        _truthy(result['match']) ||
        _truthy(result['is_match']) ||
        _truthy(dataMap['cleared']) ||
        _truthy(dataMap['verified']) ||
        _truthy(dataMap['identity_verified']) ||
        _truthy(dataMap['match']) ||
        _truthy(dataMap['is_match']) ||
        (result['status']?.toString().toLowerCase() == 'verified') ||
        (dataMap['status']?.toString().toLowerCase() == 'verified');

    final dynamicThreshold = ((result['threshold'] ??
                result['verify_threshold'] ??
                dataMap['threshold'] ??
                dataMap['verify_threshold']) as num?)
            ?.toDouble() ??
        _verifyMinScore;

    if (explicitPositive) {
      // Extra guard against false positives.
      return score == 0.0 || score >= dynamicThreshold;
    }

    // If API provided an explicit decision and it's not positive, fail.
    if (hasExplicitDecision) {
      return false;
    }

    // If no explicit decision is provided, use score only when policy allows it.
    if (_requireExplicitVerifyDecision) return false;
    return _truthy(result['success']) && score >= dynamicThreshold;
  }

  bool _truthy(dynamic value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final v = value.toLowerCase().trim();
      return v == 'true' || v == '1' || v == 'yes' || v == 'verified';
    }
    return false;
  }

  bool _isServerUnreachable(Map<String, dynamic> result) {
    final raw = (result['error'] ?? result['detail'] ?? '').toString().toLowerCase();
    return raw.contains('cannot reach server') ||
        raw.contains('failed to fetch') ||
        raw.contains('networkerror') ||
        raw.contains('connection refused') ||
        raw.contains('socketexception') ||
        raw.contains('xmlhttprequest');
  }

  TextInputFormatter _noPasteFormatter() {
    return TextInputFormatter.withFunction((oldValue, newValue) {
      final oldText = oldValue.text;
      final newText = newValue.text;

      // If inserted chunk is >1 character, treat it as paste-like and block.
      final delta = newText.length - oldText.length;
      final selectionJump =
          (newValue.selection.baseOffset - oldValue.selection.baseOffset).abs();
      final likelyPaste = delta > 1 || selectionJump > 1;

      if (likelyPaste) {
        _handleClipboardShortcutBlocked('paste');
        return oldValue;
      }

      return newValue;
    });
  }

  void _setTextAnswer(int index, String value, {String? previous}) {
    final prev = (previous ?? (_answers[index] ?? '')).toString();
    final trimmed = value.trim();
    _textEditEvents++;
    final delta = value.length - prev.length;
    _recordAction(
      changedAnswer: trimmed != prev.trim(),
      charsDelta: delta,
      isBackspace: delta < 0,
      isPasteLike: delta >= 6,
    );
    setState(() {
      if (trimmed.isEmpty) {
        _answers.remove(index);
      } else {
        _answers[index] = trimmed;
      }
    });
  }

  Widget _buildNoPasteWebAnswerBox() {
    final current = (_answers[_currentQuestion] ?? '').toString();
    return Focus(
      focusNode: _webAnswerFocusNode,
      autofocus: true,
      onKeyEvent: (_, KeyEvent event) {
        if (event is! KeyDownEvent) return KeyEventResult.handled;
        final isCtrlMeta = HardwareKeyboard.instance.isControlPressed ||
            HardwareKeyboard.instance.isMetaPressed;
        final key = event.logicalKey;
        if (isCtrlMeta &&
            (key == LogicalKeyboardKey.keyV ||
                key == LogicalKeyboardKey.keyC ||
                key == LogicalKeyboardKey.keyX ||
                key == LogicalKeyboardKey.keyA)) {
          _handleClipboardShortcutBlocked('paste');
          return KeyEventResult.handled;
        }

        if (key == LogicalKeyboardKey.backspace) {
          if (current.isNotEmpty) {
            _setTextAnswer(_currentQuestion, current.substring(0, current.length - 1),
                previous: current);
          }
          return KeyEventResult.handled;
        }

        if (key == LogicalKeyboardKey.enter) {
          _setTextAnswer(_currentQuestion, '$current\n', previous: current);
          return KeyEventResult.handled;
        }

        final ch = event.character;
        if (ch != null && ch.isNotEmpty && ch.runes.length == 1) {
          final code = ch.runes.first;
          // Printable ASCII + common unicode letters.
          if (code >= 32 && code != 127) {
            _setTextAnswer(_currentQuestion, '$current$ch', previous: current);
          }
          return KeyEventResult.handled;
        }
        return KeyEventResult.handled;
      },
      child: GestureDetector(
        onTap: () => _webAnswerFocusNode.requestFocus(),
        child: Container(
          width: double.infinity,
          constraints: const BoxConstraints(minHeight: 120),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFFBDBDBD)),
          ),
          child: Text(
            current.isEmpty ? 'Type your answer (paste disabled)...' : current,
            style: TextStyle(
              color: current.isEmpty ? Colors.grey : const Color(0xFF1a1a2e),
              fontSize: 14,
            ),
          ),
        ),
      ),
    );
  }

  bool _isStudentNotEnrolled(Map<String, dynamic> result) {
    final raw = (result['error'] ?? result['detail'] ?? '').toString().toLowerCase();
    return raw.contains('student_not_enrolled') ||
        raw.contains('not enrolled') ||
        raw.contains('no enrollment');
  }

  Future<bool> _repairBackendEnrollment(String frameBase64) async {
    try {
      final doc = await _db.collection('students').doc(widget.studentId).get();
      if (!doc.exists) return false;
      final data = doc.data() ?? {};
      final aadhaar = (data['aadhaar_number'] ?? '').toString().trim();
      if (aadhaar.length != 12) return false;

      final enrolled = await ApiService.enrollStudent(
        studentId: widget.studentId,
        name: (data['name'] ?? '').toString(),
        email: (data['email'] ?? '').toString(),
        college: (data['college'] ?? '').toString(),
        course: (data['course'] ?? '').toString(),
        aadhaarNumber: aadhaar,
        faceImageBase64: frameBase64,
        // Backend requires >= 3 liveness frames; use current frame as recovery fallback.
        livenessFrames: [frameBase64, frameBase64, frameBase64],
        behavioralSamples: [_buildBehavioralSample()],
      );
      return enrolled['success'] == true;
    } catch (e) {
      debugPrint('Enrollment repair failed: $e');
      return false;
    }
  }

  double _extractVerifyScore(Map<String, dynamic> result) {
    final candidates = [
      result['face_match_score'],
      result['match_score'],
      result['similarity'],
      result['score'],
    ];
    for (final c in candidates) {
      if (c is num) return c.toDouble();
    }
    final data = result['data'];
    if (data is Map<String, dynamic>) {
      for (final key in ['face_match_score', 'match_score', 'similarity', 'score']) {
        final v = data[key];
        if (v is num) return v.toDouble();
      }
    }
    for (final key in ['face_match_score', 'match_score', 'similarity', 'score']) {
      final raw = result[key];
      if (raw is String) {
        final parsed = double.tryParse(raw);
        if (parsed != null) return parsed;
      }
      final nestedRaw = dataMapValue(result, key);
      if (nestedRaw is String) {
        final parsed = double.tryParse(nestedRaw);
        if (parsed != null) return parsed;
      }
    }
    return 0.0;
  }

  dynamic dataMapValue(Map<String, dynamic> result, String key) {
    final data = result['data'];
    if (data is Map<String, dynamic>) {
      return data[key];
    }
    return null;
  }

  // ── Exam timer ─────────────────────────────────────────────────────────────
  void _startExamTimer() {
    _examStartedAt ??= DateTime.now();
    _startVisibilityGuard();
    _startWebGuard();
    _examTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_secondsLeft <= 0) {
        timer.cancel();
        _autoSubmit();
      } else {
        if (mounted) setState(() => _secondsLeft--);
      }
    });
  }

  void _startWebGuard() {
    if (_webGuardActive) return;
    _webGuardActive = true;
    _webExamGuard.start(
      onClipboardBlocked: (action) {
        if (!_entryVerified || _examSubmitted) return;
        _handleClipboardShortcutBlocked(action);
      },
      onTabSwitched: (source) {
        if (!_entryVerified || _examSubmitted) return;
        _registerTabSwitch(source: 'web_$source');
      },
      onTabReturned: (source) {
        if (!_entryVerified || _examSubmitted) return;
        if (!_pendingTabSwitchWarning) return;
        _pendingTabSwitchWarning = false;
        if (_tabSwitchCount >= _maxAllowedTabSwitches) {
          _showTabSwitchTerminationDialog();
          return;
        }
        _showTabSwitchWarningDialog();
      },
      onScreenShareDetected: () {
        if (!_entryVerified || _examSubmitted) return;
        unawaited(_logEvent('screen_share_attempted', extraData: {
          'exam_id': widget.examId,
          'flag_level': 'hard',
        }));
        if (!mounted) return;
        setState(() {
          _showFraudAlert = true;
          _fraudAlertMessage = 'Screen sharing is not allowed during exam.';
        });
        Future.delayed(const Duration(seconds: 4), () {
          if (mounted) setState(() => _showFraudAlert = false);
        });
      },
    );
  }

  void _ensureWebGuardState() {
    final shouldBeActive = !_examSubmitted;
    if (shouldBeActive && !_webGuardActive) {
      _startWebGuard();
    } else if (!shouldBeActive && _webGuardActive) {
      _webExamGuard.stop();
      _webGuardActive = false;
    }
  }

  void _startVisibilityGuard() {
    _visibilityGuardTimer?.cancel();
    _lastVisibilityTick = DateTime.now();
    _visibilityGuardTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_examSubmitted || !_entryVerified) return;
      final now = DateTime.now();
      final last = _lastVisibilityTick;
      _lastVisibilityTick = now;
      if (last == null) return;
      // If timers were paused for several seconds, user likely backgrounded app/tab.
      if (now.difference(last).inSeconds >= 4) {
        _registerTabSwitch(source: 'timer_gap');
      }
    });
  }

  // ── Monitoring timer (every 10 min, or 60s for demo) ──────────────────────
  void _startMonitoring() {
    _monitorTimer = Timer.periodic(
      Duration(seconds: _monitorInterval),
      (_) => _runMonitorCheck(),
    );
    _startAudioMonitoring();
  }

  Future<void> _startAudioMonitoring() async {
    try {
      if (!await _audioRecorder.hasPermission()) return;
      String recordPath = 'examiq_audio.m4a';
      if (!kIsWeb) {
        final dir = await getTemporaryDirectory();
        recordPath = '${dir.path}/examiq_audio_${DateTime.now().millisecondsSinceEpoch}.m4a';
      }
      await _audioRecorder.start(
        const RecordConfig(encoder: AudioEncoder.aacLc, sampleRate: 16000, numChannels: 1),
        path: recordPath,
      );
      _audioMonitorTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
        if (_examSubmitted || !_entryVerified) return;
        try {
          final amp = await _audioRecorder.getAmplitude();
          _handleAudioAmplitude(amp.current);
        } catch (_) {}
      });
    } catch (e) {
      debugPrint('Audio monitoring unavailable: $e');
    }
  }

  void _handleAudioAmplitude(double dbfs) {
    if (dbfs > _audioAlertThreshold) {
      _highAudioStreak++;
      if (_highAudioStreak >= 3) {
        _highAudioStreak = 0;
        unawaited(_logEvent('audio_noise_detected', extraData: {
          'amplitude_dbfs': dbfs,
          'flag_level': 'soft',
        }));
        if (!mounted) return;
        setState(() {
          _showFraudAlert = true;
          _fraudAlertMessage = 'Suspicious audio noise detected.';
        });
        Future.delayed(const Duration(seconds: 3), () {
          if (mounted) setState(() => _showFraudAlert = false);
        });
      }
    } else {
      _highAudioStreak = 0;
    }
  }

  Future<void> _stopAudioMonitoring() async {
    _audioMonitorTimer?.cancel();
    _audioMonitorTimer = null;
    try {
      final path = await _audioRecorder.stop();
      if (path != null && !kIsWeb) {
        final f = File(path);
        if (await f.exists()) await f.delete();
      }
    } catch (_) {}
  }

  Future<void> _runMonitorCheck() async {
    if (_examSubmitted || !_entryVerified) return;

    final frame = await _captureFrame();
    final faceAbsent = frame == null;
    if (faceAbsent) {
      _noFaceStreak++;
    } else {
      _noFaceStreak = 0;
    }

    final result = await ApiService.monitorStudent(
      studentId:        widget.studentId,
      examId:           widget.examId,
      faceFrameBase64:  frame ?? '',
      behavioralSample: _buildBehavioralSample(),
      faceAbsent:       faceAbsent,
    );

    if (!mounted) return;

    final deepfakeScore = ((result['deepfake_score'] ?? 0.0) as num).toDouble();
    final deepfakeFlag = result['deepfake'] == true || deepfakeScore >= 0.65;
    final faceScore = ((result['face_match_score'] ?? 0.0) as num).toDouble();
    final faceMismatch = faceScore > 0 && faceScore < 0.70;
    final repeatedNoFace = _noFaceStreak >= 3;
    final multipleFaces = result['multiple_faces'] == true;
    final score     = result['fraud_score'] ?? 0;
    final flagLevel = result['flag_level'] ?? 'clean';

    setState(() {
      _currentFraudScore = score;
      _currentFlagLevel  = flagLevel;
    });

    if (deepfakeFlag) {
      await _logEvent('deepfake_suspected', extraData: {
        'exam_id': widget.examId,
        'deepfake_score': deepfakeScore,
      });
    }

    if (multipleFaces) {
      await _logEvent('multiple_faces_detected', extraData: {
        'exam_id': widget.examId,
        'flag_level': 'hard',
      });
    }

    // Show alert if flagged
    final identityViolation = deepfakeFlag || repeatedNoFace || faceMismatch || multipleFaces;
    if (identityViolation) {
      _identityRiskStreak++;
    } else {
      _identityRiskStreak = 0;
    }

    if (_identityRiskStreak >= 2 && !_examSubmitted) {
      await _logEvent('exam_terminated_identity_violation', extraData: {
        'face_match_score': faceScore,
        'deepfake_score': deepfakeScore,
        'no_face_streak': _noFaceStreak,
      });
      if (!mounted) return;
      _showIdentityTerminationDialog();
      return;
    }

    final localHardFlags =
        deepfakeFlag || repeatedNoFace || multipleFaces || _tabSwitchCount >= 3;
    if (flagLevel == 'hard' || flagLevel == 'critical' || localHardFlags) {
      final merged = <String, dynamic>{
        ...result,
        'deepfake': deepfakeFlag,
        'deepfake_score': deepfakeScore,
        'multiple_faces': multipleFaces,
        'no_face_streak': _noFaceStreak,
        'tab_switch_count': _tabSwitchCount,
      };
      _showAlert(score, flagLevel, merged);
    }
  }

  Future<void> _showIdentityTerminationDialog() async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text('Identity Verification Failed'),
        content: const Text(
          'Multiple identity mismatches were detected during monitoring. '
          'Your exam session will be submitted and flagged for review.',
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    if (!_examSubmitted) {
      _doSubmit();
    }
  }

  void _showAlert(int score, String level, Map<String, dynamic> result) {
    final faceScore = result['face_match_score'] ?? 0.0;
    final drift     = result['behavioral_drift'] ?? 0.0;
    final deepfakeScore = ((result['deepfake_score'] ?? 0.0) as num).toDouble();

    String message = '';
    if (result['deepfake'] == true || deepfakeScore >= 0.65) {
      message = 'Possible deepfake/spoof attempt detected.';
    } else if (result['multiple_faces'] == true) {
      message = 'Multiple faces detected in camera.';
    } else if ((result['no_face_streak'] ?? 0) >= 3 || result['face_absent'] == true) {
      message = 'Face not detected in camera.';
    } else if ((result['tab_switch_count'] ?? 0) >= 3) {
      message = 'Frequent app/tab switching detected.';
    } else if ((faceScore as double) < 0.70) {
      message = 'Face verification failed.';
    } else if ((drift as double) > 0.60) {
      message = 'Unusual typing behavior detected.';
    } else {
      message = 'Suspicious activity detected.';
    }

    setState(() {
      _showFraudAlert    = true;
      _fraudAlertMessage = message;
    });

    // Auto-dismiss after 5 seconds
    Future.delayed(const Duration(seconds: 5), () {
      if (mounted) setState(() => _showFraudAlert = false);
    });
  }

  // ── Capture frame ──────────────────────────────────────────────────────────
  Future<String?> _captureFrame() async {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return null;

    for (int attempt = 1; attempt <= 3; attempt++) {
      try {
        if (controller.value.isTakingPicture) {
          await Future.delayed(const Duration(milliseconds: 150));
        }
        final image = await controller.takePicture();
        final bytes = await image.readAsBytes();
        if (bytes.isNotEmpty) {
          return base64Encode(bytes);
        }
      } catch (e) {
        debugPrint('Exam capture failed (attempt $attempt): $e');
      }
      await Future.delayed(const Duration(milliseconds: 220));
    }
    final fallback = await _captureFromPreview();
    if (fallback != null) return fallback;
    if (!kIsWeb) {
      final pickerFrame = await _captureWithImagePicker();
      if (pickerFrame != null) return pickerFrame;
    }
    return null;
  }

  Future<String?> _captureFromPreview() async {
    try {
      final context = _verifyPreviewKey.currentContext;
      if (context == null) return null;
      final boundary = context.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) return null;
      final ui.Image image = await boundary.toImage(pixelRatio: 1.2);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      final Uint8List? bytes = byteData?.buffer.asUint8List();
      if (bytes == null || bytes.isEmpty) return null;
      return base64Encode(bytes);
    } catch (e) {
      debugPrint('Exam preview fallback failed: $e');
      return null;
    }
  }

  Future<String?> _captureWithImagePicker() async {
    try {
      final file = await ImagePicker().pickImage(
        source: ImageSource.camera,
        preferredCameraDevice: CameraDevice.front,
        imageQuality: 85,
      );
      if (file == null) return null;
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) return null;
      return base64Encode(bytes);
    } catch (e) {
      debugPrint('Exam picker fallback failed: $e');
      return null;
    }
  }

  // ── Log event to Firestore ─────────────────────────────────────────────────
  Future<void> _logEvent(String type,
      {Map<String, dynamic> extraData = const {}}) async {
    await _db.collection('exam_events').add({
      'student_id': widget.studentId,
      'exam_id':    widget.examId,
      'event_type': type,
      'timestamp':  DateTime.now().toIso8601String(),
      ...extraData,
    });
  }

  // ── Submit exam ────────────────────────────────────────────────────────────
  Future<void> _submitExam() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Submit Exam?'),
        content: Text(
          'You have answered $_answeredCount of ${_questions.length} questions. '
              'Are you sure you want to submit?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Submit'),
          ),
        ],
      ),
    );

    if (confirmed == true) _doSubmit();
  }

  void _autoSubmit() {
    if (!_examSubmitted) _doSubmit();
  }

  Future<void> _doSubmit() async {
    if (_examSubmitted) return;

    setState(() {
      _isSubmitting  = true;
      _examSubmitted = true;
    });

    _examTimer?.cancel();
    _monitorTimer?.cancel();
    _visibilityGuardTimer?.cancel();
    unawaited(_stopAudioMonitoring());
    _webExamGuard.stop();

    // Log submission
    await _logEvent('exam_submitted', extraData: {
      'answers_count':   _answeredCount,
      'total_questions': _questions.length,
    });

    // Save student answers
    await _db
        .collection('exam_answers')
        .doc('${widget.examId}_${widget.studentId}')
        .set({
      'exam_id':      widget.examId,
      'student_id':   widget.studentId,
      'answers':      _answers.map((k, v) => MapEntry('$k', v)),
      'submitted_at': DateTime.now().toIso8601String(),
      'graded':       false,
    });

    // Log exam end event
    await _db
        .collection('exam_events')
        .add({
      'student_id': widget.studentId,
      'exam_id':    widget.examId,
      'event_type': 'exam_end',
      'timestamp':  DateTime.now().toIso8601String(),
      'final_fraud_score': _currentFraudScore,
    });

    setState(() => _isSubmitting = false);

    if (mounted) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => _ExamResultScreen(
            examTitle:       widget.examTitle,
            answeredCount:   _answeredCount,
            totalQuestions:  _questions.length,
            fraudScore:      _currentFraudScore,
          ),
        ),
      );
    }
  }

  // ── Timer display ──────────────────────────────────────────────────────────
  String get _timerDisplay {
    final mins = _secondsLeft ~/ 60;
    final secs = _secondsLeft % 60;
    return '${mins.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
  }

  Color get _timerColor {
    if (_secondsLeft < 300) return const Color(0xFFA32D2D); // < 5 min = red
    if (_secondsLeft < 600) return const Color(0xFFBA7517); // < 10 min = amber
    return const Color(0xFF534AB7);
  }

  // ── Build ──────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    _ensureWebGuardState();
    if (_verifyingEntry) return _buildVerifyingScreen();
    if (!_entryVerified) return _buildVerifyFailedScreen();
    if (_examLoading)    return _buildLoadingScreen();

    return WillPopScope(
      onWillPop: () async {
        // Prevent back button during exam
        final exit = await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Leave Exam?'),
            content: const Text(
              'Leaving will be logged. Your progress will be lost.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Stay'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                style: TextButton.styleFrom(
                    foregroundColor: Colors.red),
                child: const Text('Leave'),
              ),
            ],
          ),
        );
        return exit ?? false;
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          CopySelectionTextIntent:
              CallbackAction<CopySelectionTextIntent>(onInvoke: (intent) {
            _handleClipboardShortcutBlocked('copy');
            return null;
          }),
          PasteTextIntent:
              CallbackAction<PasteTextIntent>(onInvoke: (intent) {
            _handleClipboardShortcutBlocked('paste');
            return null;
          }),
          SelectAllTextIntent:
              CallbackAction<SelectAllTextIntent>(onInvoke: (intent) {
            _handleClipboardShortcutBlocked('select_all');
            return null;
          }),
        },
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.keyC, control: true): () =>
                _handleClipboardShortcutBlocked('copy'),
            const SingleActivator(LogicalKeyboardKey.keyC, meta: true): () =>
                _handleClipboardShortcutBlocked('copy'),
            const SingleActivator(LogicalKeyboardKey.keyV, control: true): () =>
                _handleClipboardShortcutBlocked('paste'),
            const SingleActivator(LogicalKeyboardKey.keyV, meta: true): () =>
                _handleClipboardShortcutBlocked('paste'),
            const SingleActivator(LogicalKeyboardKey.keyX, control: true): () =>
                _handleClipboardShortcutBlocked('cut'),
            const SingleActivator(LogicalKeyboardKey.keyX, meta: true): () =>
                _handleClipboardShortcutBlocked('cut'),
            const SingleActivator(LogicalKeyboardKey.keyA, control: true): () =>
                _handleClipboardShortcutBlocked('select_all'),
            const SingleActivator(LogicalKeyboardKey.keyA, meta: true): () =>
                _handleClipboardShortcutBlocked('select_all'),
            const SingleActivator(LogicalKeyboardKey.insert, shift: true): () =>
                _handleClipboardShortcutBlocked('paste'),
          },
          child: Focus(
            autofocus: true,
            child: SelectionContainer.disabled(
              child: Stack(
                children: [
                  Scaffold(
                    backgroundColor: const Color(0xFFF8F7FF),
                    body: SafeArea(
                      child: Column(
                        children: [
                          _buildExamHeader(),
                          if (_showFraudAlert) _buildFraudAlert(),
                          Expanded(
                            child: _questions.isEmpty
                                ? _buildNoQuestionsView()
                                : _buildQuestionView(),
                          ),
                          _buildBottomNav(),
                        ],
                      ),
                    ),
                  ),
                  if (_showTabSwitchOverlay) _buildTabSwitchOverlay(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _handleClipboardShortcutBlocked(String action) {
    _pasteLikeEvents++;
    _recordAction(isPasteLike: true);
    unawaited(_logEvent('clipboard_blocked', extraData: {
      'exam_id': widget.examId,
      'action': action,
      'timestamp_client': DateTime.now().toIso8601String(),
    }));
    final now = DateTime.now();
    if (_lastClipboardWarnAt != null &&
        now.difference(_lastClipboardWarnAt!).inSeconds < 2) {
      return;
    }
    _lastClipboardWarnAt = now;
    if (!mounted) return;
    setState(() {
      _showFraudAlert = true;
      _fraudAlertMessage = 'Copy/paste is disabled during exam.';
    });
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _showFraudAlert = false);
    });
  }

  Widget _buildTabSwitchOverlay() {
    return Positioned.fill(
      child: Material(
        color: Colors.black54,
        child: Center(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 24),
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFFF09595)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.warning_rounded, color: Color(0xFFA32D2D), size: 42),
                const SizedBox(height: 10),
                const Text(
                  'Warning',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFFA32D2D),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _tabSwitchOverlayMessage,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 13, color: Color(0xFF1a1a2e)),
                ),
                const SizedBox(height: 14),
                ElevatedButton(
                  onPressed: () {
                    if (!mounted) return;
                    setState(() => _showTabSwitchOverlay = false);
                  },
                  child: const Text('Continue Exam'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Verifying screen ───────────────────────────────────────────────────────
  Widget _buildVerifyingScreen() {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            // Mini camera preview
            if (_cameraReady && _cameraController != null)
              Container(
                height: 280,
                color: Colors.black,
                child: Stack(
                  children: [
                    Center(
                      child: RepaintBoundary(
                        key: _verifyPreviewKey,
                        child: CameraPreview(_cameraController!),
                      ),
                    ),
                    Center(
                      child: Container(
                        width: 180,
                        height: 220,
                        decoration: BoxDecoration(
                          border: Border.all(
                              color: const Color(0xFF534AB7), width: 2),
                          borderRadius: BorderRadius.circular(90),
                        ),
                      ),
                    ),
                  ],
                ),
              )
            else
              SizedBox(
                height: 280,
                child: Center(
                  child: _cameraError != null
                      ? Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.videocam_off_rounded,
                                  color: Colors.white54, size: 48),
                              const SizedBox(height: 12),
                              const Text(
                                'Camera blocked by another app',
                                style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 15,
                                    fontWeight: FontWeight.bold),
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 8),
                              const Text(
                                'Close any app using your camera\n(Teams, Zoom, Skype, Windows Camera)\nthen tap Retry.',
                                style: TextStyle(
                                    color: Colors.white70, fontSize: 13, height: 1.5),
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 20),
                              ElevatedButton.icon(
                                onPressed: () async {
                                  await _recoverCamera();
                                  if (_cameraReady) _verifyEntry();
                                },
                                icon: const Icon(Icons.refresh),
                                label: const Text('Retry Camera'),
                              ),
                            ],
                          ),
                        )
                      : const CircularProgressIndicator(color: Colors.white),
                ),
              ),
            const SizedBox(height: 40),
            const CircularProgressIndicator(color: Color(0xFF534AB7)),
            const SizedBox(height: 20),
            const Text(
              'Verifying your identity',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _verifyMessage,
              style: const TextStyle(color: Colors.white60, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVerifyFailedScreen() {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_rounded, color: Colors.red, size: 64),
              const SizedBox(height: 20),
              const Text(
                'Verification Failed',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              Text(
                _verifyMessage,
                style: const TextStyle(color: Colors.white70, fontSize: 14),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              ElevatedButton(
                onPressed: () {
                  setState(() => _verifyingEntry = true);
                  _verifyEntry();
                },
                child: const Text('Try Again'),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text(
                  'Go Back',
                  style: TextStyle(color: Colors.white60),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLoadingScreen() {
    return const Scaffold(
      body: Center(
        child: CircularProgressIndicator(color: Color(0xFF534AB7)),
      ),
    );
  }

  // ── Exam header ────────────────────────────────────────────────────────────
  Widget _buildExamHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      color: Colors.white,
      child: Row(
        children: [
          // Question counter
          Expanded(
            child: Text(
              widget.examTitle,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Color(0xFF1a1a2e),
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),

          // Fraud indicator (subtle)
          if (_currentFraudScore > 30)
            Container(
              margin: const EdgeInsets.only(right: 10),
              padding:
              const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: _currentFlagLevel == 'critical'
                    ? const Color(0xFFFCEBEB)
                    : const Color(0xFFFAEEDA),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.shield_outlined,
                    size: 12,
                    color: _currentFlagLevel == 'critical'
                        ? const Color(0xFFA32D2D)
                        : const Color(0xFFBA7517),
                  ),
                  const SizedBox(width: 3),
                  Text(
                    '$_currentFraudScore',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: _currentFlagLevel == 'critical'
                          ? const Color(0xFFA32D2D)
                          : const Color(0xFFBA7517),
                    ),
                  ),
                ],
              ),
            ),

          // Timer
          Container(
            padding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: _timerColor.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(Icons.timer_outlined, size: 14, color: _timerColor),
                const SizedBox(width: 4),
                Text(
                  _timerDisplay,
                  style: TextStyle(
                    color: _timerColor,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    fontFamily: 'Courier',
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Fraud alert banner ─────────────────────────────────────────────────────
  Widget _buildFraudAlert() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: const Color(0xFFFCEBEB),
      child: Row(
        children: [
          const Icon(Icons.warning_rounded,
              color: Color(0xFFA32D2D), size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _fraudAlertMessage,
              style: const TextStyle(
                color: Color(0xFFA32D2D),
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          GestureDetector(
            onTap: () => setState(() => _showFraudAlert = false),
            child: const Icon(Icons.close,
                color: Color(0xFFA32D2D), size: 16),
          ),
        ],
      ),
    );
  }

  // ── Question view ──────────────────────────────────────────────────────────
  Widget _buildQuestionView() {
    final question = _questions[_currentQuestion];
    final qText    = question['q'] ?? question['question'] ?? 'Question';
    final options  = List<String>.from(question['options'] ?? []);
    final marks    = (question['marks'] ?? 1).toString();
    final qType    = (question['type'] ?? (options.isNotEmpty ? 'mcq' : 'text'))
        .toString()
        .toLowerCase();
    final imageData = (question['image_data_url'] ?? question['image_base64'] ?? '')
        .toString()
        .trim();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Progress bar
          Row(
            children: [
              Text(
                'Q${_currentQuestion + 1} of ${_questions.length}',
                style: const TextStyle(
                  color: Colors.grey,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: (_currentQuestion + 1) / _questions.length,
                    backgroundColor: const Color(0xFFE8E8E8),
                    valueColor: const AlwaysStoppedAnimation<Color>(
                        Color(0xFF534AB7)),
                    minHeight: 6,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                '$_answeredCount answered',
                style: const TextStyle(
                  color: Colors.grey,
                  fontSize: 12,
                ),
              ),
            ],
          ),

          const SizedBox(height: 24),

          // Question text
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFFE8E8E8)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.04),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEEEDFE),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        qType == 'text' ? 'Text Answer' : 'MCQ',
                        style: const TextStyle(
                          color: Color(0xFF534AB7),
                          fontWeight: FontWeight.w600,
                          fontSize: 11,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: const Color(0xFFE1F5EE),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        '$marks mark${marks == '1' ? '' : 's'}',
                        style: const TextStyle(
                          color: Color(0xFF085041),
                          fontWeight: FontWeight.w600,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  qText,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF1a1a2e),
                    height: 1.5,
                  ),
                ),
                if (imageData.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  _buildQuestionImage(imageData),
                ],
              ],
            ),
          ),

          const SizedBox(height: 16),

          if (qType == 'text')
            (kIsWeb
                ? _buildNoPasteWebAnswerBox()
                : TextField(
                    controller: _textControllerFor(_currentQuestion),
                    minLines: 4,
                    maxLines: 8,
                    enableInteractiveSelection: false,
                    contextMenuBuilder: (_, __) => const SizedBox.shrink(),
                    inputFormatters: [_noPasteFormatter()],
                    decoration: const InputDecoration(
                      hintText: 'Type your answer here...',
                      alignLabelWithHint: true,
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (value) {
                      _setTextAnswer(_currentQuestion, value);
                    },
                  ))
          else ...[
            // Options (MCQ)
            ...options.asMap().entries.map((entry) {
              final idx      = entry.key;
              final optText  = entry.value;
              final selected = _answers[_currentQuestion] == idx;

              return GestureDetector(
                onTap: () {
                  final prev = _answers[_currentQuestion];
                  _recordAction(changedAnswer: prev != idx);
                  setState(() => _answers[_currentQuestion] = idx);
                },
                child: Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: selected
                        ? const Color(0xFFEEEDFE)
                        : Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: selected
                          ? const Color(0xFF534AB7)
                          : const Color(0xFFE8E8E8),
                      width: selected ? 2 : 1,
                    ),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 26,
                        height: 26,
                        decoration: BoxDecoration(
                          color: selected
                              ? const Color(0xFF534AB7)
                              : const Color(0xFFF1EFE8),
                          shape: BoxShape.circle,
                        ),
                        child: Center(
                          child: selected
                              ? const Icon(Icons.check,
                              color: Colors.white, size: 14)
                              : Text(
                            String.fromCharCode(65 + idx), // A, B, C, D
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF444441),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          optText,
                          style: TextStyle(
                            fontSize: 14,
                            color: selected
                                ? const Color(0xFF3C3489)
                                : const Color(0xFF1a1a2e),
                            fontWeight: selected
                                ? FontWeight.w500
                                : FontWeight.normal,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),
          ],
        ],
      ),
    );
  }

  Widget _buildQuestionImage(String imageData) {
    final isUrl = imageData.startsWith('http://') ||
        imageData.startsWith('https://') ||
        imageData.startsWith('data:image/');
    final imageWidget = isUrl
        ? Image.network(
            imageData,
            fit: BoxFit.cover,
            width: double.infinity,
            errorBuilder: (_, __, ___) => const SizedBox(
              height: 120,
              child: Center(child: Text('Image could not be loaded')),
            ),
          )
        : Image.memory(
            base64Decode(imageData),
            fit: BoxFit.cover,
            width: double.infinity,
            errorBuilder: (_, __, ___) => const SizedBox(
              height: 120,
              child: Center(child: Text('Image could not be loaded')),
            ),
          );

    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Container(
        constraints: const BoxConstraints(maxHeight: 220),
        color: const Color(0xFFF1EFE8),
        child: imageWidget,
      ),
    );
  }

  Widget _buildNoQuestionsView() {
    return const Center(
      child: Text(
        'No questions available for this exam.',
        style: TextStyle(color: Colors.grey),
      ),
    );
  }

  // ── Bottom navigation ──────────────────────────────────────────────────────
  Widget _buildBottomNav() {
    final isFirst = _currentQuestion == 0;
    final isLast  = _currentQuestion == _questions.length - 1;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(
            top: BorderSide(color: Color(0xFFE8E8E8))),
      ),
      child: Row(
        children: [
          // Previous
          if (!isFirst)
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () =>
                    setState(() => _currentQuestion--),
                icon: const Icon(Icons.arrow_back_ios, size: 14),
                label: const Text('Previous'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF534AB7),
                  side:
                  const BorderSide(color: Color(0xFF534AB7)),
                  minimumSize: const Size(0, 46),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ),

          if (!isFirst) const SizedBox(width: 12),

          // Next or Submit
          Expanded(
            flex: isFirst ? 1 : 1,
            child: ElevatedButton.icon(
              onPressed: isLast
                  ? _submitExam
                  : () => setState(() => _currentQuestion++),
              icon: Icon(
                isLast
                    ? Icons.check_rounded
                    : Icons.arrow_forward_ios,
                size: 14,
              ),
              label: Text(isLast ? 'Submit Exam' : 'Next'),
              style: ElevatedButton.styleFrom(
                backgroundColor: isLast
                    ? const Color(0xFF1D9E75)
                    : const Color(0xFF534AB7),
                foregroundColor: Colors.white,
                minimumSize: const Size(0, 46),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Exam result screen ─────────────────────────────────────────────────────
class _ExamResultScreen extends StatelessWidget {
  final String examTitle;
  final int    answeredCount;
  final int    totalQuestions;
  final int    fraudScore;

  const _ExamResultScreen({
    required this.examTitle,
    required this.answeredCount,
    required this.totalQuestions,
    required this.fraudScore,
  });

  @override
  Widget build(BuildContext context) {
    final isClean = fraudScore <= 30;

    return Scaffold(
      backgroundColor: const Color(0xFFF8F7FF),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Icon
              Container(
                width: 90,
                height: 90,
                decoration: BoxDecoration(
                  color: isClean
                      ? const Color(0xFF1D9E75)
                      : const Color(0xFFBA7517),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  isClean
                      ? Icons.check_rounded
                      : Icons.warning_rounded,
                  color: Colors.white,
                  size: 50,
                ),
              ),

              const SizedBox(height: 24),

              Text(
                isClean ? 'Exam Submitted!' : 'Exam Submitted',
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF1a1a2e),
                ),
              ),

              const SizedBox(height: 8),

              Text(
                examTitle,
                style: const TextStyle(color: Colors.grey, fontSize: 14),
                textAlign: TextAlign.center,
              ),

              const SizedBox(height: 32),

              // Stats
              Row(
                children: [
                  _resultStat(
                    '$answeredCount/$totalQuestions',
                    'Answered',
                    const Color(0xFF534AB7),
                    const Color(0xFFEEEDFE),
                  ),
                  const SizedBox(width: 12),
                  _resultStat(
                    '$fraudScore',
                    'Integrity Score',
                    isClean
                        ? const Color(0xFF1D9E75)
                        : const Color(0xFFBA7517),
                    isClean
                        ? const Color(0xFFE1F5EE)
                        : const Color(0xFFFAEEDA),
                  ),
                ],
              ),

              const SizedBox(height: 32),

              if (!isClean)
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFAEEDA),
                    borderRadius: BorderRadius.circular(10),
                    border:
                    Border.all(color: const Color(0xFFFAC775)),
                  ),
                  child: const Text(
                    'Some integrity checks were flagged during your exam. Your teacher will review the report.',
                    style: TextStyle(
                      color: Color(0xFF633806),
                      fontSize: 13,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),

              const SizedBox(height: 24),

              ElevatedButton(
                onPressed: () => Navigator.pushNamedAndRemoveUntil(
                  context,
                  '/student-dashboard',
                      (route) => false,
                ),
                child: const Text('Back to Dashboard'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _resultStat(
      String value, String label, Color color, Color bgColor) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [
            Text(
              value,
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style:
              TextStyle(fontSize: 12, color: color.withOpacity(0.8)),
            ),
          ],
        ),
      ),
    );
  }
}
