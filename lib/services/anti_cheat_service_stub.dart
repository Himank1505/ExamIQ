import 'dart:async';

class AntiCheatEvent {
  final String type;
  final String detail;
  const AntiCheatEvent(this.type, this.detail);
}

class AntiCheatService {
  static Stream<AntiCheatEvent> get events => const Stream.empty();
  static void startExamMode() {}
  static void stopExamMode() {}
}
