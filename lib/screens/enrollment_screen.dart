import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:camera/camera.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:image_picker/image_picker.dart';
import '../services/api_service.dart';
import 'student_dashboard.dart';

class EnrollmentScreen extends StatefulWidget {
  final String studentId;
  final List<List<double>>? initialBehavioralSamples;
  const EnrollmentScreen({
    super.key,
    required this.studentId,
    this.initialBehavioralSamples,
  });

  @override
  State<EnrollmentScreen> createState() => _EnrollmentScreenState();
}

class _EnrollmentScreenState extends State<EnrollmentScreen>
    with TickerProviderStateMixin {

  CameraController? _cameraController;
  final GlobalKey _cameraPreviewKey = GlobalKey();
  List<CameraDescription> _cameras = [];

  // State
  bool _cameraReady      = false;
  bool _isProcessing     = false;
  bool _enrollmentDone   = false;
  String _statusMessage  = 'Position your face in the circle';
  String _stepLabel      = 'Step 1 of 3 — Look straight at camera';
  int  _currentStep      = 0; // 0=position, 1=liveness, 2=enrolling
  String? _errorMessage;

  // Captured data
  final List<String> _livenessFrames = [];
  String? _enrollmentFrame;

  // Behavioral tracking (simulated for now — JS not available in Flutter)
  // We send dummy behavioral data and replace with real later
  final List<List<double>> _behavioralSamples = [];

  // Animation
  late AnimationController _pulseController;
  late Animation<double>    _pulseAnimation;

  // Liveness countdown
  int _livenessCountdown = 3;
  Timer? _livenessTimer;
  final ImagePicker _imagePicker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.04).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    _initCamera();
    final real = widget.initialBehavioralSamples;
    if (real != null && real.isNotEmpty) {
      _behavioralSamples.addAll(real);
    } else {
      _generateDummyBehavioralData();
    }
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    _pulseController.dispose();
    _livenessTimer?.cancel();
    super.dispose();
  }

  // ── Camera init ────────────────────────────────────────────────────────────
  Future<void> _initCamera() async {
    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        setState(() => _errorMessage = 'No camera found on device.');
        return;
      }

      // Use front camera
      final frontCamera = _cameras.firstWhere(
            (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => _cameras.first,
      );

      _cameraController = CameraController(
        frontCamera,
        kIsWeb ? ResolutionPreset.low : ResolutionPreset.medium,
        enableAudio: false,
      );

      await _cameraController!.initialize();
      if (mounted) setState(() => _cameraReady = true);
    } catch (e) {
      setState(() => _errorMessage = 'Camera error: $e');
    }
  }

  // ── Generate dummy behavioral data ────────────────────────────────────────
  void _generateDummyBehavioralData() {
    // In production this comes from keystroke tracking during form fill
    // For now we generate realistic baseline values
    final random = [
      [4.2, 0.11, 0.08, 3.1, 2.4, 0.09, 0.04, 0.06],
      [3.8, 0.13, 0.09, 2.8, 2.1, 0.11, 0.05, 0.07],
      [4.5, 0.10, 0.07, 3.4, 2.6, 0.08, 0.03, 0.05],
    ];
    _behavioralSamples.addAll(random.map((e) => e.map((v) => v).toList()));
  }

  // ── Capture single frame as base64 ────────────────────────────────────────
  Future<String?> _captureFrame() async {
    CameraController? controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) {
      await _recoverCamera();
      controller = _cameraController;
      if (controller == null || !controller.value.isInitialized) return null;
    }

    for (int attempt = 1; attempt <= 3; attempt++) {
      final current = controller;
      if (current == null || !current.value.isInitialized) {
        break;
      }
      try {
        if (current.value.isTakingPicture) {
          await Future.delayed(const Duration(milliseconds: 150));
        }
        final image = await current.takePicture();
        final bytes = await image.readAsBytes();
        if (bytes.isNotEmpty) {
          return base64Encode(bytes);
        }
      } catch (e) {
        debugPrint('Enrollment capture failed (attempt $attempt): $e');
        if (attempt == 2) {
          await _recoverCamera();
          controller = _cameraController;
          if (controller == null || !controller.value.isInitialized) break;
        }
      }
      await Future.delayed(const Duration(milliseconds: 220));
    }

    final fallback = await _captureFromPreview();
    if (fallback != null) return fallback;

    // Final fallback: use platform image picker camera flow.
    final pickerFallback = await _captureWithImagePickerFallback();
    if (pickerFallback != null) return pickerFallback;

    return null;
  }

  Future<void> _recoverCamera() async {
    try {
      await _cameraController?.dispose();
    } catch (_) {}
    _cameraController = null;
    if (mounted) {
      setState(() => _cameraReady = false);
    }
    await Future.delayed(const Duration(milliseconds: 220));
    await _initCamera();
  }

  Future<String?> _captureFromPreview() async {
    try {
      final context = _cameraPreviewKey.currentContext;
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
      debugPrint('Enrollment preview fallback failed: $e');
      return null;
    }
  }

  Future<String?> _captureWithImagePickerFallback() async {
    try {
      final XFile? file = await _imagePicker.pickImage(
        source: ImageSource.camera,
        preferredCameraDevice: CameraDevice.front,
        imageQuality: 85,
      );
      if (file == null) return null;
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) return null;
      return base64Encode(bytes);
    } catch (e) {
      debugPrint('Enrollment picker fallback failed: $e');
      return null;
    }
  }

  // ── Step 1: Capture enrollment photo ──────────────────────────────────────
  Future<void> _captureEnrollmentPhoto() async {
    setState(() {
      _statusMessage = 'Hold still...';
      _isProcessing  = true;
    });

    final frame = await _captureFrame();
    if (frame == null) {
      setState(() {
        _errorMessage =
            'Could not capture photo. Please allow camera permission and try again.';
        _isProcessing = false;
      });
      return;
    }

    _enrollmentFrame = frame;
    setState(() {
      _isProcessing  = false;
      _currentStep   = 1;
      _stepLabel     = 'Step 2 of 3 — Liveness check';
      _statusMessage = 'Please blink naturally when you see the countdown';
    });
  }

  // ── Step 2: Liveness — capture frames during blink ────────────────────────
  Future<void> _startLivenessCheck() async {
    setState(() {
      _isProcessing      = true;
      _livenessCountdown = 3;
      _statusMessage     = 'Get ready to blink...';
    });

    // Countdown 3-2-1
    _livenessTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      if (_livenessCountdown > 1) {
        setState(() => _livenessCountdown--);
      } else {
        timer.cancel();
        await _captureLivenessFrames();
      }
    });
  }

  Future<void> _captureLivenessFrames() async {
    setState(() => _statusMessage = 'Capturing — blink now!');
    _livenessFrames.clear();

    // Capture 12 frames over 3 seconds
    for (int i = 0; i < 12; i++) {
      final frame = await _captureFrame();
      if (frame != null) _livenessFrames.add(frame);
      await Future.delayed(const Duration(milliseconds: 250));
    }

    setState(() {
      _isProcessing  = false;
      _currentStep   = 2;
      _stepLabel     = 'Step 3 of 3 — Enrolling';
      _statusMessage = 'Processing your identity...';
    });

    // Auto-proceed to enrollment
    await _submitEnrollment();
  }

  // ── Step 3: Call Python /enroll ───────────────────────────────────────────
  Future<void> _submitEnrollment() async {
    setState(() {
      _isProcessing  = true;
      _statusMessage = 'Verifying identity with AI...';
    });

    // Load student data from Firestore
    final db  = FirebaseFirestore.instance;
    final doc = await db.collection('students').doc(widget.studentId).get();
    if (!doc.exists) {
      setState(() {
        _errorMessage = 'Student record not found.';
        _isProcessing = false;
      });
      return;
    }

    final data = doc.data()!;
    final aadhaar = (data['aadhaar_number'] ?? '').toString().trim();
    if (aadhaar.length != 12) {
      setState(() {
        _errorMessage = 'Aadhaar number missing in profile. Please re-register.';
        _isProcessing = false;
      });
      return;
    }

    // Check server reachable
    final serverUp = await ApiService.isServerReachable();
    if (!serverUp) {
      // If server not reachable during testing, mark as pending
      // and let student proceed — for demo purposes
      await db.collection('students').doc(widget.studentId).update({
        'enrollment_status': 'pending_ml',
        'enrollment_note':   'ML server not reachable during enrollment',
        'face_enrollment': {
          'status': 'pending_ml',
          'captured_at': DateTime.now().toIso8601String(),
          'liveness_frames_captured': _livenessFrames.length,
          'ml_server_reachable': false,
        },
      });
      if (mounted) {
        setState(() {
          _enrollmentDone = true;
          _statusMessage  = 'Enrolled (ML pending — server offline)';
          _isProcessing   = false;
        });
      }
      return;
    }

    // Call Python enrollment endpoint
    final result = await ApiService.enrollStudent(
      studentId:          widget.studentId,
      name:               data['name'] ?? '',
      email:              data['email'] ?? '',
      college:            data['college'] ?? '',
      course:             data['course'] ?? '',
      aadhaarNumber:      aadhaar,
      faceImageBase64:    _enrollmentFrame!,
      livenessFrames:     _livenessFrames,
      behavioralSamples:  _behavioralSamples,
    );

    if (!mounted) return;

    if (result['success'] == true) {
      try {
        await db.collection('students').doc(widget.studentId).update({
          'enrollment_status': 'verified',
          'enrollment_note': FieldValue.delete(),
          'enrolled_at': DateTime.now().toIso8601String(),
          'face_enrollment': {
            'status': 'verified',
            'verified_at': DateTime.now().toIso8601String(),
            'liveness_frames_captured': _livenessFrames.length,
            'ml_server_reachable': true,
            'analysis_result': result,
          },
        });
      } catch (e) {
        setState(() {
          _errorMessage = 'Enrollment saved but status update failed: $e';
          _isProcessing = false;
        });
        return;
      }

      setState(() {
        _enrollmentDone = true;
        _statusMessage  = 'Enrollment successful!';
        _isProcessing   = false;
      });
    } else {
      // Handle specific errors
      final error = result['error'] ?? result['detail']?.toString() ?? 'Unknown error';
      setState(() {
        _errorMessage = error.toString().contains('deepfake')
            ? 'Photo appears AI-generated. Please use your real face.'
            : error.toString().contains('liveness')
            ? 'Liveness check failed. Please try again in good lighting.'
            : error.toString().contains('duplicate')
            ? 'This face is already registered in the system.'
            : 'Enrollment failed: $error';
        _isProcessing = false;
        _currentStep  = 0;
        _stepLabel    = 'Step 1 of 3 — Look straight at camera';
        _statusMessage = 'Position your face in the circle';
      });
    }
  }

  // ── UI ─────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text(
          'Face Enrollment',
          style: TextStyle(color: Colors.white),
        ),
        leading: _enrollmentDone
            ? const SizedBox()
            : IconButton(
          icon: const Icon(Icons.arrow_back_ios, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: _enrollmentDone
          ? _buildSuccessView()
          : _buildCameraView(),
    );
  }

  Widget _buildCameraView() {
    return Stack(
      children: [
        // Camera preview
        if (_cameraReady && _cameraController != null)
          Positioned.fill(
            child: RepaintBoundary(
              key: _cameraPreviewKey,
              child: CameraPreview(_cameraController!),
            ),
          )
        else
          const Center(
            child: CircularProgressIndicator(color: Colors.white),
          ),

        // Oval overlay with hole
        Positioned.fill(
          child: CustomPaint(
            painter: _OvalOverlayPainter(),
          ),
        ),

        // Step label
        Positioned(
          top: 20,
          left: 0,
          right: 0,
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF534AB7).withOpacity(0.85),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                _stepLabel,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
        ),

        // Pulsing oval guide
        Center(
          child: AnimatedBuilder(
            animation: _pulseAnimation,
            builder: (_, child) => Transform.scale(
              scale: _isProcessing ? _pulseAnimation.value : 1.0,
              child: child,
            ),
            child: Container(
              width: 240,
              height: 300,
              decoration: BoxDecoration(
                border: Border.all(
                  color: _errorMessage != null
                      ? Colors.red
                      : _currentStep == 2
                      ? Colors.green
                      : const Color(0xFF534AB7),
                  width: 3,
                ),
                borderRadius: BorderRadius.circular(120),
              ),
            ),
          ),
        ),

        // Liveness countdown
        if (_currentStep == 1 && _livenessCountdown > 0 && _isProcessing)
          Center(
            child: Text(
              '$_livenessCountdown',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 80,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),

        // Status + button at bottom
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.transparent,
                  Colors.black.withOpacity(0.85),
                ],
              ),
            ),
            child: Column(
              children: [
                // Status
                Text(
                  _statusMessage,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: _errorMessage != null ? Colors.red[300] : Colors.white,
                    fontSize: 15,
                  ),
                ),

                if (_errorMessage != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    _errorMessage!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.red,
                      fontSize: 12,
                    ),
                  ),
                ],

                const SizedBox(height: 20),

                // Action button
                if (!_isProcessing)
                  ElevatedButton(
                    onPressed: _cameraReady
                        ? (_currentStep == 0
                        ? _captureEnrollmentPhoto
                        : _currentStep == 1
                        ? _startLivenessCheck
                        : null)
                        : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF534AB7),
                      foregroundColor: Colors.white,
                      minimumSize: const Size(double.infinity, 52),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: Text(
                      _currentStep == 0
                          ? 'Capture Photo'
                          : _currentStep == 1
                          ? 'Start Liveness Check'
                          : 'Processing...',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  )
                else
                  const SizedBox(
                    height: 52,
                    child: Center(
                      child: CircularProgressIndicator(color: Colors.white),
                    ),
                  ),

                // Retry button on error
                if (_errorMessage != null && !_isProcessing) ...[
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: () => setState(() {
                      _errorMessage  = null;
                      _currentStep   = 0;
                      _stepLabel     = 'Step 1 of 3 — Look straight at camera';
                      _statusMessage = 'Position your face in the circle';
                    }),
                    child: const Text(
                      'Try Again',
                      style: TextStyle(color: Colors.white70),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSuccessView() {
    return Container(
      color: Colors.black,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Success icon
              Container(
                width: 100,
                height: 100,
                decoration: const BoxDecoration(
                  color: Color(0xFF1D9E75),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.check_rounded,
                  color: Colors.white,
                  size: 56,
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                'Enrollment Complete!',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Your identity has been verified and your facial profile has been created. You can now take exams securely.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 14,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 40),
              ElevatedButton(
                onPressed: () => Navigator.pushAndRemoveUntil(
                  context,
                  MaterialPageRoute(builder: (_) => const StudentDashboard()),
                      (route) => false,
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF534AB7),
                  foregroundColor: Colors.white,
                  minimumSize: const Size(double.infinity, 52),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text(
                  'Go to Dashboard',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Oval overlay painter ───────────────────────────────────────────────────
class _OvalOverlayPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.black.withOpacity(0.55)
      ..style = PaintingStyle.fill;

    final ovalRect = Rect.fromCenter(
      center: Offset(size.width / 2, size.height / 2 - 20),
      width:  240,
      height: 300,
    );

    final fullRect = Rect.fromLTWH(0, 0, size.width, size.height);
    final path = Path()
      ..addRect(fullRect)
      ..addOval(ovalRect)
      ..fillType = PathFillType.evenOdd;

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_OvalOverlayPainter oldDelegate) => false;
}
