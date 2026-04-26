import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:csv/csv.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'dart:io';

class ReportScreen extends StatefulWidget {
  final String examId;
  final String examTitle;
  final bool   isLive;

  const ReportScreen({
    super.key,
    required this.examId,
    required this.examTitle,
    this.isLive = false,
  });

  @override
  State<ReportScreen> createState() => _ReportScreenState();
}

class _ReportScreenState extends State<ReportScreen>
    with SingleTickerProviderStateMixin {
  final _db = FirebaseFirestore.instance;
  late TabController _tabController;

  Map<String, dynamic>? _classReport;
  Map<String, dynamic>? _flaggedReport;
  List<Map<String, dynamic>> _studentReports = [];
  bool _isLoading = true;

  // Selected student for detail view
  Map<String, dynamic>? _selectedStudent;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _loadReports();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadReports() async {
    setState(() => _isLoading = true);
    try {
      // Load class-wide report
      final classDoc = await _db
          .collection('reports')
          .doc('class_${widget.examId}')
          .get();
      if (classDoc.exists) {
        _classReport = classDoc.data();
      }

      // Load flagged summary
      final flaggedDoc = await _db
          .collection('reports')
          .doc('flagged_${widget.examId}')
          .get();
      if (flaggedDoc.exists) {
        _flaggedReport = flaggedDoc.data();
      }

      // Load per-student reports
      final reportsSnap = await _db
          .collection('reports')
          .where('exam_id', isEqualTo: widget.examId)
          .where('report_type', isEqualTo: 'per_student')
          .get();

      _studentReports = reportsSnap.docs
          .map((d) => {'id': d.id, ...d.data()})
          .toList();

      // Sort by fraud score descending
      _studentReports.sort((a, b) =>
          (b['final_fraud_score'] ?? 0)
              .compareTo(a['final_fraud_score'] ?? 0));

    } catch (e) {
      debugPrint('Error loading reports: $e');
    }

    // If live — also load events directly from exam_events
    if (widget.isLive) await _loadLiveEvents();

    if (mounted) setState(() => _isLoading = false);
  }

  Future<void> _loadLiveEvents() async {
    try {
      final eventsSnap = await _db
          .collection('exam_events')
          .where('exam_id', isEqualTo: widget.examId)
          .get();

      // Group by student
      final Map<String, List<Map<String, dynamic>>> byStudent = {};
      for (final doc in eventsSnap.docs) {
        final data      = doc.data();
        final studentId = data['student_id'] ?? '';
        byStudent.putIfAbsent(studentId, () => []).add(data);
      }

      // Build live student summaries
      final liveSummaries = <Map<String, dynamic>>[];
      for (final entry in byStudent.entries) {
        final events     = entry.value;
        final scores     = events.map((e) => (e['fraud_score'] ?? 0) as int).toList();
        final maxScore   = scores.isNotEmpty ? scores.reduce((a, b) => a > b ? a : b) : 0;
        final flagCount  = events.where((e) =>
            ['soft', 'hard', 'critical'].contains(e['flag_level'])).length;

        liveSummaries.add({
          'student_id':        entry.key,
          'student_name':      events.first['student_name'] ?? entry.key,
          'final_fraud_score': maxScore,
          'flag_count':        flagCount,
          'event_timeline':    events..sort((a, b) =>
              (a['timestamp'] ?? '').compareTo(b['timestamp'] ?? '')),
          'recommendation':    maxScore > 75 ? 'escalate'
              : maxScore > 55 ? 'investigate'
              : maxScore > 30 ? 'monitor'
              : 'clear',
        });
      }

      liveSummaries.sort((a, b) =>
          (b['final_fraud_score'] ?? 0).compareTo(a['final_fraud_score'] ?? 0));

      if (_studentReports.isEmpty) {
        _studentReports = liveSummaries;
      }
    } catch (e) {
      debugPrint('Live events load error: $e');
    }
  }

  // ── Export CSV ─────────────────────────────────────────────────────────────
  Future<void> _exportCSV() async {
    try {
      // Load all score docs for this exam
      final scoresSnap = await _db
          .collection('exam_scores')
          .where('exam_id', isEqualTo: widget.examId)
          .get();
      final scoresByStudent = <String, Map<String, dynamic>>{
        for (final d in scoresSnap.docs) d.data()['student_id'] as String: d.data(),
      };

      final rows = <List<dynamic>>[
        ['Student Name', 'Fraud Score', 'Flag Count', 'Recommendation',
          'Face Mismatch', 'Behavioral Drift', 'Deepfake',
          'Score Earned', 'Score Total', 'Percentage'],
      ];

      for (final s in _studentReports) {
        final shap      = s['shap_values'] as Map? ?? {};
        final sid       = s['student_id'] as String? ?? '';
        final scoreData = scoresByStudent[sid];
        rows.add([
          s['student_name'] ?? sid,
          s['final_fraud_score'] ?? 0,
          s['flag_count'] ?? 0,
          s['recommendation'] ?? '',
          shap['face_mismatch'] ?? 0,
          shap['behavioral_drift'] ?? 0,
          shap['deepfake'] ?? 0,
          scoreData?['total_earned'] ?? '',
          scoreData?['total_marks'] ?? '',
          scoreData != null
              ? '${(scoreData['percentage'] as num?)?.toStringAsFixed(1)}%'
              : '',
        ]);
      }

      final csv      = const ListToCsvConverter().convert(rows);
      final dir      = await getTemporaryDirectory();
      final file     = File('${dir.path}/examiq_report_${widget.examId}.csv');
      await file.writeAsString(csv);

      await Share.shareXFiles(
        [XFile(file.path)],
        subject: 'ExamIQ Report — ${widget.examTitle}',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export failed: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8F7FF),
      appBar: AppBar(
        title: Text(
          widget.isLive ? 'Live Monitor' : 'Exam Report',
          style: const TextStyle(fontSize: 16),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadReports,
          ),
          if (!widget.isLive)
            IconButton(
              icon: const Icon(Icons.download_rounded),
              onPressed: _exportCSV,
              tooltip: 'Export CSV',
            ),
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: Colors.white,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white60,
          tabs: const [
            Tab(text: 'Overview'),
            Tab(text: 'All Students'),
            Tab(text: 'Flagged'),
          ],
        ),
      ),
      body: _isLoading
          ? const Center(
        child: CircularProgressIndicator(color: Color(0xFF534AB7)),
      )
          : TabBarView(
        controller: _tabController,
        children: [
          _buildOverviewTab(),
          _buildAllStudentsTab(),
          _buildFlaggedTab(),
        ],
      ),
    );
  }

  // ── Overview tab ───────────────────────────────────────────────────────────
  Widget _buildOverviewTab() {
    if (_classReport == null && _studentReports.isEmpty) {
      return _emptyState(
        Icons.bar_chart_rounded,
        'No report data yet',
        widget.isLive
            ? 'Data will appear as students take the exam.'
            : 'Generate the report from the teacher dashboard.',
      );
    }

    final total    = _classReport?['total_students'] ?? _studentReports.length;
    final clean    = _classReport?['clean_count'] ??
        _studentReports.where((s) => (s['final_fraud_score'] ?? 0) <= 30).length;
    final flagged  = _classReport?['flagged_count'] ??
        _studentReports.where((s) {
          final score = s['final_fraud_score'] ?? 0;
          return score > 30 && score <= 75;
        }).length;
    final critical = _classReport?['critical_count'] ??
        _studentReports.where((s) => (s['final_fraud_score'] ?? 0) > 75).length;
    final avgScore = _classReport?['avg_fraud_score'] ??
        (_studentReports.isNotEmpty
            ? _studentReports
            .map((s) => (s['final_fraud_score'] ?? 0) as int)
            .reduce((a, b) => a + b) /
            _studentReports.length
            : 0.0);

    return RefreshIndicator(
      onRefresh: _loadReports,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [

            // Exam title
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF534AB7), Color(0xFF7F77DD)],
                ),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.examTitle,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    widget.isLive ? 'Live monitoring' : 'Post-exam report',
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.8),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // Stats grid
            Row(
              children: [
                _overviewStat('$total', 'Total',
                    const Color(0xFF534AB7), const Color(0xFFEEEDFE)),
                const SizedBox(width: 10),
                _overviewStat('$clean', 'Clean',
                    const Color(0xFF1D9E75), const Color(0xFFE1F5EE)),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                _overviewStat('$flagged', 'Flagged',
                    const Color(0xFFBA7517), const Color(0xFFFAEEDA)),
                const SizedBox(width: 10),
                _overviewStat('$critical', 'Critical',
                    const Color(0xFFA32D2D), const Color(0xFFFCEBEB)),
              ],
            ),

            const SizedBox(height: 16),

            // Integrity rate bar
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFE8E8E8)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Exam integrity rate',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                          color: Color(0xFF1a1a2e),
                        ),
                      ),
                      Text(
                        total > 0
                            ? '${(clean / total * 100).toStringAsFixed(1)}%'
                            : '0%',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF1D9E75),
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: total > 0 ? clean / total : 0,
                      backgroundColor: const Color(0xFFFCEBEB),
                      valueColor: const AlwaysStoppedAnimation<Color>(
                          Color(0xFF1D9E75)),
                      minHeight: 10,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Average fraud score: ${avgScore.toStringAsFixed(1)}',
                    style: const TextStyle(
                        color: Colors.grey, fontSize: 12),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // Top flagged students preview
            if (critical > 0 || flagged > 0) ...[
              const Text(
                'Needs attention',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF1a1a2e),
                ),
              ),
              const SizedBox(height: 10),
              ..._studentReports
                  .where((s) => (s['final_fraud_score'] ?? 0) > 30)
                  .take(3)
                  .map((s) => _compactStudentCard(s)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _overviewStat(
      String value, String label, Color color, Color bgColor) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Text(
              value,
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
            const SizedBox(width: 10),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                color: color.withOpacity(0.8),
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── All students tab ───────────────────────────────────────────────────────
  Widget _buildAllStudentsTab() {
    if (_studentReports.isEmpty) {
      return _emptyState(
        Icons.people_outline,
        'No student data',
        'Student reports will appear here after the exam.',
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _studentReports.length,
      itemBuilder: (_, i) {
        final student = _studentReports[i];
        return _studentCard(student);
      },
    );
  }

  Widget _studentCard(Map<String, dynamic> student) {
    final name       = student['student_name'] ?? student['student_id'] ?? 'Unknown';
    final score      = student['final_fraud_score'] ?? 0;
    final flagCount  = student['flag_count'] ?? 0;
    final rec        = student['recommendation'] ?? 'clear';

    Color scoreColor;
    Color scoreBg;
    if (score <= 30) {
      scoreColor = const Color(0xFF1D9E75);
      scoreBg    = const Color(0xFFE1F5EE);
    } else if (score <= 55) {
      scoreColor = const Color(0xFFBA7517);
      scoreBg    = const Color(0xFFFAEEDA);
    } else if (score <= 75) {
      scoreColor = const Color(0xFFD85A30);
      scoreBg    = const Color(0xFFFAECE7);
    } else {
      scoreColor = const Color(0xFFA32D2D);
      scoreBg    = const Color(0xFFFCEBEB);
    }

    return GestureDetector(
      onTap: () => _showStudentDetail(student),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFE8E8E8)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.03),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          children: [
            // Avatar
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: scoreBg,
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Text(
                  name.isNotEmpty ? name[0].toUpperCase() : '?',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: scoreColor,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),

            // Name + flags
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF1a1a2e),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    flagCount > 0
                        ? '$flagCount flag${flagCount > 1 ? 's' : ''} raised'
                        : 'No flags raised',
                    style: TextStyle(
                      fontSize: 11,
                      color: flagCount > 0 ? scoreColor : Colors.grey,
                    ),
                  ),
                ],
              ),
            ),

            // Score badge
            Container(
              padding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: scoreBg,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '$score',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: scoreColor,
                ),
              ),
            ),

            const SizedBox(width: 8),
            const Icon(Icons.chevron_right, color: Colors.grey, size: 18),
          ],
        ),
      ),
    );
  }

  Widget _compactStudentCard(Map<String, dynamic> student) {
    final name  = student['student_name'] ?? student['student_id'] ?? 'Unknown';
    final score = student['final_fraud_score'] ?? 0;
    final rec   = student['recommendation'] ?? 'monitor';

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: score > 75
            ? const Color(0xFFFCEBEB)
            : const Color(0xFFFAEEDA),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: score > 75
              ? const Color(0xFFF09595)
              : const Color(0xFFFAC775),
        ),
      ),
      child: Row(
        children: [
          Icon(
            score > 75
                ? Icons.error_rounded
                : Icons.warning_amber_rounded,
            color: score > 75
                ? const Color(0xFFA32D2D)
                : const Color(0xFFBA7517),
            size: 18,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              name,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: score > 75
                    ? const Color(0xFF791F1F)
                    : const Color(0xFF633806),
              ),
            ),
          ),
          Text(
            rec.toUpperCase(),
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              color: score > 75
                  ? const Color(0xFFA32D2D)
                  : const Color(0xFFBA7517),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '$score',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: score > 75
                  ? const Color(0xFFA32D2D)
                  : const Color(0xFFBA7517),
            ),
          ),
        ],
      ),
    );
  }

  // ── Flagged tab ────────────────────────────────────────────────────────────
  Widget _buildFlaggedTab() {
    final flagged = _studentReports
        .where((s) => (s['final_fraud_score'] ?? 0) > 30)
        .toList();

    if (flagged.isEmpty) {
      return _emptyState(
        Icons.check_circle_outline_rounded,
        'No flagged students',
        'All students passed integrity checks.',
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: flagged.length,
      itemBuilder: (_, i) => _flaggedCard(flagged[i]),
    );
  }

  Widget _flaggedCard(Map<String, dynamic> student) {
    final name      = student['student_name'] ?? 'Unknown';
    final score     = student['final_fraud_score'] ?? 0;
    final flagCount = student['flag_count'] ?? 0;
    final rec       = student['recommendation'] ?? 'monitor';
    final shap      = student['shap_values'] as Map? ?? {};

    // Find primary signal
    String primarySignal = 'Unknown';
    if (shap.isNotEmpty) {
      final topKey = shap.entries
          .reduce((a, b) => (a.value ?? 0) > (b.value ?? 0) ? a : b)
          .key;
      primarySignal = topKey.toString().replaceAll('_', ' ');
    }

    final isCritical = score > 75;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isCritical
              ? const Color(0xFFF09595)
              : const Color(0xFFFAC775),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: (isCritical
                ? const Color(0xFFA32D2D)
                : const Color(0xFFBA7517))
                .withOpacity(0.08),
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
            // Header row
            Row(
              children: [
                Expanded(
                  child: Text(
                    name,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF1a1a2e),
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: isCritical
                        ? const Color(0xFFFCEBEB)
                        : const Color(0xFFFAEEDA),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    'Score $score',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: isCritical
                          ? const Color(0xFFA32D2D)
                          : const Color(0xFFBA7517),
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 10),

            // Primary signal
            Row(
              children: [
                const Icon(Icons.flag_rounded,
                    size: 14, color: Colors.grey),
                const SizedBox(width: 5),
                Text(
                  'Primary signal: $primarySignal',
                  style: const TextStyle(
                      color: Colors.grey, fontSize: 12),
                ),
                const SizedBox(width: 14),
                const Icon(Icons.warning_outlined,
                    size: 14, color: Colors.grey),
                const SizedBox(width: 5),
                Text(
                  '$flagCount flags',
                  style: const TextStyle(
                      color: Colors.grey, fontSize: 12),
                ),
              ],
            ),

            const SizedBox(height: 12),

            // SHAP mini bars
            _shapMiniBar(
                'Face mismatch', shap['face_mismatch'] ?? 0,
                const Color(0xFFE24B4A)),
            _shapMiniBar(
                'Behavioral drift', shap['behavioral_drift'] ?? 0,
                const Color(0xFFD85A30)),
            _shapMiniBar(
                'Deepfake', shap['deepfake'] ?? 0,
                const Color(0xFF7F77DD)),

            const SizedBox(height: 12),

            // Actions
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _showStudentDetail(student),
                    icon: const Icon(Icons.timeline_rounded, size: 14),
                    label: const Text('Full Timeline'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF534AB7),
                      side: const BorderSide(
                          color: Color(0xFF534AB7)),
                      minimumSize: const Size(0, 36),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () =>
                        _escalateStudent(student),
                    icon: const Icon(
                        Icons.report_problem_rounded, size: 14),
                    label: const Text('Escalate'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: isCritical
                          ? const Color(0xFFA32D2D)
                          : const Color(0xFFBA7517),
                      foregroundColor: Colors.white,
                      minimumSize: const Size(0, 36),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8)),
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

  Widget _shapMiniBar(String label, dynamic value, Color color) {
    final val    = (value is double ? value : (value as num).toDouble());
    final pct    = (val / 40).clamp(0.0, 1.0); // max expected ~40 pts
    if (val <= 0) return const SizedBox();

    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Row(
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: const TextStyle(
                  fontSize: 11, color: Colors.grey),
            ),
          ),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: pct,
                backgroundColor: color.withOpacity(0.12),
                valueColor: AlwaysStoppedAnimation<Color>(color),
                minHeight: 5,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '+${val.toStringAsFixed(1)}',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  // ── Student detail sheet ───────────────────────────────────────────────────
  void _showStudentDetail(Map<String, dynamic> student) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.85,
        minChildSize:     0.5,
        maxChildSize:     0.95,
        expand:           false,
        builder: (_, scrollController) => _buildStudentDetailSheet(
          student,
          scrollController,
        ),
      ),
    );
  }

  Widget _buildStudentDetailSheet(
      Map<String, dynamic> student,
      ScrollController scrollController,
      ) {
    final name      = student['student_name'] ?? 'Unknown';
    final score     = student['final_fraud_score'] ?? 0;
    final flagCount = student['flag_count'] ?? 0;
    final rec       = student['recommendation'] ?? 'clear';
    final shap      = student['shap_values'] as Map? ?? {};
    final timeline  = List<Map<String, dynamic>>.from(
      (student['event_timeline'] as List? ?? [])
          .map((e) => Map<String, dynamic>.from(e)),
    );

    return Column(
      children: [
        // Handle bar
        Container(
          margin: const EdgeInsets.only(top: 10),
          width: 40,
          height: 4,
          decoration: BoxDecoration(
            color: Colors.grey[300],
            borderRadius: BorderRadius.circular(2),
          ),
        ),

        Expanded(
          child: ListView(
            controller: scrollController,
            padding: const EdgeInsets.all(20),
            children: [
              // Header
              Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: score > 75
                          ? const Color(0xFFFCEBEB)
                          : score > 30
                          ? const Color(0xFFFAEEDA)
                          : const Color(0xFFE1F5EE),
                      shape: BoxShape.circle,
                    ),
                    child: Center(
                      child: Text(
                        name[0].toUpperCase(),
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: score > 75
                              ? const Color(0xFFA32D2D)
                              : score > 30
                              ? const Color(0xFFBA7517)
                              : const Color(0xFF1D9E75),
                        ),
                      ),
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
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          '$flagCount flags · Recommendation: ${rec.toUpperCase()}',
                          style: const TextStyle(
                              fontSize: 12, color: Colors.grey),
                        ),
                      ],
                    ),
                  ),
                  Text(
                    '$score',
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      color: score > 75
                          ? const Color(0xFFA32D2D)
                          : score > 30
                          ? const Color(0xFFBA7517)
                          : const Color(0xFF1D9E75),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 20),

              // SHAP breakdown
              const Text(
                'Signal breakdown',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF1a1a2e),
                ),
              ),
              const SizedBox(height: 10),
              ...shap.entries.map((e) {
                final val = (e.value is double
                    ? e.value
                    : (e.value as num).toDouble()) as double;
                if (val <= 0) return const SizedBox();
                final label = e.key.toString().replaceAll('_', ' ');
                return _shapDetailBar(label, val);
              }),

              const SizedBox(height: 20),

              // Score breakdown
              const Text(
                'Score breakdown',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF1a1a2e),
                ),
              ),
              const SizedBox(height: 10),
              FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                future: _db
                    .collection('exam_scores')
                    .doc('${widget.examId}_${student['student_id'] ?? ''}')
                    .get(),
                builder: (context, snap) {
                  if (snap.connectionState == ConnectionState.waiting) {
                    return const Center(
                      child: Padding(
                        padding: EdgeInsets.all(8),
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Color(0xFF534AB7),
                        ),
                      ),
                    );
                  }
                  if (!snap.hasData || snap.data?.exists != true) {
                    return const Text(
                      'No score data — generate report to grade answers.',
                      style: TextStyle(color: Colors.grey, fontSize: 13),
                    );
                  }
                  final scoreDoc = snap.data!.data()!;
                  final totalEarned = scoreDoc['total_earned'] ?? 0;
                  final totalMarks  = scoreDoc['total_marks']  ?? 0;
                  final percentage  = (scoreDoc['percentage'] as num?)
                          ?.toStringAsFixed(1) ??
                      '0.0';
                  final qScores = List<Map<String, dynamic>>.from(
                    ((scoreDoc['question_scores'] as List?) ?? [])
                        .map((e) => Map<String, dynamic>.from(e as Map)),
                  );

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: const Color(0xFFEEEDFE),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          children: [
                            Text(
                              '$totalEarned / $totalMarks',
                              style: const TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF534AB7),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Text(
                              '$percentage%',
                              style: const TextStyle(
                                fontSize: 14,
                                color: Color(0xFF534AB7),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                      ...qScores.asMap().entries.map((entry) {
                        final idx    = entry.key;
                        final qs     = entry.value;
                        final earned = (qs['earned'] as num?)?.toInt() ?? 0;
                        final marks  = (qs['marks']  as num?)?.toInt() ?? 1;
                        final qType  = qs['type'] as String? ?? 'mcq';
                        final isCorrect = qs['is_correct'] as bool?;
                        final feedback  = qs['feedback'] as String?;

                        Color dotColor;
                        String statusText;
                        if (earned == marks) {
                          dotColor   = const Color(0xFF1D9E75);
                          statusText = 'Full marks';
                        } else if (earned > 0) {
                          dotColor   = const Color(0xFFBA7517);
                          statusText = 'Partial';
                        } else {
                          dotColor   = const Color(0xFFA32D2D);
                          statusText =
                              qType == 'mcq' ? 'Incorrect' : 'No marks';
                        }

                        return Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                                color: const Color(0xFFE8E8E8)),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                margin: const EdgeInsets.only(top: 2),
                                width: 10,
                                height: 10,
                                decoration: BoxDecoration(
                                  color: dotColor,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Q${idx + 1}  ·  '
                                      '${qType.toUpperCase()}',
                                      style: const TextStyle(
                                        fontSize: 11,
                                        color: Colors.grey,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                    if (qType == 'mcq' &&
                                        isCorrect != null) ...[
                                      const SizedBox(height: 2),
                                      Text(
                                        isCorrect
                                            ? 'Correct answer selected'
                                            : 'Wrong answer selected',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: isCorrect
                                              ? const Color(0xFF1D9E75)
                                              : const Color(0xFFA32D2D),
                                        ),
                                      ),
                                    ],
                                    if (feedback != null &&
                                        feedback.isNotEmpty) ...[
                                      const SizedBox(height: 2),
                                      Text(
                                        feedback,
                                        style: const TextStyle(
                                          fontSize: 12,
                                          color: Colors.black87,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                              Text(
                                '$earned/$marks',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                  color: dotColor,
                                ),
                              ),
                            ],
                          ),
                        );
                      }),
                    ],
                  );
                },
              ),

              const SizedBox(height: 20),

              // Event timeline
              const Text(
                'Event timeline',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF1a1a2e),
                ),
              ),
              const SizedBox(height: 12),

              if (timeline.isEmpty)
                const Text(
                  'No monitoring events recorded.',
                  style: TextStyle(color: Colors.grey, fontSize: 13),
                )
              else
                ...timeline.asMap().entries.map((entry) {
                  final i     = entry.key;
                  final event = entry.value;
                  return _timelineItem(event, isLast: i == timeline.length - 1);
                }),

              const SizedBox(height: 20),
            ],
          ),
        ),
      ],
    );
  }

  Widget _shapDetailBar(String label, double value) {
    final pct = (value / 40).clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                label.length > 1
                    ? label[0].toUpperCase() + label.substring(1)
                    : label,
                style: const TextStyle(
                    fontSize: 12, color: Color(0xFF444441)),
              ),
              Text(
                '+${value.toStringAsFixed(1)} pts',
                style: const TextStyle(
                  fontSize: 11,
                  color: Color(0xFF534AB7),
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: pct,
              backgroundColor: const Color(0xFFEEEDFE),
              valueColor: const AlwaysStoppedAnimation<Color>(
                  Color(0xFF534AB7)),
              minHeight: 7,
            ),
          ),
        ],
      ),
    );
  }

  Widget _timelineItem(Map<String, dynamic> event, {bool isLast = false}) {
    final flagLevel  = event['flag_level'] ?? 'clean';
    final timestamp  = event['timestamp'] ?? '';
    final faceScore  = event['face_match_score'] ?? 0.0;
    final drift      = event['behavioral_drift'] ?? 0.0;
    final fraudScore = event['fraud_score'] ?? 0;
    final eventType  = event['event_type'] ?? 'monitoring_check';

    Color dotColor;
    switch (flagLevel) {
      case 'critical': dotColor = const Color(0xFFA32D2D); break;
      case 'hard':     dotColor = const Color(0xFFD85A30); break;
      case 'soft':     dotColor = const Color(0xFFBA7517); break;
      default:         dotColor = const Color(0xFF1D9E75);
    }

    String timeLabel = '';
    final dt = DateTime.tryParse(timestamp);
    if (dt != null) {
      timeLabel =
      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    }

    String eventLabel;
    if (eventType == 'exam_entry') {
      eventLabel = 'Exam entry';
    } else if (eventType == 'tab_switched' || eventType == 'app_backgrounded') {
      eventLabel = 'Tab/app switch detected';
    } else if (eventType == 'clipboard_blocked') {
      eventLabel = 'Copy/paste blocked';
    } else {
      eventLabel = 'Check #${event['check_number'] ?? ''}';
    }

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Timeline line + dot
          SizedBox(
            width: 24,
            child: Column(
              children: [
                Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: dotColor,
                    shape: BoxShape.circle,
                    border: Border.all(
                        color: Colors.white, width: 2),
                    boxShadow: [
                      BoxShadow(
                        color: dotColor.withOpacity(0.3),
                        blurRadius: 4,
                      ),
                    ],
                  ),
                ),
                if (!isLast)
                  Expanded(
                    child: Container(
                      width: 1.5,
                      color: const Color(0xFFE8E8E8),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 10),

          // Event content
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: flagLevel == 'clean'
                      ? const Color(0xFFF8F7FF)
                      : flagLevel == 'critical'
                      ? const Color(0xFFFCEBEB)
                      : const Color(0xFFFAEEDA),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: flagLevel == 'clean'
                        ? const Color(0xFFE8E8E8)
                        : flagLevel == 'critical'
                        ? const Color(0xFFF09595)
                        : const Color(0xFFFAC775),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment:
                      MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          eventLabel,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: dotColor,
                          ),
                        ),
                        Text(
                          timeLabel,
                          style: const TextStyle(
                              fontSize: 11, color: Colors.grey),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Face: ${((faceScore as double) * 100).toStringAsFixed(0)}%  '
                          'Drift: ${((drift as double) * 100).toStringAsFixed(0)}%  '
                          'Score: $fraudScore',
                      style: const TextStyle(
                          fontSize: 11,
                          color: Colors.grey,
                          fontFamily: 'Courier'),
                    ),
                    if (event['face_absent'] == true)
                      const Text('⚠ Face absent',
                          style: TextStyle(
                              fontSize: 11,
                              color: Color(0xFFA32D2D))),
                    if (event['multiple_faces'] == true)
                      const Text('⚠ Multiple faces detected',
                          style: TextStyle(
                              fontSize: 11,
                              color: Color(0xFFA32D2D))),
                    if (event['looking_away'] == true)
                      const Text('⚠ Looking away',
                          style: TextStyle(
                              fontSize: 11,
                              color: Color(0xFFBA7517))),
                    if (eventType == 'tab_switched' || eventType == 'app_backgrounded')
                      Text(
                        '⚠ Tab switched ${event['tab_switch_count'] != null ? '(count: ${event['tab_switch_count']})' : ''}',
                        style: const TextStyle(
                            fontSize: 11,
                            color: Color(0xFFA32D2D)),
                      ),
                    if (eventType == 'clipboard_blocked')
                      Text(
                        '⚠ Clipboard action blocked (${event['action'] ?? 'unknown'})',
                        style: const TextStyle(
                            fontSize: 11,
                            color: Color(0xFFA32D2D)),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Escalate student ───────────────────────────────────────────────────────
  Future<void> _escalateStudent(Map<String, dynamic> student) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Escalate for Inquiry?'),
        content: Text(
          'This will flag ${student['student_name'] ?? 'this student'} '
              'for formal inquiry. This action is logged.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFA32D2D)),
            child: const Text('Escalate'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _db
          .collection('reports')
          .doc(student['id'] ?? '')
          .update({'escalated': true, 'recommendation': 'escalate'});

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Student escalated for formal inquiry.'),
            backgroundColor: Color(0xFFA32D2D),
          ),
        );
        _loadReports();
      }
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
}
