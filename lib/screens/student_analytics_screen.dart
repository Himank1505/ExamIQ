import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fl_chart/fl_chart.dart';
import '../services/api_service.dart';

class StudentAnalyticsScreen extends StatefulWidget {
  final String studentId;
  final List<Map<String, dynamic>> completedExams;

  const StudentAnalyticsScreen({
    super.key,
    required this.studentId,
    required this.completedExams,
  });

  @override
  State<StudentAnalyticsScreen> createState() => _StudentAnalyticsScreenState();
}

class _StudentAnalyticsScreenState extends State<StudentAnalyticsScreen> {
  final _db = FirebaseFirestore.instance;

  bool _isLoading = true;
  List<_ExamRecord> _records = [];

  // AI insights
  Map<String, dynamic>? _insights;
  bool _insightsLoading = false;
  String? _insightsError;

  @override
  void initState() {
    super.initState();
    _loadAnalytics();
  }

  Future<void> _loadAnalytics() async {
    setState(() => _isLoading = true);
    final records = <_ExamRecord>[];

    for (final exam in widget.completedExams) {
      final examId    = exam['id'] as String? ?? '';
      final title     = exam['title'] as String? ?? 'Untitled';
      final startTime = _parseDate(exam['start_time']);
      final durationMins = (exam['duration_mins'] as num?)?.toInt() ?? 90;

      // Score doc
      final scoreDoc = await _db
          .collection('exam_scores')
          .doc('${examId}_${widget.studentId}')
          .get();

      int    totalEarned = 0;
      int    totalMarks  = 0;
      double percentage  = 0;
      List<Map<String, dynamic>> questionScores = [];
      DateTime? gradedAt;

      if (scoreDoc.exists) {
        final d = scoreDoc.data()!;
        totalEarned    = (d['total_earned'] as num?)?.toInt() ?? 0;
        totalMarks     = (d['total_marks']  as num?)?.toInt() ?? 0;
        percentage     = (d['percentage']   as num?)?.toDouble() ?? 0;
        questionScores = List<Map<String, dynamic>>.from(
          ((d['question_scores'] as List?) ?? [])
              .map((e) => Map<String, dynamic>.from(e as Map)),
        );
        gradedAt = _parseDate(d['graded_at']);
      }

      // Submission time → duration taken
      final answerDoc = await _db
          .collection('exam_answers')
          .doc('${examId}_${widget.studentId}')
          .get();
      DateTime? submittedAt;
      if (answerDoc.exists) {
        submittedAt = _parseDate(answerDoc.data()?['submitted_at']);
      }
      int? minutesTaken;
      if (startTime != null && submittedAt != null) {
        minutesTaken = submittedAt.difference(startTime).inMinutes.clamp(0, durationMins);
      }

      // Flag events
      final eventsSnap = await _db
          .collection('exam_events')
          .where('exam_id',    isEqualTo: examId)
          .where('student_id', isEqualTo: widget.studentId)
          .get();

      final events    = eventsSnap.docs.map((d) => d.data()).toList();
      final flagCount = events.where((e) =>
          ['soft', 'hard', 'critical'].contains(e['flag_level'])).length;
      final tabSwitches = events
          .where((e) => e['event_type'] == 'tab_switched')
          .length;

      records.add(_ExamRecord(
        examId:         examId,
        title:          title,
        startTime:      startTime,
        submittedAt:    submittedAt,
        minutesTaken:   minutesTaken,
        totalEarned:    totalEarned,
        totalMarks:     totalMarks,
        percentage:     percentage,
        questionScores: questionScores,
        flagCount:      flagCount,
        tabSwitches:    tabSwitches,
        events:         events,
      ));
    }

    // Chronological order for chart (oldest first)
    records.sort((a, b) => (a.startTime ?? DateTime(0))
        .compareTo(b.startTime ?? DateTime(0)));

    if (mounted) setState(() { _records = records; _isLoading = false; });
    _fetchInsights();
  }

