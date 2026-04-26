import 'dart:async';
import 'dart:convert';
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
// ignore: avoid_web_libraries_in_flutter
import 'dart:js' as js;

class AntiCheatEvent {
  final String type;
  final String detail;
  const AntiCheatEvent(this.type, this.detail);
}

class AntiCheatService {
  static final StreamController<AntiCheatEvent> _controller =
      StreamController<AntiCheatEvent>.broadcast();
  static bool _listening = false;
  static StreamSubscription<html.MessageEvent>? _msgSub;

  static Stream<AntiCheatEvent> get events {
    _ensureListener();
    return _controller.stream;
  }

  static void startExamMode() {
    _ensureListener();
    try {
      js.context.callMethod('startExamMode', []);
    } catch (_) {}
  }

  static void stopExamMode() {
    try {
      js.context.callMethod('stopExamMode', []);
    } catch (_) {}
  }

  static void _ensureListener() {
    if (_listening) return;
    _listening = true;
    _msgSub = html.window.onMessage.listen((event) {
      final raw = event.data;
      if (raw is! String) return;
      Map<String, dynamic> data;
      try {
        final parsed = jsonDecode(raw);
        if (parsed is! Map) return;
        data = parsed.map((k, v) => MapEntry('$k', v));
      } catch (_) {
        return;
      }

      if ('${data['source'] ?? ''}' != 'examiq_anti_cheat') return;
      final type = '${data['type'] ?? ''}';
      final detail = '${data['detail'] ?? ''}';
      if (type.isEmpty) return;
      _controller.add(AntiCheatEvent(type, detail));
    });
  }
}
