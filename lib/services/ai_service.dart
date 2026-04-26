import 'api_service.dart';

class AiService {
  static Future<List<Map<String, dynamic>>> generateQuestions({
    required String topic,
    int mcqCount    = 5,
    int textCount   = 2,
    String difficulty = 'medium',
  }) => ApiService.generateQuestions(
        topic:      topic,
        mcqCount:   mcqCount,
        textCount:  textCount,
        difficulty: difficulty,
      );

  static Future<Map<String, dynamic>> gradeTextAnswer({
    required String question,
    required String studentAnswer,
    required String modelAnswer,
    required int maxMarks,
  }) => ApiService.gradeAnswer(
        question:      question,
        studentAnswer: studentAnswer,
        modelAnswer:   modelAnswer,
        maxMarks:      maxMarks,
      );
}