  Future<void> _fetchInsights() async {
    if (_records.isEmpty) return;
    setState(() { _insightsLoading = true; _insightsError = null; });

    final graded = _records.where((r) => r.totalMarks > 0).toList();

    final payload = {
      'exams_taken': _records.length,
      'avg_score_pct': double.parse(_avgPercentage.toStringAsFixed(1)),
      'best_score_pct': double.parse(_bestPercentage.toStringAsFixed(1)),
      'total_flags': _totalFlags,
      'score_trend': graded.map((r) => {
        'exam': r.title,
        'score_pct': double.parse(r.percentage.toStringAsFixed(1)),
        'date': r.startTime?.toIso8601String().substring(0, 10) ?? '',
      }).toList(),
      'time_management': _records
          .where((r) => r.minutesTaken != null)
          .map((r) => {
                'exam': r.title,
                'mins_taken': r.minutesTaken,
              })
          .toList(),
      'mcq_correct_rate': _mcqCorrectRate(),
      'text_avg_pct': _textAvgPct(),
    };

    final result = await ApiService.getStudentInsights(performanceData: payload);
    if (!mounted) return;
    if (result['success'] == true) {
      setState(() { _insights = result; _insightsLoading = false; });
    } else {
      setState(() {
        _insightsError = result['error'] ?? 'Could not generate insights.';
        _insightsLoading = false;
      });
    }
  }

  double _mcqCorrectRate() {
    int correct = 0, total = 0;
    for (final r in _records) {
      for (final q in r.questionScores) {
        if (q['type'] == 'mcq') {
          total++;
          if (q['is_correct'] == true) correct++;
        }
      }
    }
    return total == 0 ? 0 : double.parse((correct / total * 100).toStringAsFixed(1));
  }

  double _textAvgPct() {
    double earned = 0; int marks = 0;
    for (final r in _records) {
      for (final q in r.questionScores) {
        if (q['type'] == 'text') {
          earned += (q['earned'] as num?)?.toDouble() ?? 0;
          marks  += (q['marks']  as num?)?.toInt()    ?? 0;
        }
      }
    }
    return marks == 0 ? 0 : double.parse((earned / marks * 100).toStringAsFixed(1));
  }

  DateTime? _parseDate(dynamic v) {
    if (v == null) return null;
    if (v is DateTime) return v;
    if (v is String) return DateTime.tryParse(v);
    return null;
  }

  // ── Summary stats ──────────────────────────────────────────────────────────
  double get _avgPercentage {
    final graded = _records.where((r) => r.totalMarks > 0).toList();
    if (graded.isEmpty) return 0;
    return graded.map((r) => r.percentage).reduce((a, b) => a + b) / graded.length;
  }

  double get _bestPercentage {
    if (_records.isEmpty) return 0;
    return _records.map((r) => r.percentage).reduce((a, b) => a > b ? a : b);
  }

