import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
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
            Text('Generating report...'),
          ],
        ),
      ),
    );

    final result = await ApiService.generateReport(examId: examId);
    if (!mounted) return;
    Navigator.pop(context); // close dialog

    if (result['success'] == true) {
      // Grade submitted answers with AI
      await GradingService.gradeExam(examId);

      // Send email
      final teacherEmail = _teacherData?['email'] ?? '';
      if (teacherEmail.isNotEmpty) {
        await ApiService.sendReportEmail(
          examId:       examId,
          teacherEmail: teacherEmail,
        );
      }

      // Navigate to report screen
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ReportScreen(
            examId:    examId,
            examTitle: exam['title'] ?? '',
          ),
        ),
      );
    } else {
      _showError(result['error'] ?? 'Failed to generate report');
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: const Color(0xFFA32D2D),
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

      final studentAnswers = answerDocs.docs.map((doc) {
        final d = doc.data();
        return {
          'student_id': d['student_id'] ?? doc.id,
          'answers': d['answers'] ?? {},
        };
      }).toList();

      if (!mounted) return;
      Navigator.pop(context); // close loading dialog

      if (studentAnswers.length < 2) {
        _showError('Need at least 2 student submissions to check for plagiarism.');
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
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => _checkPlagiarism(exam),
                icon: const Icon(Icons.content_copy_rounded, size: 16),
                label: const Text('Check Plagiarism'),
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
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: topicController,
                                decoration: const InputDecoration(
                                  labelText: 'Topic / Syllabus',
                                  hintText: 'e.g. Binary Trees',
                                  isDense: true,
                                  contentPadding: EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 10),
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            ElevatedButton(
                              onPressed: isGenerating
                                  ? null
                                  : () async {
                                      final topic = topicController.text.trim();
                                      if (topic.isEmpty) {
                                        showSheetError(
                                            'Enter a topic to generate questions.');
                                        return;
                                      }
                                      setSheetState(() => isGenerating = true);
                                      try {
                                        final generated =
                                            await AiService.generateQuestions(
                                          topic: topic,
                                          mcqCount: 5,
                                          textCount: 2,
                                        );
                                        for (final q in draftQuestions) {
                                          q.dispose();
                                        }
                                        draftQuestions.clear();
                                        for (final qData in generated) {
                                          final dq = _DraftQuestion();
                                          dq.type =
                                              qData['type'] as String? ?? 'mcq';
                                          dq.questionController.text =
                                              qData['q'] as String? ?? '';
                                          dq.marksController.text =
                                              '${qData['marks'] ?? 1}';
                                          if (dq.type == 'mcq') {
                                            final opts = List<String>.from(
                                                qData['options'] as List? ?? []);
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
                                        showSheetError('Generation failed: $e');
                                      }
                                      setSheetState(() => isGenerating = false);
                                    },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF534AB7),
                                foregroundColor: Colors.white,
                                minimumSize: const Size(0, 44),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 16),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10)),
                              ),
                              child: isGenerating
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: Colors.white),
                                    )
                                  : const Text('Generate'),
                            ),
                          ],
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
