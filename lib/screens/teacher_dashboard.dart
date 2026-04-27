import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:image_picker/image_picker.dart';
import '../services/auth_service.dart';
import '../services/api_service.dart';
import '../services/ai_service.dart';
import '../services/grading_service.dart';
import 'report_screen.dart';

class TeacherDashboard extends StatefulWidget {
  const TeacherDashboard({super.key});

  @override
  State<TeacherDashboard> createState() => _TeacherDashboardState();
}

class _TeacherDashboardState extends State<TeacherDashboard>
    with SingleTickerProviderStateMixin {
  final _auth = AuthService();
  final _db   = FirebaseFirestore.instance;

  late TabController _tabController;

  Map<String, dynamic>? _teacherData;
  List<Map<String, dynamic>> _liveExams      = [];
  List<Map<String, dynamic>> _upcomingExams  = [];
  List<Map<String, dynamic>> _completedExams = [];
  bool _isLoading = true;

  // Live alert feed
  final List<Map<String, dynamic>> _alerts = [];
  int _unreadAlerts = 0;
  StreamSubscription<QuerySnapshot>? _alertSub;

  DateTime? _parseDate(dynamic value) {
    if (value == null) return null;
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;
    if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
    if (value is String) return DateTime.tryParse(value);
    return null;
  }

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _loadData();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _alertSub?.cancel();
    super.dispose();
  }

  void _startAlertStream() {
    _alertSub?.cancel();
    final ids = _liveExams.map((e) => e['id'] as String).take(10).toList();
    if (ids.isEmpty) return;

    _alertSub = _db
        .collection('exam_events')
        .where('exam_id', whereIn: ids)
        .where('flag_level', whereIn: ['hard', 'critical'])
        .snapshots()
        .listen((snap) {
      for (final change in snap.docChanges) {
        if (change.type != DocumentChangeType.added) continue;
        final data = Map<String, dynamic>.from(change.doc.data()!);
        if (!mounted) return;
        setState(() {
          _alerts.insert(0, data);
          if (_alerts.length > 100) _alerts.removeLast();
          _unreadAlerts++;
        });
        _showAlertBanner(data);
      }
    });
  }

  void _showAlertBanner(Map<String, dynamic> event) {
    if (!mounted) return;
    final score     = event['fraud_score'] ?? 0;
    final level     = event['flag_level'] ?? 'hard';
    final studentId = event['student_id'] ?? '';
    final isCrit    = level == 'critical';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: isCrit ? const Color(0xFFA32D2D) : const Color(0xFFBA7517),
        duration: const Duration(seconds: 5),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        content: Row(
          children: [
            Icon(isCrit ? Icons.error_rounded : Icons.warning_rounded,
                color: Colors.white, size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '${isCrit ? 'CRITICAL' : 'HIGH'} — Student $studentId · Score $score',
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
            ),
          ],
        ),
        action: SnackBarAction(
          label: 'View',
          textColor: Colors.white,
          onPressed: _showAlertFeed,
        ),
      ),
    );
  }

  void _showAlertFeed() {
    setState(() => _unreadAlerts = 0);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        minChildSize: 0.4,
        maxChildSize: 0.92,
        expand: false,
        builder: (_, sc) => _buildAlertSheet(sc),
      ),
    );
  }

  Widget _buildAlertSheet(ScrollController sc) {
    return Column(
      children: [
        Container(
          margin: const EdgeInsets.only(top: 10),
          width: 40, height: 4,
          decoration: BoxDecoration(
            color: Colors.grey[300],
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
          child: Row(
            children: [
              const Icon(Icons.notifications_active_rounded,
                  color: Color(0xFFA32D2D), size: 20),
              const SizedBox(width: 8),
              const Text('Live Alerts',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const Spacer(),
              if (_alerts.isNotEmpty)
                TextButton(
                  onPressed: () => setState(() => _alerts.clear()),
                  child: const Text('Clear all',
                      style: TextStyle(fontSize: 12, color: Colors.grey)),
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: _alerts.isEmpty
              ? const Center(
                  child: Text('No alerts yet.',
                      style: TextStyle(color: Colors.grey, fontSize: 14)),
                )
              : ListView.separated(
                  controller: sc,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: _alerts.length,
                  separatorBuilder: (_, __) =>
                      const Divider(height: 1, indent: 16, endIndent: 16),
                  itemBuilder: (_, i) => _alertTile(_alerts[i]),
                ),
        ),
      ],
    );
  }

  Widget _alertTile(Map<String, dynamic> event) {
    final level     = event['flag_level'] ?? 'hard';
    final score     = event['fraud_score'] ?? 0;
    final studentId = event['student_id'] ?? '';
    final examId    = event['exam_id'] ?? '';
    final ts        = DateTime.tryParse(event['timestamp'] ?? '');
    final isCrit    = level == 'critical';

    final timeLabel = ts != null
        ? '${ts.hour.toString().padLeft(2, '0')}:${ts.minute.toString().padLeft(2, '0')}'
        : '';

    String reason = 'Suspicious activity';
    if (event['face_absent'] == true)         reason = 'Face absent from camera';
    else if (event['multiple_faces'] == true) reason = 'Multiple faces detected';
    else if (event['deepfake'] == true)       reason = 'Possible deepfake/spoof';
    else if ((event['tab_switch_count'] ?? 0) > 2) reason = 'Repeated tab switching';

    return ListTile(
      leading: CircleAvatar(
        radius: 18,
        backgroundColor: isCrit ? const Color(0xFFFCEBEB) : const Color(0xFFFAEEDA),
        child: Icon(
          isCrit ? Icons.error_rounded : Icons.warning_amber_rounded,
          color: isCrit ? const Color(0xFFA32D2D) : const Color(0xFFBA7517),
          size: 18,
        ),
      ),
      title: Text(
        studentId,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        '$reason · Score $score',
        style: TextStyle(
          fontSize: 12,
          color: isCrit ? const Color(0xFFA32D2D) : const Color(0xFFBA7517),
        ),
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(timeLabel,
              style: const TextStyle(fontSize: 11, color: Colors.grey)),
          const SizedBox(height: 4),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: isCrit ? const Color(0xFFA32D2D) : const Color(0xFFBA7517),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              level.toUpperCase(),
              style: const TextStyle(color: Colors.white, fontSize: 10,
                  fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
      onTap: () {
        Navigator.pop(context);
        final exam = _liveExams.firstWhere(
          (e) => e['id'] == examId,
          orElse: () => {'id': examId, 'title': examId},
        );
        Navigator.push(context, MaterialPageRoute(
          builder: (_) => ReportScreen(
            examId: examId,
            examTitle: exam['title'] ?? examId,
            isLive: true,
          ),
        ));
      },
    );
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    try {
      final user = FirebaseAuth.instance.currentUser;
      final uid = user?.uid;
      if (uid == null) return;

      // Load teacher profile
      final teacherDoc = await _db.collection('teachers').doc(uid).get();
      if (teacherDoc.exists) {
        _teacherData = {'id': teacherDoc.id, ...teacherDoc.data()!};
      }

      // Load all exams by this teacher
      final examsByTeacherId = await _db
          .collection('exams')
          .where('teacher_id', isEqualTo: uid)
          .get();
      final teacherEmail = (user?.email ?? _teacherData?['email'] ?? '').toString().trim();
      QuerySnapshot<Map<String, dynamic>>? examsByEmail;
      if (teacherEmail.isNotEmpty) {
        examsByEmail = await _db
            .collection('exams')
            .where('teacher_email', isEqualTo: teacherEmail)
            .get();
      }

      final examDocsById = <String, Map<String, dynamic>>{};
      for (final doc in examsByTeacherId.docs) {
        examDocsById[doc.id] = {'id': doc.id, ...doc.data()};
      }
      for (final doc in examsByEmail?.docs ?? const []) {
        examDocsById[doc.id] = {'id': doc.id, ...doc.data()};
      }

      final now = DateTime.now();
      _liveExams      = [];
      _upcomingExams  = [];
      _completedExams = [];

      for (final exam in examDocsById.values) {
        final startTime = _parseDate(exam['start_time']) ?? now;
        final endTime   = _parseDate(exam['end_time']) ?? now;

        if (now.isAfter(startTime) && now.isBefore(endTime)) {
          _liveExams.add(exam);
        } else if (startTime.isAfter(now)) {
          _upcomingExams.add(exam);
        } else {
          _completedExams.add(exam);
        }
      }

      _completedExams.sort((a, b) {
        final aTime = _parseDate(a['end_time']) ?? now;
        final bTime = _parseDate(b['end_time']) ?? now;
        return bTime.compareTo(aTime); // newest first
      });

    } catch (e) {
      debugPrint('Error loading teacher data: $e');
    }
    if (mounted) setState(() => _isLoading = false);
    _startAlertStream();
  }

  Future<void> _logout() async {
    await _auth.logout();
    if (mounted) Navigator.pushReplacementNamed(context, '/login');
  }

  // ── Generate report for completed exam ────────────────────────────────────
  Future<void> _generateReport(Map<String, dynamic> exam) async {
    final examId = exam['id'];

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(color: Color(0xFF534AB7)),
            SizedBox(width: 16),
            Expanded(child: Text('Checking submissions...')),
          ],
        ),
      ),
    );

    try {
      // Check how many students actually submitted answers
      final answersSnap = await _db
          .collection('exam_answers')
          .where('exam_id', isEqualTo: examId)
          .get();

      if (!mounted) return;

      if (answersSnap.docs.isEmpty) {
        Navigator.pop(context);
        _showNoSubmissionsDialog(exam['title'] ?? 'this exam');
        return;
      }

      debugPrint('[Report] ${answersSnap.docs.length} submission(s) found for $examId');

      // Grade all submitted answers → writes to exam_scores
      await GradingService.gradeExam(examId);

      // Build report documents from exam_events + exam_scores → writes to reports
      await _saveReportToFirestore(examId);

      // Send email notification
      final teacherEmail = _teacherData?['email'] ?? '';
      if (teacherEmail.isNotEmpty) {
        await ApiService.sendReportEmail(
          examId:       examId,
          teacherEmail: teacherEmail,
        );
      }

      if (!mounted) return;
      Navigator.pop(context);

      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ReportScreen(
            examId:    examId,
            examTitle: exam['title'] ?? '',
          ),
        ),
      );

      _loadData();
    } catch (e) {
      if (!mounted) return;
      Navigator.pop(context);
      _showError('Failed to generate report: $e');
    }
  }

  void _showNoSubmissionsDialog(String examTitle) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.inbox_outlined, color: Color(0xFFBA7517)),
            SizedBox(width: 8),
            Text('No Submissions Yet'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'No students have submitted "$examTitle" yet.',
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 12),
            const Text(
              'Students must:\n'
              '1. Be enrolled (face registration complete)\n'
              '2. Open the exam from their dashboard\n'
              '3. Pass face verification\n'
              '4. Complete and submit the exam',
              style: TextStyle(fontSize: 13, color: Colors.black87, height: 1.6),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _saveReportToFirestore(String examId) async {
    // Fetch all monitoring events grouped by student
    final eventsSnap = await _db
        .collection('exam_events')
        .where('exam_id', isEqualTo: examId)
        .get();

    final byStudent = <String, List<Map<String, dynamic>>>{};
    for (final doc in eventsSnap.docs) {
      final data      = doc.data();
      final studentId = '${data['student_id'] ?? ''}'.trim();
      if (studentId.isEmpty) continue;
      byStudent.putIfAbsent(studentId, () => []).add(data);
    }

    // Fetch all graded scores
    final scoresSnap = await _db
        .collection('exam_scores')
        .where('exam_id', isEqualTo: examId)
        .get();

    // Fetch all answer submissions (students who submitted even with no events)
    final answersSnap = await _db
        .collection('exam_answers')
        .where('exam_id', isEqualTo: examId)
        .get();

    // Union of all student IDs across all three sources
    final allStudents = <String>{
      ...byStudent.keys,
      ...scoresSnap.docs.map((d) => '${d.data()['student_id'] ?? ''}'),
      ...answersSnap.docs.map((d) => '${d.data()['student_id'] ?? ''}'),
    }..remove('');

    int cleanCount    = 0;
    int flaggedCount  = 0;
    int criticalCount = 0;
    double totalFraud = 0;

    // Build a name map: prefer student_name stored in exam_answers, then look
    // up the students collection, finally fall back to the raw UID.
    final nameMap = <String, String>{};
    for (final d in answersSnap.docs) {
      final sid  = '${d.data()['student_id'] ?? ''}'.trim();
      final name = '${d.data()['student_name'] ?? ''}'.trim();
      if (sid.isNotEmpty && name.isNotEmpty) nameMap[sid] = name;
    }
    // Look up any still-missing names from the students collection
    for (final sid in allStudents) {
      if (nameMap.containsKey(sid)) continue;
      try {
        final doc = await _db.collection('students').doc(sid).get();
        final name = (doc.data()?['name'] as String?)?.trim() ?? '';
        if (name.isNotEmpty) nameMap[sid] = name;
      } catch (_) {}
    }

    // Write each student report individually so one failure can't block others
    for (final studentId in allStudents) {
      try {
        final events = byStudent[studentId] ?? [];
        events.sort((a, b) =>
            (a['timestamp'] ?? '').compareTo(b['timestamp'] ?? ''));

        // Cap timeline at 50 events to stay well under Firestore's 1MB doc limit
        final timeline = events.length > 50
            ? events.sublist(events.length - 50)
            : events;

        final fraudScores = events
            .map((e) => ((e['fraud_score'] ?? 0) as num).toInt())
            .toList();
        final maxFraud = fraudScores.isNotEmpty
            ? fraudScores.reduce((a, b) => a > b ? a : b)
            : 0;
        totalFraud += maxFraud;

        final flagCount = events
            .where((e) =>
                ['soft', 'hard', 'critical'].contains(e['flag_level']))
            .length;

        double faceMismatch    = 0;
        double behavioralDrift = 0;
        double deepfakeScore   = 0;
        for (final e in events) {
          final fm = ((e['face_match_score'] as num?) ?? 1.0).toDouble();
          faceMismatch    += (1.0 - fm).clamp(0.0, 1.0) * 10;
          final bd = ((e['behavioral_drift'] as num?) ?? 0.0).toDouble();
          behavioralDrift += bd * 10;
          if (e['deepfake'] == true) deepfakeScore += 15;
        }
        if (events.isNotEmpty) {
          faceMismatch    = (faceMismatch    / events.length).clamp(0, 40);
          behavioralDrift = (behavioralDrift / events.length).clamp(0, 40);
        }
        deepfakeScore = deepfakeScore.clamp(0, 40);

        final tabSwitches = events
            .where((e) =>
                e['event_type'] == 'tab_switched' ||
                e['event_type'] == 'app_backgrounded')
            .length;
        if (tabSwitches > 0) {
          behavioralDrift =
              (behavioralDrift + tabSwitches * 5).clamp(0, 40);
        }

        final String recommendation;
        if (maxFraud > 75) {
          criticalCount++;
          recommendation = 'escalate';
        } else if (maxFraud > 55) {
          flaggedCount++;
          recommendation = 'investigate';
        } else if (maxFraud > 30) {
          flaggedCount++;
          recommendation = 'monitor';
        } else {
          cleanCount++;
          recommendation = 'clear';
        }

        final studentName = nameMap[studentId] ?? studentId;

        await _db
            .collection('reports')
            .doc('student_${examId}_$studentId')
            .set({
          'exam_id':           examId,
          'student_id':        studentId,
          'student_name':      studentName,
          'report_type':       'per_student',
          'final_fraud_score': maxFraud,
          'flag_count':        flagCount,
          'recommendation':    recommendation,
          'shap_values': {
            'face_mismatch':    faceMismatch,
            'behavioral_drift': behavioralDrift,
            'deepfake':         deepfakeScore,
          },
          'event_timeline':    timeline,
          'generated_at':      DateTime.now().toIso8601String(),
        });

        debugPrint('[Report] Wrote report for student $studentId');
      } catch (e) {
        debugPrint('[Report] Failed to write report for $studentId: $e');
      }
    }

    final avgFraud = allStudents.isNotEmpty
        ? totalFraud / allStudents.length
        : 0.0;

    // Class-wide summary and exam flag — use a small batch for atomicity
    final batch = _db.batch();
    batch.set(
      _db.collection('reports').doc('class_$examId'),
      {
        'exam_id':         examId,
        'total_students':  allStudents.length,
        'clean_count':     cleanCount,
        'flagged_count':   flaggedCount,
        'critical_count':  criticalCount,
        'avg_fraud_score': avgFraud,
        'generated_at':    DateTime.now().toIso8601String(),
      },
    );
    batch.set(
      _db.collection('reports').doc('flagged_$examId'),
      {
        'exam_id':       examId,
        'flagged_count': flaggedCount + criticalCount,
        'generated_at':  DateTime.now().toIso8601String(),
      },
    );
    batch.update(
      _db.collection('exams').doc(examId),
      {'report_generated': true},
    );
    await batch.commit();

    debugPrint('[Report] Done. ${allStudents.length} students processed.');
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: const Color(0xFFA32D2D),
      ),
    );
  }

  // ── AI Class Summary ───────────────────────────────────────────────────────
  Future<void> _getClassSummary(Map<String, dynamic> exam) async {
    final examId = exam['id'] as String;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(color: Color(0xFF534AB7)),
            SizedBox(width: 16),
            Expanded(child: Text('Generating class summary...')),
          ],
        ),
      ),
    );

    try {
      final examDoc = await _db.collection('exams').doc(examId).get();
      final questions = List<Map<String, dynamic>>.from(
        ((examDoc.data()?['questions'] as List?) ?? [])
            .map((q) => Map<String, dynamic>.from(q as Map)),
      );

      final scoresSnap = await _db
          .collection('exam_scores')
          .where('exam_id', isEqualTo: examId)
          .get();

      if (!mounted) return;

      if (scoresSnap.docs.isEmpty) {
        Navigator.pop(context);
        _showError('No graded scores found. Tap "Generate Report" first so student answers are graded.');
        return;
      }

      final studentScores =
          scoresSnap.docs.map((d) => d.data()).toList();

      // Per-question accuracy stats computed client-side
      final questionStats = <Map<String, dynamic>>[];
      for (var i = 0; i < questions.length; i++) {
        final q = questions[i];
        final marks = ((q['marks'] as num?) ?? 1).toInt();
        int answered = 0;
        int fullMarks = 0;
        int zeroMarks = 0;
        double totalEarned = 0;

        for (final s in studentScores) {
          final qList = (s['question_scores'] as List? ?? [])
              .cast<Map<String, dynamic>>();
          final qs = qList.cast<Map<String, dynamic>?>().firstWhere(
                (e) => e != null && (e['q_index'] as num?)?.toInt() == i,
                orElse: () => null,
              );
          if (qs != null) {
            answered++;
            final earned = ((qs['earned'] as num?) ?? 0).toInt();
            totalEarned += earned;
            if (earned == marks) fullMarks++;
            if (earned == 0) zeroMarks++;
          }
        }

        final avgPct =
            answered > 0 ? totalEarned / answered / marks * 100 : 0.0;
        final wrongPct =
            answered > 0 ? (answered - fullMarks) / answered * 100 : 0.0;

        questionStats.add({
          'q_index':        i,
          'question':       q['q'] ?? q['question'] ?? '',
          'type':           q['type'] ?? 'mcq',
          'marks':          marks,
          'answered_by':    answered,
          'full_marks_pct': double.parse(
              (answered > 0 ? fullMarks / answered * 100 : 0.0)
                  .toStringAsFixed(1)),
          'zero_marks_pct': double.parse(
              (answered > 0 ? zeroMarks / answered * 100 : 0.0)
                  .toStringAsFixed(1)),
          'avg_score_pct':  double.parse(avgPct.toStringAsFixed(1)),
          'wrong_pct':      double.parse(wrongPct.toStringAsFixed(1)),
        });
      }

      final percentages = studentScores
          .map((s) => ((s['percentage'] as num?) ?? 0.0).toDouble())
          .toList();
      final classAvg = percentages.isEmpty
          ? 0.0
          : percentages.reduce((a, b) => a + b) / percentages.length;
      final passRate = percentages.isEmpty
          ? 0.0
          : percentages.where((p) => p >= 50).length /
              percentages.length *
              100;

      final result = await ApiService.getClassSummary(
        examId:       examId,
        examTitle:    exam['title'] ?? '',
        studentCount: studentScores.length,
        classAvg:     classAvg,
        passRate:     passRate,
        questionStats: questionStats,
      );

      if (!mounted) return;
      Navigator.pop(context);

      if (result['success'] != true) {
        _showError(result['error'] ?? 'Class summary failed');
        return;
      }

      _showClassSummarySheet(
        title:       exam['title'] ?? '',
        classAvg:    classAvg,
        passRate:    passRate,
        studentCount: studentScores.length,
        result:      result,
      );
    } catch (e) {
      if (!mounted) return;
      Navigator.pop(context);
      _showError('Error: $e');
    }
  }

  void _showClassSummarySheet({
    required String title,
    required double classAvg,
    required double passRate,
    required int studentCount,
    required Map<String, dynamic> result,
  }) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.82,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (_, sc) => _buildClassSummarySheet(
          sc, title, classAvg, passRate, studentCount, result),
      ),
    );
  }

  Widget _buildClassSummarySheet(
    ScrollController sc,
    String title,
    double classAvg,
    double passRate,
    int studentCount,
    Map<String, dynamic> result,
  ) {
    final summary     = result['summary'] as String? ?? '';
    final hardest     = List<Map<String, dynamic>>.from(
        (result['hardest_questions'] as List? ?? [])
            .map((e) => Map<String, dynamic>.from(e as Map)));
    final missed      = List<String>.from(result['most_missed_concepts'] as List? ?? []);
    final strengths   = List<String>.from(result['class_strengths'] as List? ?? []);
    final reteach     = List<Map<String, dynamic>>.from(
        (result['reteach_topics'] as List? ?? [])
            .map((e) => Map<String, dynamic>.from(e as Map)));
    final encourage   = result['encouragement'] as String? ?? '';

    return Column(
      children: [
        Container(
          margin: const EdgeInsets.only(top: 10),
          width: 40, height: 4,
          decoration: BoxDecoration(
              color: Colors.grey[300],
              borderRadius: BorderRadius.circular(2)),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
          child: Row(
            children: [
              const Icon(Icons.auto_awesome_rounded,
                  color: Color(0xFF534AB7), size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'AI Class Summary · $title',
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.bold),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            controller: sc,
            padding: const EdgeInsets.all(16),
            children: [
              // Stat row
              Row(
                children: [
                  _classStat('${classAvg.toStringAsFixed(1)}%', 'Class Avg',
                      const Color(0xFF534AB7)),
                  const SizedBox(width: 10),
                  _classStat('${passRate.toStringAsFixed(0)}%', 'Pass Rate',
                      passRate >= 70
                          ? const Color(0xFF1D9E75)
                          : const Color(0xFFBA7517)),
                  const SizedBox(width: 10),
                  _classStat('$studentCount', 'Students',
                      const Color(0xFF444441)),
                ],
              ),
              const SizedBox(height: 14),

              // AI summary paragraph
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF534AB7), Color(0xFF7B74E0)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  summary,
                  style: const TextStyle(
                      color: Colors.white, fontSize: 13, height: 1.5),
                ),
              ),
              const SizedBox(height: 16),

              // Hardest questions
              if (hardest.isNotEmpty) ...[
                _sectionHeader(Icons.trending_down_rounded,
                    'Hardest Questions', const Color(0xFFA32D2D)),
                const SizedBox(height: 8),
                ...hardest.map((q) => _hardestQCard(q)),
                const SizedBox(height: 14),
              ],

              // Most missed concepts + strengths in a row
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (missed.isNotEmpty)
                    Expanded(
                      child: _chipSection(
                        icon: Icons.warning_amber_rounded,
                        label: 'Missed Concepts',
                        color: const Color(0xFFBA7517),
                        bgColor: const Color(0xFFFAEEDA),
                        items: missed,
                      ),
                    ),
                  if (missed.isNotEmpty && strengths.isNotEmpty)
                    const SizedBox(width: 10),
                  if (strengths.isNotEmpty)
                    Expanded(
                      child: _chipSection(
                        icon: Icons.thumb_up_alt_rounded,
                        label: 'Strengths',
                        color: const Color(0xFF1D9E75),
                        bgColor: const Color(0xFFE1F5EE),
                        items: strengths,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 14),

              // Re-teach recommendations
              if (reteach.isNotEmpty) ...[
                _sectionHeader(Icons.school_rounded,
                    'Re-Teaching Priorities', const Color(0xFF534AB7)),
                const SizedBox(height: 8),
                ...reteach.map((t) => _reteachCard(t)),
                const SizedBox(height: 14),
              ],

              // Encouragement
              if (encourage.isNotEmpty)
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFEEEDFE),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.favorite_rounded,
                          color: Color(0xFF534AB7), size: 16),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          encourage,
                          style: const TextStyle(
                              fontSize: 12,
                              color: Color(0xFF534AB7),
                              fontStyle: FontStyle.italic),
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ],
    );
  }

  Widget _classStat(String value, String label, Color color) => Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: color.withOpacity(0.08),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            children: [
              Text(value,
                  style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: color)),
              const SizedBox(height: 2),
              Text(label,
                  style: TextStyle(fontSize: 11, color: color.withOpacity(0.8))),
            ],
          ),
        ),
      );

  Widget _sectionHeader(IconData icon, String label, Color color) => Row(
        children: [
          Icon(icon, color: color, size: 16),
          const SizedBox(width: 6),
          Text(label,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: color)),
        ],
      );

  Widget _hardestQCard(Map<String, dynamic> q) {
    final wrongPct = ((q['wrong_pct'] as num?) ?? 0).toInt();
    final question = q['question'] as String? ?? '';
    final insight  = q['insight']  as String? ?? '';

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFCEBEB),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFA32D2D).withOpacity(0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFFA32D2D),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text(
                  '$wrongPct% wrong',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(question,
              style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF1a1a2e))),
          if (insight.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(insight,
                style: const TextStyle(
                    fontSize: 11, color: Color(0xFFA32D2D))),
          ],
        ],
      ),
    );
  }

  Widget _chipSection({
    required IconData icon,
    required String label,
    required Color color,
    required Color bgColor,
    required List<String> items,
  }) =>
      Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: color, size: 13),
                const SizedBox(width: 4),
                Text(label,
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: color)),
              ],
            ),
            const SizedBox(height: 6),
            ...items.map((item) => Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('• ',
                          style: TextStyle(
                              color: color, fontWeight: FontWeight.bold)),
                      Expanded(
                        child: Text(item,
                            style: TextStyle(
                                fontSize: 11, color: color.withOpacity(0.9))),
                      ),
                    ],
                  ),
                )),
          ],
        ),
      );

  Widget _reteachCard(Map<String, dynamic> t) {
    final topic      = t['topic']      as String? ?? '';
    final priority   = t['priority']   as String? ?? 'medium';
    final suggestion = t['suggestion'] as String? ?? '';
    final isHigh     = priority == 'high';

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
            color: const Color(0xFF534AB7).withOpacity(0.2)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            margin: const EdgeInsets.only(top: 2),
            padding:
                const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: isHigh
                  ? const Color(0xFF534AB7)
                  : const Color(0xFFEEEDFE),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              priority.toUpperCase(),
              style: TextStyle(
                  color: isHigh
                      ? Colors.white
                      : const Color(0xFF534AB7),
                  fontSize: 9,
                  fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(topic,
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF1a1a2e))),
                if (suggestion.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(suggestion,
                      style: const TextStyle(
                          fontSize: 11, color: Colors.grey)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Plagiarism detection ────────────────────────────────────────────────────
  Future<void> _checkPlagiarism(Map<String, dynamic> exam) async {
    final examId = exam['id'] as String;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(color: Color(0xFF534AB7)),
            SizedBox(width: 16),
            Expanded(child: Text('Analyzing answers for plagiarism...')),
          ],
        ),
      ),
    );

    try {
      // Fetch exam questions
      final examDoc = await _db.collection('exams').doc(examId).get();
      final questionsRaw = (examDoc.data()?['questions'] as List? ?? [])
          .cast<Map<String, dynamic>>();

      // Fetch all student answer docs for this exam
      final answerDocs = await _db
          .collection('exam_answers')
          .where('exam_id', isEqualTo: examId)
          .get();

      // Build name map: stored student_name first, then students collection
      final plagNameMap = <String, String>{};
      for (final doc in answerDocs.docs) {
        final d    = doc.data();
        final sid  = '${d['student_id'] ?? ''}'.trim();
        final name = '${d['student_name'] ?? ''}'.trim();
        if (sid.isNotEmpty && name.isNotEmpty) plagNameMap[sid] = name;
      }
      for (final doc in answerDocs.docs) {
        final sid = '${doc.data()['student_id'] ?? ''}'.trim();
        if (sid.isEmpty || plagNameMap.containsKey(sid)) continue;
        try {
          final sDoc = await _db.collection('students').doc(sid).get();
          final name = (sDoc.data()?['name'] as String?)?.trim() ?? '';
          if (name.isNotEmpty) plagNameMap[sid] = name;
        } catch (_) {}
      }

      final studentAnswers = answerDocs.docs.map((doc) {
        final d   = doc.data();
        final sid = '${d['student_id'] ?? doc.id}'.trim();
        return {
          'student_id':   sid,
          'student_name': plagNameMap[sid] ?? sid,
          'answers':      d['answers'] ?? {},
        };
      }).toList();

      if (!mounted) return;
      Navigator.pop(context); // close loading dialog

      if (studentAnswers.isEmpty) {
        _showError('No student submissions found. Students must submit the exam first.');
        return;
      }
      if (studentAnswers.length < 2) {
        _showError('Need at least 2 student submissions to check for plagiarism. Only ${studentAnswers.length} submission found.');
        return;
      }

      final result = await ApiService.detectPlagiarism(
        examId: examId,
        questions: questionsRaw,
        studentAnswers: studentAnswers,
      );

      if (!mounted) return;

      if (result['success'] != true) {
        _showError(result['error'] ?? 'Plagiarism check failed');
        return;
      }

      final flagged = List<Map<String, dynamic>>.from(
        (result['flagged_pairs'] as List? ?? [])
            .map((e) => Map<String, dynamic>.from(e as Map)),
      );
      final summary = result['summary'] as String? ?? '';
      _showPlagiarismSheet(exam['title'] ?? '', flagged, summary);
    } catch (e) {
      if (!mounted) return;
      Navigator.pop(context);
      _showError('Error: $e');
    }
  }

  void _showPlagiarismSheet(
    String examTitle,
    List<Map<String, dynamic>> flagged,
    String summary,
  ) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.75,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (_, sc) => _buildPlagiarismSheet(sc, examTitle, flagged, summary),
      ),
    );
  }

  Widget _buildPlagiarismSheet(
    ScrollController sc,
    String examTitle,
    List<Map<String, dynamic>> flagged,
    String summary,
  ) {
    return Column(
      children: [
        Container(
          margin: const EdgeInsets.only(top: 10),
          width: 40,
          height: 4,
          decoration: BoxDecoration(
            color: Colors.grey[300],
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
          child: Row(
            children: [
              const Icon(Icons.content_copy_rounded,
                  color: Color(0xFF534AB7), size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Plagiarism Report · $examTitle',
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.bold),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            controller: sc,
            padding: const EdgeInsets.all(16),
            children: [
              // Summary card
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: flagged.isEmpty
                      ? const Color(0xFFE1F5EE)
                      : const Color(0xFFFCF3DC),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      flagged.isEmpty
                          ? Icons.verified_rounded
                          : Icons.warning_amber_rounded,
                      color: flagged.isEmpty
                          ? const Color(0xFF1D9E75)
                          : const Color(0xFFBA7517),
                      size: 20,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            flagged.isEmpty
                                ? 'No Plagiarism Detected'
                                : '${flagged.length} Suspicious Pair${flagged.length > 1 ? 's' : ''} Found',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                              color: flagged.isEmpty
                                  ? const Color(0xFF085041)
                                  : const Color(0xFFBA7517),
                            ),
                          ),
                          if (summary.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              summary,
                              style: const TextStyle(
                                  fontSize: 12, color: Colors.black87),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              if (flagged.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 40),
                  child: Center(
                    child: Text(
                      'All text answers appear original.',
                      style: TextStyle(color: Colors.grey, fontSize: 14),
                    ),
                  ),
                )
              else ...[
                const SizedBox(height: 16),
                ...flagged.map((pair) => _plagiarismPairCard(pair)),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _plagiarismPairCard(Map<String, dynamic> pair) {
    final riskLevel = pair['risk_level'] as String? ?? 'medium';
    final score = ((pair['similarity_score'] as num?)?.toDouble() ?? 0.0);
    final pct = (score * 100).toStringAsFixed(0);
    final studentA = pair['student_a'] as String? ?? '';
    final studentB = pair['student_b'] as String? ?? '';
    final question = pair['question'] as String? ?? '';
    final answerA = pair['answer_a'] as String? ?? '';
    final answerB = pair['answer_b'] as String? ?? '';
    final reasoning = pair['reasoning'] as String? ?? '';

    final Color riskColor;
    final Color riskBg;
    switch (riskLevel) {
      case 'high':
        riskColor = const Color(0xFFA32D2D);
        riskBg = const Color(0xFFFCEBEB);
      case 'low':
        riskColor = const Color(0xFF085041);
        riskBg = const Color(0xFFE1F5EE);
      default:
        riskColor = const Color(0xFFBA7517);
        riskBg = const Color(0xFFFAEEDA);
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: riskColor.withOpacity(0.3)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: riskBg,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    riskLevel.toUpperCase(),
                    style: TextStyle(
                      color: riskColor,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '$pct% similarity',
                  style: TextStyle(
                    color: riskColor,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
                const Spacer(),
                const Icon(Icons.people_alt_rounded,
                    size: 14, color: Colors.grey),
                const SizedBox(width: 4),
                Text(
                  '$studentA & $studentB',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Q: $question',
              style: const TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF1a1a2e)),
            ),
            const SizedBox(height: 8),
            _answerCompareRow(studentA, answerA),
            const SizedBox(height: 4),
            _answerCompareRow(studentB, answerB),
            if (reasoning.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFFF5F4FF),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.auto_awesome,
                        size: 13, color: Color(0xFF534AB7)),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        reasoning,
                        style: const TextStyle(
                            fontSize: 11, color: Color(0xFF534AB7)),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _answerCompareRow(String studentId, String answer) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: const Color(0xFFEEEDFE),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            studentId,
            style: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.bold,
                color: Color(0xFF534AB7)),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            answer,
            style: const TextStyle(fontSize: 12, color: Colors.black87),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8F7FF),
      appBar: AppBar(
        title: const Text('ExamIQ'),
        automaticallyImplyLeading: false,
        actions: [
          // Live alert bell
          Stack(
            alignment: Alignment.center,
            children: [
              IconButton(
                icon: const Icon(Icons.notifications_rounded),
                tooltip: 'Live Alerts',
                onPressed: _showAlertFeed,
              ),
              if (_unreadAlerts > 0)
                Positioned(
                  top: 8,
                  right: 8,
                  child: GestureDetector(
                    onTap: _showAlertFeed,
                    child: Container(
                      padding: const EdgeInsets.all(3),
                      decoration: const BoxDecoration(
                        color: Color(0xFFA32D2D),
                        shape: BoxShape.circle,
                      ),
                      constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                      child: Text(
                        _unreadAlerts > 99 ? '99+' : '$_unreadAlerts',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadData,
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: _logout,
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: Colors.white,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white60,
          tabs: [
            Tab(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Live'),
                  if (_liveExams.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    _liveBadge(_liveExams.length),
                  ],
                ],
              ),
            ),
            const Tab(text: 'Upcoming'),
            const Tab(text: 'Completed'),
          ],
        ),
      ),
      body: _isLoading
          ? const Center(
        child: CircularProgressIndicator(color: Color(0xFF534AB7)),
      )
          : Column(
        children: [
          _buildTeacherHeader(),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildLiveTab(),
                _buildUpcomingTab(),
                _buildCompletedTab(),
              ],
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showCreateExamDialog,
        backgroundColor: const Color(0xFF534AB7),
        icon: const Icon(Icons.add, color: Colors.white),
        label: const Text(
          'Create Exam',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }

  // ── Teacher header ─────────────────────────────────────────────────────────
  Widget _buildTeacherHeader() {
    final name       = _teacherData?['name'] ?? 'Teacher';
    final college    = _teacherData?['college'] ?? '';
    final department = _teacherData?['department'] ?? '';

    return Container(
      padding: const EdgeInsets.all(16),
      color: Colors.white,
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: const Color(0xFFEEEDFE),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(
              Icons.school_rounded,
              color: Color(0xFF534AB7),
              size: 26,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF1a1a2e),
                  ),
                ),
                Text(
                  '$department • $college',
                  style: const TextStyle(
                    fontSize: 11,
                    color: Colors.grey,
                  ),
                ),
              ],
            ),
          ),
          // Quick stats
          _miniStat('${_liveExams.length}', 'Live',      const Color(0xFF1D9E75)),
          const SizedBox(width: 12),
          _miniStat('${_completedExams.length}', 'Done', const Color(0xFF534AB7)),
        ],
      ),
    );
  }

  Widget _miniStat(String value, String label, Color color) => Column(
    children: [
      Text(value,
          style: TextStyle(
              fontSize: 18, fontWeight: FontWeight.bold, color: color)),
      Text(label,
          style: TextStyle(fontSize: 10, color: color.withOpacity(0.7))),
    ],
  );

  Widget _liveBadge(int count) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: const Color(0xFFE24B4A),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Text(
      '$count',
      style: const TextStyle(
          color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
    ),
  );

  // ── Live tab ───────────────────────────────────────────────────────────────
  Widget _buildLiveTab() {
    if (_liveExams.isEmpty) {
      return _emptyState(
        Icons.live_tv_rounded,
        'No live exams',
        'Exams currently in progress will appear here.',
      );
    }
    return RefreshIndicator(
      onRefresh: _loadData,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _liveExams.length,
        itemBuilder: (_, i) => _liveExamCard(_liveExams[i]),
      ),
    );
  }

  Widget _liveExamCard(Map<String, dynamic> exam) {
    final title            = exam['title'] ?? 'Untitled';
    final registeredCount  = (exam['registered_students'] as List?)?.length ?? 0;
    final endTime          = _parseDate(exam['end_time']);
    final minsLeft         = endTime != null
        ? endTime.difference(DateTime.now()).inMinutes
        : 0;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF1D9E75), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF1D9E75).withOpacity(0.1),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(
                    color: Color(0xFF1D9E75),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                const Text(
                  'LIVE',
                  style: TextStyle(
                    color: Color(0xFF1D9E75),
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1,
                  ),
                ),
                const Spacer(),
                Text(
                  '$minsLeft min remaining',
                  style: const TextStyle(
                    color: Colors.grey,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              title,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: Color(0xFF1a1a2e),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                const Icon(Icons.people_outline, size: 14, color: Colors.grey),
                const SizedBox(width: 4),
                Text(
                  '$registeredCount students',
                  style: const TextStyle(color: Colors.grey, fontSize: 12),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // Live monitoring button
            StreamBuilder<QuerySnapshot>(
              stream: _db
                  .collection('exam_events')
                  .where('exam_id', isEqualTo: exam['id'])
                  .where('flag_level', whereIn: ['hard', 'critical'])
                  .snapshots(),
              builder: (context, snapshot) {
                final flagCount = snapshot.data?.docs.length ?? 0;
                return Row(
                  children: [
                    if (flagCount > 0)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFCEBEB),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.warning_rounded,
                                color: Color(0xFFA32D2D), size: 14),
                            const SizedBox(width: 4),
                            Text(
                              '$flagCount flagged',
                              style: const TextStyle(
                                color: Color(0xFFA32D2D),
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    const Spacer(),
                    ElevatedButton.icon(
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => ReportScreen(
                            examId:    exam['id'],
                            examTitle: title,
                            isLive:    true,
                          ),
                        ),
                      ),
                      icon: const Icon(Icons.monitor_heart_outlined, size: 16),
                      label: const Text('Monitor Live'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF1D9E75),
                        foregroundColor: Colors.white,
                        minimumSize: const Size(0, 36),
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  // ── Upcoming tab ───────────────────────────────────────────────────────────
  Widget _buildUpcomingTab() {
    if (_upcomingExams.isEmpty) {
      return _emptyState(
        Icons.event_outlined,
        'No upcoming exams',
        'Create an exam using the button below.',
      );
    }
    return RefreshIndicator(
      onRefresh: _loadData,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _upcomingExams.length,
        itemBuilder: (_, i) => _upcomingExamCard(_upcomingExams[i]),
      ),
    );
  }

  Widget _upcomingExamCard(Map<String, dynamic> exam) {
    final title           = exam['title'] ?? 'Untitled';
    final startTime       = _parseDate(exam['start_time']);
    final registeredCount = (exam['registered_students'] as List?)?.length ?? 0;
    final duration        = exam['duration_mins'] ?? 90;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
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
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: Color(0xFF1a1a2e),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.calendar_today_outlined,
                    size: 13, color: Colors.grey),
                const SizedBox(width: 4),
                Text(
                  startTime != null ? _formatDate(startTime) : 'TBD',
                  style: const TextStyle(color: Colors.grey, fontSize: 12),
                ),
                const SizedBox(width: 16),
                const Icon(Icons.timer_outlined, size: 13, color: Colors.grey),
                const SizedBox(width: 4),
                Text(
                  '$duration mins',
                  style: const TextStyle(color: Colors.grey, fontSize: 12),
                ),
                const SizedBox(width: 16),
                const Icon(Icons.people_outline, size: 13, color: Colors.grey),
                const SizedBox(width: 4),
                Text(
                  '$registeredCount registered',
                  style: const TextStyle(color: Colors.grey, fontSize: 12),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ── Completed tab ──────────────────────────────────────────────────────────
  Widget _buildCompletedTab() {
    if (_completedExams.isEmpty) {
      return _emptyState(
        Icons.history_rounded,
        'No completed exams',
        'Finished exams will appear here with reports.',
      );
    }
    return RefreshIndicator(
      onRefresh: _loadData,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _completedExams.length,
        itemBuilder: (_, i) => _completedExamCard(_completedExams[i]),
      ),
    );
  }

  Widget _completedExamCard(Map<String, dynamic> exam) {
    final title           = exam['title'] ?? 'Untitled';
    final endTime         = _parseDate(exam['end_time']);
    final registeredCount = (exam['registered_students'] as List?)?.length ?? 0;
    final reportGenerated = exam['report_generated'] == true;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
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
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF1a1a2e),
                    ),
                  ),
                ),
                Container(
                  padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: reportGenerated
                        ? const Color(0xFFE1F5EE)
                        : const Color(0xFFF1EFE8),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    reportGenerated ? 'Report Ready' : 'No Report',
                    style: TextStyle(
                      color: reportGenerated
                          ? const Color(0xFF085041)
                          : const Color(0xFF444441),
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.event_available_outlined,
                    size: 13, color: Colors.grey),
                const SizedBox(width: 4),
                Text(
                  endTime != null ? _formatDate(endTime) : 'Unknown',
                  style: const TextStyle(color: Colors.grey, fontSize: 12),
                ),
                const SizedBox(width: 16),
                const Icon(Icons.people_outline, size: 13, color: Colors.grey),
                const SizedBox(width: 4),
                Text(
                  '$registeredCount students',
                  style: const TextStyle(color: Colors.grey, fontSize: 12),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: reportGenerated
                        ? () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ReportScreen(
                          examId:    exam['id'],
                          examTitle: title,
                        ),
                      ),
                    )
                        : null,
                    icon: const Icon(Icons.bar_chart_rounded, size: 16),
                    label: const Text('View Report'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF534AB7),
                      side: const BorderSide(color: Color(0xFF534AB7)),
                      minimumSize: const Size(0, 38),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () => _generateReport(exam),
                    icon: Icon(
                      reportGenerated
                          ? Icons.refresh_rounded
                          : Icons.auto_awesome_rounded,
                      size: 16,
                    ),
                    label: Text(reportGenerated ? 'Regenerate' : 'Generate Report'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF534AB7),
                      foregroundColor: Colors.white,
                      minimumSize: const Size(0, 38),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _checkPlagiarism(exam),
                    icon: const Icon(Icons.content_copy_rounded, size: 15),
                    label: const Text('Plagiarism'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFFBA7517),
                      side: const BorderSide(color: Color(0xFFBA7517)),
                      minimumSize: const Size(0, 38),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _getClassSummary(exam),
                    icon: const Icon(Icons.auto_awesome_rounded, size: 15),
                    label: const Text('AI Summary'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF534AB7),
                      side: const BorderSide(color: Color(0xFF534AB7)),
                      minimumSize: const Size(0, 38),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ── Create exam dialog ─────────────────────────────────────────────────────
  void _showCreateExamDialog() {
    final titleController    = TextEditingController();
    final durationController = TextEditingController(text: '90');
    final topicController    = TextEditingController();
    DateTime? selectedDate;
    String selectedCourse    = 'B.Tech Computer Science';
    final draftQuestions = <_DraftQuestion>[_DraftQuestion()];
    final picker = ImagePicker();
    bool isCreating = false;
    bool isGenerating = false;
    String selectedDifficulty = 'medium';
    int mcqCount  = 5;
    int textCount = 2;

    final courses = [
      'B.Tech Computer Science',
      'B.Tech Information Technology',
      'B.Tech Electronics',
      'B.Tech Mechanical',
      'B.Tech Civil',
    ];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          void showSheetError(String message) {
            ScaffoldMessenger.of(ctx).showSnackBar(
              SnackBar(
                content: Text(message),
                backgroundColor: const Color(0xFFA32D2D),
              ),
            );
          }

          return Padding(
            padding: EdgeInsets.only(
              left: 24,
              right: 24,
              top: 24,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
            ),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Create New Exam',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF1a1a2e),
                    ),
                  ),
                  const SizedBox(height: 20),
                  TextField(
                    controller: titleController,
                    decoration: const InputDecoration(
                      labelText: 'Exam Title',
                      hintText: 'e.g. Data Structures Finals',
                      prefixIcon: Icon(Icons.title),
                    ),
                  ),
                  const SizedBox(height: 14),
                  DropdownButtonFormField<String>(
                    initialValue: selectedCourse,
                    decoration: const InputDecoration(
                      labelText: 'Course',
                      prefixIcon: Icon(Icons.book_outlined),
                    ),
                    items: courses
                        .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                        .toList(),
                    onChanged: (v) => setSheetState(() => selectedCourse = v!),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: durationController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Duration (minutes)',
                      prefixIcon: Icon(Icons.timer_outlined),
                    ),
                  ),
                  const SizedBox(height: 14),
                  OutlinedButton.icon(
                    onPressed: () async {
                      final picked = await showDatePicker(
                        context: ctx,
                        initialDate: DateTime.now().add(const Duration(days: 1)),
                        firstDate: DateTime.now(),
                        lastDate: DateTime.now().add(const Duration(days: 365)),
                      );
                      if (picked == null) return;
                      final time = await showTimePicker(
                        context: ctx,
                        initialTime: TimeOfDay.now(),
                      );
                      if (time == null) return;

                      setSheetState(() {
                        selectedDate = DateTime(
                          picked.year,
                          picked.month,
                          picked.day,
                          time.hour,
                          time.minute,
                        );
                      });
                    },
                    icon: const Icon(Icons.calendar_today_outlined),
                    label: Text(
                      selectedDate != null
                          ? _formatDate(selectedDate!)
                          : 'Select Date & Time',
                    ),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(double.infinity, 48),
                      side: const BorderSide(color: Color(0xFF534AB7)),
                      foregroundColor: const Color(0xFF534AB7),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  // ── AI Question Generator ───────────────────────────────
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEEEDFE),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Row(
                          children: [
                            Icon(Icons.auto_awesome_rounded,
                                size: 16, color: Color(0xFF534AB7)),
                            SizedBox(width: 6),
                            Text(
                              'AI Question Generator',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF534AB7),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        // Syllabus text area
                        Stack(
                          children: [
                            TextField(
                              controller: topicController,
                              maxLines: 6,
                              minLines: 4,
                              keyboardType: TextInputType.multiline,
                              textInputAction: TextInputAction.newline,
                              enableInteractiveSelection: true,
                              decoration: const InputDecoration(
                                labelText: 'Syllabus / Topics',
                                hintText:
                                    'Describe the topics here…\ne.g. Binary Trees, AVL Trees, Red-Black Trees, Heaps',
                                isDense: true,
                                alignLabelWithHint: true,
                                contentPadding: EdgeInsets.fromLTRB(
                                    12, 10, 48, 10),
                              ),
                            ),
                            Positioned(
                              top: 4,
                              right: 4,
                              child: Tooltip(
                                message: 'Paste from clipboard',
                                child: IconButton(
                                  icon: const Icon(Icons.content_paste_rounded,
                                      size: 18, color: Color(0xFF534AB7)),
                                  onPressed: () async {
                                    final data = await Clipboard.getData(
                                        Clipboard.kTextPlain);
                                    if (data?.text != null &&
                                        data!.text!.isNotEmpty) {
                                      topicController.text = data.text!;
                                      topicController.selection =
                                          TextSelection.collapsed(
                                              offset:
                                                  topicController.text.length);
                                    }
                                  },
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        // Question counts row
                        Row(
                          children: [
                            Expanded(
                              child: _CountStepper(
                                label: 'MCQ',
                                value: mcqCount,
                                onChanged: (v) =>
                                    setSheetState(() => mcqCount = v),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _CountStepper(
                                label: 'Text',
                                value: textCount,
                                onChanged: (v) =>
                                    setSheetState(() => textCount = v),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        // Difficulty selector
                        Row(
                          children: [
                            const Text(
                              'Difficulty:',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: Color(0xFF534AB7),
                                  fontWeight: FontWeight.w500),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Row(
                                children: [
                                  for (final d in ['easy', 'medium', 'hard'])
                                    Expanded(
                                      child: GestureDetector(
                                        onTap: () => setSheetState(
                                            () => selectedDifficulty = d),
                                        child: Container(
                                          margin: EdgeInsets.only(
                                              right: d == 'hard' ? 0 : 6),
                                          padding: const EdgeInsets.symmetric(
                                              vertical: 6),
                                          decoration: BoxDecoration(
                                            color: selectedDifficulty == d
                                                ? const Color(0xFF534AB7)
                                                : Colors.white,
                                            borderRadius:
                                                BorderRadius.circular(8),
                                            border: Border.all(
                                                color:
                                                    const Color(0xFF534AB7)),
                                          ),
                                          child: Text(
                                            d[0].toUpperCase() +
                                                d.substring(1),
                                            textAlign: TextAlign.center,
                                            style: TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.w600,
                                              color: selectedDifficulty == d
                                                  ? Colors.white
                                                  : const Color(0xFF534AB7),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        // Generate button
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            icon: isGenerating
                                ? const SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white),
                                  )
                                : const Icon(Icons.auto_awesome_rounded,
                                    size: 16),
                            label: Text(isGenerating
                                ? 'Generating…'
                                : 'Generate Questions'),
                            onPressed: isGenerating
                                ? null
                                : () async {
                                    final topic =
                                        topicController.text.trim();
                                    if (topic.isEmpty) {
                                      showSheetError(
                                          'Paste a syllabus or describe topics first.');
                                      return;
                                    }
                                    setSheetState(() => isGenerating = true);
                                    try {
                                      final generated =
                                          await AiService.generateQuestions(
                                        topic: topic,
                                        mcqCount: mcqCount,
                                        textCount: textCount,
                                        difficulty: selectedDifficulty,
                                      );
                                      for (final q in draftQuestions) {
                                        q.dispose();
                                      }
                                      draftQuestions.clear();
                                      for (final qData in generated) {
                                        final dq = _DraftQuestion();
                                        dq.type =
                                            qData['type'] as String? ??
                                                'mcq';
                                        dq.questionController.text =
                                            qData['q'] as String? ?? '';
                                        dq.marksController.text =
                                            '${qData['marks'] ?? 1}';
                                        if (dq.type == 'mcq') {
                                          final opts = List<String>.from(
                                              qData['options'] as List? ??
                                                  []);
                                          for (int i = 0;
                                              i < opts.length && i < 4;
                                              i++) {
                                            dq.optionControllers[i].text =
                                                opts[i];
                                          }
                                          dq.correctOption =
                                              qData['correct_option'] is int
                                                  ? qData['correct_option']
                                                      as int
                                                  : null;
                                        } else {
                                          dq.modelAnswerController.text =
                                              qData['model_answer']
                                                      as String? ??
                                                  '';
                                        }
                                        draftQuestions.add(dq);
                                      }
                                    } catch (e) {
                                      showSheetError(
                                          'Generation failed: $e');
                                    }
                                    setSheetState(() => isGenerating = false);
                                  },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF534AB7),
                              foregroundColor: Colors.white,
                              minimumSize: const Size(0, 44),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10)),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    'Questions',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF1a1a2e),
                    ),
                  ),
                  const SizedBox(height: 10),
                  ...draftQuestions.asMap().entries.map((entry) {
                    final i = entry.key;
                    final q = entry.value;
                    return Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFFE8E8E8)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                'Question ${i + 1}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF1a1a2e),
                                ),
                              ),
                              const Spacer(),
                              if (draftQuestions.length > 1)
                                IconButton(
                                  onPressed: () {
                                    setSheetState(() {
                                      q.dispose();
                                      draftQuestions.removeAt(i);
                                    });
                                  },
                                  icon: const Icon(
                                    Icons.delete_outline,
                                    color: Color(0xFFA32D2D),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: DropdownButtonFormField<String>(
                                  initialValue: q.type,
                                  decoration: const InputDecoration(
                                    labelText: 'Question Type',
                                  ),
                                  items: const [
                                    DropdownMenuItem(
                                      value: 'mcq',
                                      child: Text('MCQ'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'text',
                                      child: Text('Text Answer'),
                                    ),
                                  ],
                                  onChanged: (v) {
                                    if (v == null) return;
                                    setSheetState(() => q.type = v);
                                  },
                                ),
                              ),
                              const SizedBox(width: 10),
                              SizedBox(
                                width: 110,
                                child: TextField(
                                  controller: q.marksController,
                                  keyboardType: TextInputType.number,
                                  decoration: const InputDecoration(
                                    labelText: 'Marks',
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          TextField(
                            controller: q.questionController,
                            minLines: 2,
                            maxLines: 4,
                            decoration: const InputDecoration(
                              labelText: 'Question',
                              hintText: 'Type question text here',
                            ),
                          ),
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              OutlinedButton.icon(
                                onPressed: () async {
                                  final pickedFile = await picker.pickImage(
                                    source: ImageSource.gallery,
                                    imageQuality: 75,
                                    maxWidth: 1400,
                                  );
                                  if (pickedFile == null) return;
                                  final bytes = await pickedFile.readAsBytes();
                                  final mime = _mimeTypeFromPath(pickedFile.path);
                                  setSheetState(() {
                                    q.imageDataUrl =
                                        'data:$mime;base64,${base64Encode(bytes)}';
                                  });
                                },
                                icon: const Icon(Icons.image_outlined, size: 16),
                                label: Text(
                                  q.imageDataUrl == null ? 'Add Diagram' : 'Change Diagram',
                                ),
                              ),
                              if (q.imageDataUrl != null)
                                TextButton.icon(
                                  onPressed: () => setSheetState(() => q.imageDataUrl = null),
                                  icon: const Icon(Icons.close, size: 16),
                                  label: const Text('Remove'),
                                ),
                            ],
                          ),
                          if (q.imageDataUrl != null) ...[
                            const SizedBox(height: 10),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: Image.network(
                                q.imageDataUrl!,
                                height: 120,
                                width: double.infinity,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => const SizedBox(),
                              ),
                            ),
                          ],
                          if (q.type == 'mcq') ...[
                            const SizedBox(height: 10),
                            ...q.optionControllers.asMap().entries.map((optEntry) {
                              final optIdx = optEntry.key;
                              final controller = optEntry.value;
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: TextField(
                                  controller: controller,
                                  decoration: InputDecoration(
                                    labelText:
                                        'Option ${String.fromCharCode(65 + optIdx)}',
                                  ),
                                ),
                              );
                            }),
                            const SizedBox(height: 8),
                            const Text(
                              'Correct answer:',
                              style: TextStyle(fontSize: 12, color: Colors.grey),
                            ),
                            const SizedBox(height: 6),
                            Wrap(
                              spacing: 8,
                              children: List.generate(4, (optIdx) {
                                final label = String.fromCharCode(65 + optIdx);
                                return ChoiceChip(
                                  label: Text(label),
                                  selected: q.correctOption == optIdx,
                                  selectedColor: const Color(0xFF534AB7),
                                  labelStyle: TextStyle(
                                    color: q.correctOption == optIdx
                                        ? Colors.white
                                        : Colors.black87,
                                    fontWeight: FontWeight.w600,
                                  ),
                                  onSelected: (_) => setSheetState(
                                      () => q.correctOption = optIdx),
                                );
                              }),
                            ),
                          ],
                          if (q.type == 'text') ...[
                            const SizedBox(height: 10),
                            TextField(
                              controller: q.modelAnswerController,
                              minLines: 2,
                              maxLines: 4,
                              decoration: const InputDecoration(
                                labelText: 'Model Answer',
                                hintText: 'Expected answer for AI grading',
                              ),
                            ),
                          ],
                        ],
                      ),
                    );
                  }),
                  OutlinedButton.icon(
                    onPressed: () {
                      setSheetState(() {
                        draftQuestions.add(_DraftQuestion());
                      });
                    },
                    icon: const Icon(Icons.add),
                    label: const Text('Add Question'),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: isCreating
                        ? null
                        : () async {
                            final title = titleController.text.trim();
                            if (title.isEmpty) {
                              showSheetError('Please enter exam title.');
                              return;
                            }
                            if (selectedDate == null) {
                              showSheetError('Please select exam date and time.');
                              return;
                            }

                            final duration = int.tryParse(durationController.text) ?? 90;
                            final normalizedQuestions = <Map<String, dynamic>>[];
                            for (int i = 0; i < draftQuestions.length; i++) {
                              final q = draftQuestions[i];
                              final text = q.questionController.text.trim();
                              final marks = int.tryParse(q.marksController.text.trim()) ?? 0;
                              if (text.isEmpty) {
                                showSheetError('Question ${i + 1} text is required.');
                                return;
                              }
                              if (marks <= 0) {
                                showSheetError('Question ${i + 1} marks must be greater than 0.');
                                return;
                              }

                              if (q.type == 'mcq') {
                                final options = q.optionControllers
                                    .map((c) => c.text.trim())
                                    .where((v) => v.isNotEmpty)
                                    .toList();
                                if (options.length < 2) {
                                  showSheetError(
                                    'Question ${i + 1}: add at least 2 options for MCQ.',
                                  );
                                  return;
                                }
                                normalizedQuestions.add({
                                  'type': 'mcq',
                                  'q': text,
                                  'options': options,
                                  'marks': marks,
                                  'image_data_url': q.imageDataUrl,
                                  'correct_option': q.correctOption,
                                });
                              } else {
                                normalizedQuestions.add({
                                  'type': 'text',
                                  'q': text,
                                  'options': <String>[],
                                  'marks': marks,
                                  'image_data_url': q.imageDataUrl,
                                  'model_answer':
                                      q.modelAnswerController.text.trim(),
                                });
                              }
                            }

                            setSheetState(() => isCreating = true);
                            await _createExam(
                              title: title,
                              course: selectedCourse,
                              duration: duration,
                              startTime: selectedDate!,
                              questions: normalizedQuestions,
                            );
                            if (ctx.mounted) Navigator.pop(ctx);
                          },
                    child: isCreating
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Text('Create Exam'),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    ).whenComplete(() {
      titleController.dispose();
      durationController.dispose();
      topicController.dispose();
      for (final q in draftQuestions) {
        q.dispose();
      }
    });
  }

  Future<void> _createExam({
    required String title,
    required String course,
    required int duration,
    required DateTime startTime,
    required List<Map<String, dynamic>> questions,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    final uid = user?.uid;
    if (uid == null) {
      _showError('Session expired. Please log in again.');
      return;
    }
    final endTime = startTime.add(Duration(minutes: duration));
    final examId  = 'exam_${DateTime.now().millisecondsSinceEpoch}';

    // Get all students for this teacher's college
    final studentsSnap = await _db
        .collection('students')
        .where('college', isEqualTo: _teacherData?['college'] ?? '')
        .get();
    final studentIds =
    studentsSnap.docs.map((d) => d.id).toList();
    final totalMarks = questions.fold<int>(
      0,
      (total, q) => total + ((q['marks'] as int?) ?? 0),
    );

    await _db.collection('exams').doc(examId).set({
      'exam_id':              examId,
      'title':                title,
      'teacher_id':           uid,
      'teacher_email':        _teacherData?['email'] ?? user?.email ?? '',
      'course':               course,
      'start_time':           startTime.toIso8601String(),
      'end_time':             endTime.toIso8601String(),
      'duration_mins':        duration,
      'registered_students':  studentIds,
      'status':               'upcoming',
      'report_generated':     false,
      'questions':            questions,
      'total_marks':          totalMarks,
    });

    await _loadData();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Exam created successfully!'),
          backgroundColor: Color(0xFF1D9E75),
        ),
      );
    }
  }

  Widget _emptyState(IconData icon, String title, String subtitle) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 52, color: Colors.grey[300]),
            const SizedBox(height: 12),
            Text(
              title,
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                color: Colors.grey,
                fontSize: 15,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              style: const TextStyle(fontSize: 13, color: Colors.grey),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  String _formatDate(DateTime dt) {
    const months = [
      'Jan','Feb','Mar','Apr','May','Jun',
      'Jul','Aug','Sep','Oct','Nov','Dec'
    ];
    return '${dt.day} ${months[dt.month - 1]}, ${dt.hour}:${dt.minute.toString().padLeft(2, '0')}';
  }

  String _mimeTypeFromPath(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.gif')) return 'image/gif';
    return 'image/jpeg';
  }
}

class _DraftQuestion {
  String type;
  String? imageDataUrl;
  int? correctOption;
  final TextEditingController questionController;
  final TextEditingController marksController;
  final TextEditingController modelAnswerController;
  final List<TextEditingController> optionControllers;

  _DraftQuestion()
      : type = 'mcq',
        correctOption = null,
        questionController = TextEditingController(),
        marksController = TextEditingController(text: '1'),
        modelAnswerController = TextEditingController(),
        optionControllers = List.generate(4, (_) => TextEditingController());

  void dispose() {
    questionController.dispose();
    marksController.dispose();
    modelAnswerController.dispose();
    for (final c in optionControllers) {
      c.dispose();
    }
  }
}

class _CountStepper extends StatelessWidget {
  const _CountStepper({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF534AB7).withOpacity(0.4)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            '$label count',
            style: const TextStyle(
                fontSize: 12,
                color: Color(0xFF534AB7),
                fontWeight: FontWeight.w500),
          ),
          Row(
            children: [
              GestureDetector(
                onTap: value > 0
                    ? () => onChanged(value - 1)
                    : null,
                child: Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: value > 0
                        ? const Color(0xFF534AB7)
                        : Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Icon(Icons.remove,
                      size: 14, color: Colors.white),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Text(
                  '$value',
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w700),
                ),
              ),
              GestureDetector(
                onTap: value < 20
                    ? () => onChanged(value + 1)
                    : null,
                child: Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: value < 20
                        ? const Color(0xFF534AB7)
                        : Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Icon(Icons.add,
                      size: 14, color: Colors.white),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