  int get _totalFlags => _records.fold(0, (sum, r) => sum + r.flagCount);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8F7FF),
      appBar: AppBar(
        title: const Text('My Performance'),
        backgroundColor: const Color(0xFF534AB7),
        foregroundColor: Colors.white,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF534AB7)))
          : _records.isEmpty
              ? _emptyState()
              : RefreshIndicator(
                  onRefresh: _loadAnalytics,
                  child: SingleChildScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildSummaryCards(),
                        const SizedBox(height: 20),
                        _buildInsightsCard(),
                        const SizedBox(height: 20),
                        _buildScoreChart(),
                        const SizedBox(height: 20),
                        _buildSectionTitle('Exam History'),
                        const SizedBox(height: 12),
                        ..._records.reversed.map(_buildExamCard),
                        const SizedBox(height: 32),
                      ],
                    ),
                  ),
                ),
    );
  }

  // ── Summary cards ──────────────────────────────────────────────────────────
  Widget _buildSummaryCards() {
    return Column(
      children: [
        Row(
          children: [
            _summaryCard('${_records.length}', 'Exams Taken',
                Icons.assignment_turned_in_outlined,
                const Color(0xFF534AB7), const Color(0xFFEEEDFE)),
            const SizedBox(width: 10),
            _summaryCard('${_avgPercentage.toStringAsFixed(1)}%', 'Avg Score',
                Icons.bar_chart_rounded,
                const Color(0xFF1D9E75), const Color(0xFFE1F5EE)),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            _summaryCard('${_bestPercentage.toStringAsFixed(1)}%', 'Best Score',
                Icons.emoji_events_outlined,
                const Color(0xFFBA7517), const Color(0xFFFAEEDA)),
            const SizedBox(width: 10),
            _summaryCard('$_totalFlags', 'Total Flags',
                Icons.flag_outlined,
                _totalFlags == 0 ? const Color(0xFF1D9E75) : const Color(0xFFA32D2D),
                _totalFlags == 0 ? const Color(0xFFE1F5EE) : const Color(0xFFFCEBEB)),
          ],
        ),
      ],
    );
  }

  Widget _summaryCard(String value, String label, IconData icon,
      Color color, Color bg) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(value,
                      style: TextStyle(
                          fontSize: 18, fontWeight: FontWeight.bold, color: color)),
                  Text(label,
                      style: TextStyle(fontSize: 11, color: color.withOpacity(0.8))),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── AI Insights card ──────────────────────────────────────────────────────
  Widget _buildInsightsCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF534AB7), Color(0xFF7F77DD)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.auto_awesome_rounded,
                  color: Colors.white, size: 16),
              const SizedBox(width: 8),
              const Text('AI Insights',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.bold)),
              const Spacer(),
              if (!_insightsLoading)
                GestureDetector(
                  onTap: _fetchInsights,
                  child: const Icon(Icons.refresh,
                      color: Colors.white70, size: 18),
                ),
            ],
          ),
          const SizedBox(height: 12),

          if (_insightsLoading)
            const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: CircularProgressIndicator(
                    color: Colors.white, strokeWidth: 2),
              ),
            )
          else if (_insightsError != null)
            Text(_insightsError!,
                style:
                    const TextStyle(color: Colors.white70, fontSize: 13))
          else if (_insights != null) ...[
            // Summary
            Text(
              _insights!['summary'] ?? '',
              style: const TextStyle(
                  color: Colors.white, fontSize: 13, height: 1.5),
            ),
            const SizedBox(height: 14),

            if (_insights!['strengths'] is List &&
                (_insights!['strengths'] as List).isNotEmpty) ...[
              _insightSection(
                  Icons.thumb_up_outlined, 'Strengths',
                  List<String>.from(_insights!['strengths'] as List)),
              const SizedBox(height: 12),
            ],

            if (_insights!['areas_to_improve'] is List &&
                (_insights!['areas_to_improve'] as List).isNotEmpty) ...[
              _insightSection(
                  Icons.trending_up_rounded, 'Areas to improve',
                  List<String>.from(
                      _insights!['areas_to_improve'] as List)),
              const SizedBox(height: 12),
            ],

            if (_insights!['recommendations'] is List &&
                (_insights!['recommendations'] as List).isNotEmpty) ...[
              _insightSection(
                  Icons.lightbulb_outline_rounded, 'Recommendations',
                  List<String>.from(
                      _insights!['recommendations'] as List)),
            ],

            if (_insights!['integrity_note'] != null &&
                _insights!['integrity_note'].toString().isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.shield_outlined,
                        color: Colors.white70, size: 14),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _insights!['integrity_note'].toString(),
                        style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                            height: 1.4),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _insightSection(IconData icon, String heading, List<String> items) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, color: Colors.white70, size: 13),
            const SizedBox(width: 6),
            Text(heading,
                style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.5)),
          ],
        ),
        const SizedBox(height: 6),
        ...items.map((item) => Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('• ',
                      style: TextStyle(color: Colors.white, fontSize: 13)),
                  Expanded(
                    child: Text(item,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            height: 1.4)),
                  ),
                ],
              ),
            )),
      ],
    );
  }

  // ── Score trend bar chart ──────────────────────────────────────────────────
  Widget _buildScoreChart() {
    if (_records.isEmpty) return const SizedBox();
    final graded = _records.where((r) => r.totalMarks > 0).toList();
    if (graded.isEmpty) return const SizedBox();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE8E8E8)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionTitle('Score Trend'),
          const SizedBox(height: 16),
          SizedBox(
            height: 180,
            child: BarChart(
              BarChartData(
                maxY: 100,
                minY: 0,
                gridData: FlGridData(
                  show: true,
                  horizontalInterval: 25,
                  drawVerticalLine: false,
                  getDrawingHorizontalLine: (_) => FlLine(
                    color: const Color(0xFFE8E8E8),
                    strokeWidth: 1,
                  ),
                ),
                borderData: FlBorderData(show: false),
                titlesData: FlTitlesData(
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      interval: 25,
                      reservedSize: 32,
                      getTitlesWidget: (v, _) => Text(
                        '${v.toInt()}%',
                        style: const TextStyle(fontSize: 10, color: Colors.grey),
                      ),
                    ),
                  ),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      getTitlesWidget: (v, _) {
                        final i = v.toInt();
                        if (i < 0 || i >= graded.length) return const SizedBox();
                        final title = graded[i].title;
                        final label = title.length > 8
                            ? title.substring(0, 8)
                            : title;
                        return Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(label,
                              style: const TextStyle(fontSize: 9, color: Colors.grey),
                              overflow: TextOverflow.ellipsis),
                        );
                      },
                      reservedSize: 28,
                    ),
                  ),
                  rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                  topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                ),
                barGroups: graded.asMap().entries.map((e) {
                  final pct = e.value.percentage;
                  final color = pct >= 75
                      ? const Color(0xFF1D9E75)
                      : pct >= 50
                          ? const Color(0xFFBA7517)
                          : const Color(0xFFA32D2D);
                  return BarChartGroupData(
                    x: e.key,
                    barRods: [
                      BarChartRodData(
                        toY: pct,
                        color: color,
                        width: 20,
                        borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(4)),
                      ),
                    ],
                  );
                }).toList(),
                barTouchData: BarTouchData(
                  touchTooltipData: BarTouchTooltipData(
                    getTooltipItem: (group, _, rod, __) => BarTooltipItem(
                      '${rod.toY.toStringAsFixed(1)}%',
                      const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Per-exam history card ──────────────────────────────────────────────────
  Widget _buildExamCard(_ExamRecord r) {
    final hasScore  = r.totalMarks > 0;
    final pctColor  = r.percentage >= 75
        ? const Color(0xFF1D9E75)
        : r.percentage >= 50
            ? const Color(0xFFBA7517)
            : const Color(0xFFA32D2D);
    final pctBg     = r.percentage >= 75
        ? const Color(0xFFE1F5EE)
        : r.percentage >= 50
            ? const Color(0xFFFAEEDA)
            : const Color(0xFFFCEBEB);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE8E8E8)),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(0.03),
              blurRadius: 6,
              offset: const Offset(0, 2)),
        ],
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          childrenPadding:
              const EdgeInsets.fromLTRB(16, 0, 16, 14),
          title: Text(r.title,
              style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF1a1a2e))),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              children: [
                if (r.startTime != null) ...[
                  const Icon(Icons.calendar_today_outlined,
                      size: 12, color: Colors.grey),
                  const SizedBox(width: 4),
                  Text(_formatDate(r.startTime!),
                      style:
                          const TextStyle(fontSize: 11, color: Colors.grey)),
                  const SizedBox(width: 12),
                ],
                if (r.minutesTaken != null) ...[
                  const Icon(Icons.timer_outlined,
                      size: 12, color: Colors.grey),
                  const SizedBox(width: 4),
                  Text('${r.minutesTaken} min taken',
                      style:
                          const TextStyle(fontSize: 11, color: Colors.grey)),
                ],
              ],
            ),
          ),
          trailing: hasScore
              ? Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                      color: pctBg,
                      borderRadius: BorderRadius.circular(8)),
                  child: Text(
                    '${r.percentage.toStringAsFixed(1)}%',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: pctColor),
                  ),
                )
              : const Text('Ungraded',
                  style: TextStyle(fontSize: 12, color: Colors.grey)),
          children: [
            // Score row
            if (hasScore) ...[
              _detailRow(Icons.grade_outlined, 'Score',
                  '${r.totalEarned} / ${r.totalMarks} marks'),
              const SizedBox(height: 6),
            ],
            // Flags
            _detailRow(
              r.flagCount == 0
                  ? Icons.check_circle_outline
                  : Icons.flag_outlined,
              'Flags raised',
              r.flagCount == 0
                  ? 'None — clean session'
                  : '${r.flagCount} flag${r.flagCount > 1 ? 's' : ''}',
              color: r.flagCount == 0
                  ? const Color(0xFF1D9E75)
                  : const Color(0xFFA32D2D),
            ),
            if (r.tabSwitches > 0) ...[
              const SizedBox(height: 6),
              _detailRow(Icons.tab_unselected_rounded, 'Tab switches',
                  '${r.tabSwitches}',
                  color: const Color(0xFFBA7517)),
            ],
            // Per-question breakdown
            if (r.questionScores.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Text('Questions',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF1a1a2e))),
              const SizedBox(height: 8),
              ...r.questionScores.asMap().entries.map((e) {
                final idx    = e.key;
                final q      = e.value;
                final earned = (q['earned'] as num?)?.toInt() ?? 0;
                final marks  = (q['marks']  as num?)?.toInt() ?? 1;
                final qType  = q['type'] as String? ?? 'mcq';
                final feedback = q['feedback'] as String?;
                final dot = earned == marks
                    ? const Color(0xFF1D9E75)
                    : earned > 0
                        ? const Color(0xFFBA7517)
                        : const Color(0xFFA32D2D);
                return Container(
                  margin: const EdgeInsets.only(bottom: 6),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF8F7FF),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFFE8E8E8)),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        margin: const EdgeInsets.only(top: 3),
                        width: 8, height: 8,
                        decoration: BoxDecoration(
                            color: dot, shape: BoxShape.circle),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Q${idx + 1}  ·  ${qType.toUpperCase()}',
                              style: const TextStyle(
                                  fontSize: 11,
                                  color: Colors.grey,
                                  fontWeight: FontWeight.w500),
                            ),
                            if (feedback != null && feedback.isNotEmpty) ...[
                              const SizedBox(height: 2),
                              Text(feedback,
                                  style: const TextStyle(
                                      fontSize: 11,
                                      color: Color(0xFF444441))),
                            ],
                          ],
                        ),
                      ),
                      Text('$earned/$marks',
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: dot)),
                    ],
                  ),
                );
              }),
            ],
          ],
        ),
      ),
    );
  }

  Widget _detailRow(IconData icon, String label, String value,
      {Color color = Colors.grey}) {
    return Row(
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 6),
        Text('$label: ',
            style: const TextStyle(fontSize: 12, color: Colors.grey)),
        Text(value,
            style: TextStyle(
                fontSize: 12, color: color, fontWeight: FontWeight.w500)),
      ],
    );
  }

  Widget _buildSectionTitle(String title) => Text(
        title,
        style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.bold,
            color: Color(0xFF1a1a2e)),
      );

  Widget _emptyState() => Center(
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.bar_chart_rounded, size: 52, color: Colors.grey[300]),
              const SizedBox(height: 12),
              const Text('No exam history yet',
                  style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: Colors.grey,
                      fontSize: 15)),
              const SizedBox(height: 6),
              const Text('Your scores and analytics will appear here\nafter you complete exams.',
                  style: TextStyle(fontSize: 13, color: Colors.grey),
                  textAlign: TextAlign.center),
            ],
          ),
        ),
      );

  String _formatDate(DateTime dt) {
    const m = ['Jan','Feb','Mar','Apr','May','Jun',
                'Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${dt.day} ${m[dt.month - 1]} ${dt.year}';
  }
}

class _ExamRecord {
  final String examId;
  final String title;
  final DateTime? startTime;
  final DateTime? submittedAt;
  final int? minutesTaken;
  final int totalEarned;
  final int totalMarks;
  final double percentage;
  final List<Map<String, dynamic>> questionScores;
  final int flagCount;
  final int tabSwitches;
  final List<Map<String, dynamic>> events;

  _ExamRecord({
    required this.examId,
    required this.title,
    required this.startTime,
    required this.submittedAt,
    required this.minutesTaken,
    required this.totalEarned,
    required this.totalMarks,
    required this.percentage,
    required this.questionScores,
    required this.flagCount,
    required this.tabSwitches,
    required this.events,
  });
}
