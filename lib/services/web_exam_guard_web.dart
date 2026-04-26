import 'dart:convert';
import 'dart:async';
import 'dart:html' as html;

class WebExamGuard {
  final List<StreamSubscription> _subs = [];
  final List<void Function()> _removeDomListeners = [];
  bool _wasHidden = false;
  bool _switchPending = false;
  Timer? _pollTimer;
  String? _prevUserSelect;
  String? _prevWebkitUserSelect;
  String? _prevMozUserSelect;
  String? _prevMsUserSelect;

  void start({
    required void Function(String action) onClipboardBlocked,
    required void Function(String source) onTabSwitched,
    required void Function(String source) onTabReturned,
    void Function()? onScreenShareDetected,
  }) {
    stop();
    _lockBrowserSelection();
    _wasHidden = html.document.hidden == true;
    _switchPending = false;
    _startIndexExamMode();

    void addDomListener(
      html.EventTarget target,
      String type,
      void Function(html.Event event) handler,
    ) {
      final fn = (html.Event event) => handler(event);
      target.addEventListener(type, fn, true); // capture phase
      _removeDomListeners.add(() => target.removeEventListener(type, fn, true));
    }

    void block(html.Event event, String action) {
      event.preventDefault();
      event.stopPropagation();
      onClipboardBlocked(action);
    }

    // Block clipboard/context actions at both document + window capture.
    for (final target in <html.EventTarget>[html.document, html.window]) {
      addDomListener(target, 'copy', (event) => block(event, 'copy'));
      addDomListener(target, 'cut', (event) => block(event, 'cut'));
      addDomListener(target, 'paste', (event) => block(event, 'paste'));
      addDomListener(target, 'contextmenu', (event) => block(event, 'context_menu'));
      addDomListener(target, 'dragstart', (event) => block(event, 'drag_blocked'));
      addDomListener(target, 'drop', (event) => block(event, 'drop_blocked'));
      addDomListener(target, 'selectstart', (event) => block(event, 'selection_blocked'));
      addDomListener(target, 'beforeinput', (event) {
        final dynamic e = event;
        final type = '${e.inputType ?? ''}'.toLowerCase();
        if (type.contains('paste') || type.contains('drop') || type.contains('insertfromyank')) {
          block(event, 'beforeinput_$type');
        }
      });
    }

    _subs.add(html.window.onBlur.listen((_) {
      _wasHidden = true;
      _switchPending = true;
      onTabSwitched('window_blur');
    }));

    _subs.add(html.document.onVisibilityChange.listen((_) {
      if (html.document.hidden == true) {
        _wasHidden = true;
        _switchPending = true;
        onTabSwitched('visibility_hidden');
      } else if (_wasHidden || _switchPending) {
        _wasHidden = false;
        _switchPending = false;
        onTabReturned('visibility_visible');
      }
    }));

    _subs.add(html.window.onFocus.listen((_) {
      if (_wasHidden || _switchPending) {
        _wasHidden = false;
        _switchPending = false;
        onTabReturned('window_focus');
      }
    }));

    // Bridge events emitted from web/index.html (postMessage).
    _subs.add(html.window.onMessage.listen((event) {
      final raw = event.data;
      Map<String, dynamic>? data;
      if (raw is String) {
        try {
          final parsed = jsonDecode(raw);
          if (parsed is Map<String, dynamic>) {
            data = parsed;
          } else if (parsed is Map) {
            data = parsed.map((k, v) => MapEntry('$k', v));
          }
        } catch (_) {}
      } else if (raw is Map<String, dynamic>) {
        data = raw;
      } else if (raw is Map) {
        data = raw.map((k, v) => MapEntry('$k', v));
      }
      if (data == null) return;
      final source = '${data['source'] ?? ''}';
      if (source != 'examiq_guard' && source != 'examiq_anti_cheat') return;
      final type = '${data['type'] ?? ''}';
      if (type == 'screen_share_attempted') {
        onScreenShareDetected?.call();
      } else if (type == 'clipboard_blocked') {
        onClipboardBlocked('${data['detail'] ?? 'blocked'}');
      } else if (type == 'tab_hidden' || type == 'window_blur' || type == 'tab_switched') {
        _wasHidden = true;
        _switchPending = true;
        onTabSwitched('bridge_$type');
      } else if (type == 'tab_visible' || type == 'window_focus' || type == 'tab_returned') {
        if (_wasHidden || _switchPending) {
          _wasHidden = false;
          _switchPending = false;
          onTabReturned('bridge_$type');
        }
      }
    }));

    _subs.add(html.window.onKeyDown.listen((event) {
      final key = event.key?.toLowerCase() ?? '';
      final ctrlOrMeta = event.ctrlKey || event.metaKey;
      final shiftInsert = event.shiftKey && key == 'insert';

      if (!ctrlOrMeta && !shiftInsert) return;

      if (shiftInsert) {
        event.preventDefault();
        onClipboardBlocked('paste');
        return;
      }

      if (key == 'c') {
        event.preventDefault();
        onClipboardBlocked('copy');
      } else if (key == 'v') {
        event.preventDefault();
        onClipboardBlocked('paste');
      } else if (key == 'x') {
        event.preventDefault();
        onClipboardBlocked('cut');
      } else if (key == 'a') {
        event.preventDefault();
        onClipboardBlocked('select_all');
      }
    }));

    // Fallback polling: catches browsers that skip blur/visibility events.
    _pollTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      final hidden = html.document.hidden == true;
      if (hidden && !_wasHidden) {
        _wasHidden = true;
        _switchPending = true;
        onTabSwitched('poll_hidden_or_blur');
        return;
      }

      if (!hidden && (_wasHidden || _switchPending)) {
        _wasHidden = false;
        _switchPending = false;
        onTabReturned('poll_visible_or_focus');
      }
    });
  }

  void stop() {
    for (final sub in _subs) {
      sub.cancel();
    }
    _subs.clear();
    for (final remove in _removeDomListeners) {
      remove();
    }
    _removeDomListeners.clear();
    _pollTimer?.cancel();
    _pollTimer = null;
    _wasHidden = false;
    _switchPending = false;
    _unlockBrowserSelection();
    _stopIndexExamMode();
  }

  void _startIndexExamMode() {
    try {
      final dynamic w = html.window;
      w.startExamMode();
    } catch (_) {}
  }

  void _stopIndexExamMode() {
    try {
      final dynamic w = html.window;
      w.stopExamMode();
    } catch (_) {}
  }

  void _lockBrowserSelection() {
    final style = html.document.body?.style;
    if (style == null) return;
    _prevUserSelect = style.userSelect;
    _prevWebkitUserSelect = style.getPropertyValue('-webkit-user-select');
    _prevMozUserSelect = style.getPropertyValue('-moz-user-select');
    _prevMsUserSelect = style.getPropertyValue('-ms-user-select');
    style.userSelect = 'none';
    style.setProperty('-webkit-user-select', 'none');
    style.setProperty('-moz-user-select', 'none');
    style.setProperty('-ms-user-select', 'none');
  }

  void _unlockBrowserSelection() {
    final style = html.document.body?.style;
    if (style == null) return;
    style.userSelect = _prevUserSelect ?? '';
    style.setProperty('-webkit-user-select', _prevWebkitUserSelect ?? '');
    style.setProperty('-moz-user-select', _prevMozUserSelect ?? '');
    style.setProperty('-ms-user-select', _prevMsUserSelect ?? '');
  }
}
