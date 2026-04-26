import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../services/auth_service.dart';
import 'exam_screen.dart';
import 'enrollment_screen.dart';

class StudentDashboard extends StatefulWidget {
  const StudentDashboard({super.key});

  @override
  State<StudentDashboard> createState() => _StudentDashboardState();
}

class _StudentDashboardState extends State<StudentDashboard> {
  final _auth = AuthService();
  final _db   = FirebaseFirestore.instance;

  Map<String, dynamic>? _studentData;
  List<Map<String, dynamic>> _upcomingExams    = [];
  List<Map<String, dynamic>> _completedExams   = [];
  bool _isLoading = true;

  bool _isEnrollmentComplete(String? status) {
    return status == 'verified' || status == 'pending_ml';
  }

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
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) return;

      // Load student profile
      final studentDoc = await _db.collection('students').doc(uid).get();
      if (studentDoc.exists) {
        _studentData = {'id': studentDoc.id, ...studentDoc.data()!};
      }

      // Load exams this student is registered for
      final examsSnap = await _db
          .collection('exams')
          .where('registered_students', arrayContains: uid)
          .get();

      final now = DateTime.now();
      _upcomingExams  = [];
      _completedExams = [];

      final loadedExams = <Map<String, dynamic>>[];
      for (final doc in examsSnap.docs) {
        loadedExams.add({'id': doc.id, ...doc.data()});
      }

      // Fallback for newly registered students: show exams by matching
      // course/college even before explicit registration mapping exists.
      if (loadedExams.isEmpty && _studentData != null) {
        final allExamsSnap = await _db.collection('exams').get();
        final studentCourse = (_studentData?['course'] ?? '').toString().trim();
        final studentCollege = (_studentData?['college'] ?? '').toString().trim();
        for (final doc in allExamsSnap.docs) {
          final exam = {'id': doc.id, ...doc.data()};
          final examCourse = (exam['course'] ?? '').toString().trim();
          final examCollege = (exam['college'] ?? '').toString().trim();
          if ((examCourse.isNotEmpty && examCourse == studentCourse) ||
              (examCollege.isNotEmpty && examCollege == studentCollege)) {
            loadedExams.add(exam);
          }
        }
      }

      for (final exam in loadedExams) {
        final endTime = _parseDate(exam['end_time']) ?? now;
        if (endTime.isAfter(now)) {
          _upcomingExams.add(exam);
        } else {
          _completedExams.add(exam);
        }
      }

      // Sort upcoming by start time
      _upcomingExams.sort((a, b) {
        final aTime = _parseDate(a['start_time']) ?? now;
        final bTime = _parseDate(b['start_time']) ?? now;
        return aTime.compareTo(bTime);
      });

    } catch (e) {
      debugPrint('Error loading student data: $e');
    }
    if (mounted) setState(() => _isLoading = false);
  }

  Future<void> _logout() async {
    await _auth.logout();
    if (mounted) Navigator.pushReplacementNamed(context, '/login');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8F7FF),
      appBar: AppBar(
        title: const Text('ExamIQ'),
        automaticallyImplyLeading: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadData,
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: _logout,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(
        child: CircularProgressIndicator(color: Color(0xFF534AB7)),
      )
          : RefreshIndicator(
        onRefresh: _loadData,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildWelcomeCard(),
              const SizedBox(height: 20),
              _buildEnrollmentBanner(),
              _buildStatsRow(),
              const SizedBox(height: 24),
              _buildSectionTitle('Upcoming Exams'),
              const SizedBox(height: 12),
              _buildUpcomingExams(),
              const SizedBox(height: 24),
              _buildSectionTitle('Completed Exams'),
              const SizedBox(height: 12),
              _buildCompletedExams(),
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }

  // ── Welcome card ───────────────────────────────────────────────────────────
  Widget _buildWelcomeCard() {
    final name   = _studentData?['name'] ?? 'Student';
    final college = _studentData?['college'] ?? '';
    final course  = _studentData?['course'] ?? '';
    final status  = _studentData?['enrollment_status'] ?? 'pending';
    final isVerified = _isEnrollmentComplete(status);

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF534AB7), Color(0xFF7F77DD)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          // Avatar
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.2),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.person_rounded,
              color: Colors.white,
              size: 30,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Hello, ${name.split(' ').first}!',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  course,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.85),
                    fontSize: 12,
                  ),
                ),
                Text(
                  college,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.7),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          // Enrollment status badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: isVerified
                  ? const Color(0xFF1D9E75)
                  : Colors.orange,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              isVerified ? 'Verified' : 'Pending',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Enrollment banner (shows if not yet enrolled) ──────────────────────────
  Widget _buildEnrollmentBanner() {
    final status = _studentData?['enrollment_status'] ?? 'pending';
    if (_isEnrollmentComplete(status)) return const SizedBox();

    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFFAEEDA),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFFAC775)),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded,
              color: Color(0xFF854F0B), size: 22),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Face enrollment required',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF633806),
                    fontSize: 13,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  'Complete face enrollment to take exams.',
                  style: TextStyle(
                    color: Color(0xFF854F0B),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => EnrollmentScreen(
                  studentId: _studentData?['id'] ?? '',
                ),
              ),
            ),
            style: TextButton.styleFrom(
              backgroundColor: const Color(0xFF854F0B),
              foregroundColor: Colors.white,
              padding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            child: const Text(
              'Enroll Now',
              style: TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  // ── Stats row ──────────────────────────────────────────────────────────────
  Widget _buildStatsRow() {
    return Row(
      children: [
        _statCard(
          '${_upcomingExams.length}',
          'Upcoming',
          Icons.schedule_rounded,
          const Color(0xFF534AB7),
          const Color(0xFFEEEDFE),
        ),
        const SizedBox(width: 12),
        _statCard(
          '${_completedExams.length}',
          'Completed',
          Icons.check_circle_outline_rounded,
          const Color(0xFF1D9E75),
          const Color(0xFFE1F5EE),
        ),
        const SizedBox(width: 12),
        _statCard(
          _isEnrollmentComplete(_studentData?['enrollment_status']) ? '✓' : '!',
          'ID Status',
          Icons.verified_user_outlined,
          _isEnrollmentComplete(_studentData?['enrollment_status'])
              ? const Color(0xFF1D9E75)
              : const Color(0xFFBA7517),
          _isEnrollmentComplete(_studentData?['enrollment_status'])
              ? const Color(0xFFE1F5EE)
              : const Color(0xFFFAEEDA),
        ),
      ],
    );
  }

  Widget _statCard(
      String value,
      String label,
      IconData icon,
      Color color,
      Color bgColor,
      ) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(height: 6),
            Text(
              value,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                color: color.withOpacity(0.8),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Section title ──────────────────────────────────────────────────────────
  Widget _buildSectionTitle(String title) => Text(
    title,
    style: const TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.bold,
      color: Color(0xFF1a1a2e),
    ),
  );

  // ── Upcoming exams ─────────────────────────────────────────────────────────
  Widget _buildUpcomingExams() {
    if (_upcomingExams.isEmpty) {
      return _emptyState(
        Icons.event_available_rounded,
        'No upcoming exams',
        'Your scheduled exams will appear here.',
      );
    }

    return Column(
      children: _upcomingExams.map((exam) => _examCard(exam, upcoming: true)).toList(),
    );
  }

  // ── Completed exams ────────────────────────────────────────────────────────
  Widget _buildCompletedExams() {
    if (_completedExams.isEmpty) {
      return _emptyState(
        Icons.history_rounded,
        'No completed exams',
        'Exams you have taken will appear here.',
      );
    }

    return Column(
      children: _completedExams.map((exam) => _examCard(exam, upcoming: false)).toList(),
    );
  }

  // ── Exam card ──────────────────────────────────────────────────────────────
  Widget _examCard(Map<String, dynamic> exam, {required bool upcoming}) {
    final title     = exam['title'] ?? 'Untitled Exam';
    final course    = exam['course'] ?? '';
    final startTime = _parseDate(exam['start_time']);
    final duration  = exam['duration_mins'] ?? 90;
    final isVerified = _isEnrollmentComplete(_studentData?['enrollment_status']);

    String timeLabel = '';
    if (startTime != null) {
      final now  = DateTime.now();
      final diff = startTime.difference(now);
      if (diff.inDays > 0) {
        timeLabel = 'In ${diff.inDays} day${diff.inDays > 1 ? 's' : ''}';
      } else if (diff.inHours > 0) {
        timeLabel = 'In ${diff.inHours} hour${diff.inHours > 1 ? 's' : ''}';
      } else if (diff.inMinutes > 0) {
        timeLabel = 'In ${diff.inMinutes} min';
      } else if (!upcoming) {
        timeLabel = _formatDate(startTime);
      } else {
        timeLabel = 'Starting now';
      }
    }

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
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF1a1a2e),
                    ),
                  ),
                ),
                if (upcoming)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEEEDFE),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      timeLabel,
                      style: const TextStyle(
                        color: Color(0xFF534AB7),
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  )
                else
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE1F5EE),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Text(
                      'Completed',
                      style: TextStyle(
                        color: Color(0xFF085041),
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
                const Icon(Icons.book_outlined,
                    size: 14, color: Colors.grey),
                const SizedBox(width: 4),
                Text(
                  course,
                  style: const TextStyle(
                      color: Colors.grey, fontSize: 12),
                ),
                const SizedBox(width: 16),
                const Icon(Icons.timer_outlined,
                    size: 14, color: Colors.grey),
                const SizedBox(width: 4),
                Text(
                  '$duration mins',
                  style: const TextStyle(
                      color: Colors.grey, fontSize: 12),
                ),
              ],
            ),
            if (upcoming) ...[
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: isVerified
                      ? () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ExamScreen(
                        examId:    exam['id'],
                        studentId: _studentData?['id'] ?? '',
                        examTitle: title,
                      ),
                    ),
                  )
                      : () => _showEnrollmentRequired(),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: isVerified
                        ? const Color(0xFF534AB7)
                        : Colors.grey,
                    foregroundColor: Colors.white,
                    minimumSize: const Size(double.infinity, 42),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: Text(
                    isVerified ? 'Start Exam' : 'Enrollment Required',
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _showEnrollmentRequired() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Enrollment Required'),
        content: const Text(
          'You need to complete face enrollment before taking exams.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => EnrollmentScreen(
                    studentId: _studentData?['id'] ?? '',
                  ),
                ),
              );
            },
            child: const Text('Enroll Now'),
          ),
        ],
      ),
    );
  }

  Widget _emptyState(IconData icon, String title, String subtitle) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE8E8E8)),
      ),
      child: Center(
        child: Column(
          children: [
            Icon(icon, size: 40, color: Colors.grey[300]),
            const SizedBox(height: 10),
            Text(title,
                style: const TextStyle(
                    fontWeight: FontWeight.w600, color: Colors.grey)),
            const SizedBox(height: 4),
            Text(subtitle,
                style:
                const TextStyle(fontSize: 12, color: Colors.grey),
                textAlign: TextAlign.center),
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
    return '${dt.day} ${months[dt.month - 1]}, ${dt.hour}:${dt.minute.toString().padLeft(2,'0')}';
  }
}
