import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'api_service.dart';

class GradingService {
  static final _db = FirebaseFirestore.instance;

  static Future<void> gradeExam(String examId) async {
    final examDoc = await _db.collection('exams').doc(examId).get();
    if (!examDoc.exists) {
      debugPrint('[GradingService] Exam doc $examId not found');
      return;
    }

    final questions = List<Map<String, dynamic>>.from(
      ((examDoc.data()!['questions'] as List?) ?? [])
          .map((q) => Map<String, dynamic>.from(q as Map)),
    );
    debugPrint('[GradingService] Exam has ${questions.length} questions');

    final answersSnap = await _db
        .collection('exam_answers')
        .where('exam_id', isEqualTo: examId)
        .get();

    debugPrint('[GradingService] Found ${answersSnap.docs.length} answer submissions');

    for (final ansDoc in answersSnap.docs) {
      final ansData  = ansDoc.data();
      final studentId = ansData['student_id'] as String? ?? '';
      debugPrint('[GradingService] Grading student: $studentId');
      final rawAnswers = Map<String, dynamic>.from(ansData['answers'] as Map? ?? {});

      final questionScores = <Map<String, dynamic>>[];
      int totalEarned = 0;
      int totalMarks  = 0;

      for (int i = 0; i < questions.length; i++) {
        final q      = questions[i];
        final qType  = q['type'] as String? ?? 'mcq';
        final marks  = ((q['marks'] as num?) ?? 1).toInt();
        totalMarks  += marks;

        final raw = rawAnswers['$i'];

        if (qType == 'mcq') {
          final correctOption = q['correct_option'] is int
              ? q['correct_option'] as int
              : null;
          final studentOption = raw is int ? raw : null;
          final isCorrect     = correctOption != null && studentOption == correctOption;
          final earned        = isCorrect ? marks : 0;
          totalEarned += earned;
          questionScores.add({
            'q_index':        i,
            'type':           'mcq',
            'marks':          marks,
            'earned':         earned,
            'is_correct':     isCorrect,
            'student_answer': studentOption,
            'correct_answer': correctOption,
          });
        } else {
          final modelAnswer  = q['model_answer'] as String? ?? '';
          final studentText  = raw is String ? raw : '';
          final gradeResult  = modelAnswer.isNotEmpty
              ? await ApiService.gradeAnswer(
                  question:      q['q'] as String? ?? '',
                  studentAnswer: studentText,
                  modelAnswer:   modelAnswer,
                  maxMarks:      marks,
                )
              : {'score': 0, 'feedback': 'No model answer set.'};

          final earned = ((gradeResult['score'] as num?) ?? 0).toInt().clamp(0, marks);
          totalEarned += earned;
          questionScores.add({
            'q_index':        i,
            'type':           'text',
            'marks':          marks,
            'earned':         earned,
            'feedback':       gradeResult['feedback'],
            'student_answer': studentText,
          });
        }
      }

      final percentage =
          totalMarks > 0 ? (totalEarned / totalMarks * 100.0) : 0.0;

      await _db
          .collection('exam_scores')
          .doc('${examId}_$studentId')
          .set({
        'exam_id':        examId,
        'student_id':     studentId,
        'question_scores': questionScores,
        'total_earned':   totalEarned,
        'total_marks':    totalMarks,
        'percentage':     percentage,
        'graded_at':      DateTime.now().toIso8601String(),
        'grading_method': 'ai_assisted',
      });

      await ansDoc.reference.update({'graded': true});
    }
  }
}
