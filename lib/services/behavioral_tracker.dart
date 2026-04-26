import 'dart:math' as math;

/// Records keystroke timing during form fill to produce a real behavioral baseline
/// for enrollment, replacing the previous dummy data.
class BehavioralTracker {
  final List<int> _timestamps = [];
  int _deletions = 0;
  int _totalEdits = 0;
  DateTime? _startedAt;

  void recordKeystroke({required bool isDeletion}) {
    _startedAt ??= DateTime.now();
    _timestamps.add(DateTime.now().millisecondsSinceEpoch);
    _totalEdits++;
    if (isDeletion) _deletions++;
  }

  /// Returns 3 identical samples of the 8-feature vector the backend expects.
  /// Falls back to a static baseline when fewer than 4 keystrokes were recorded.
  List<List<double>> buildSamples() {
    if (_timestamps.length < 4) return _baseline();

    final gaps = <double>[];
    for (int i = 1; i < _timestamps.length; i++) {
      gaps.add((_timestamps[i] - _timestamps[i - 1]) / 1000.0);
    }

    final meanGap = gaps.reduce((a, b) => a + b) / gaps.length;
    double varSum = 0.0;
    for (final g in gaps) {
      final d = g - meanGap;
      varSum += d * d;
    }
    final gapStd = math.sqrt(varSum / math.max(1, gaps.length));
    final backspaceRatio =
        _totalEdits > 0 ? (_deletions / _totalEdits) : 0.0;

    final sample = [
      meanGap.clamp(0.0, 30.0),
      gapStd.clamp(0.0, 15.0),
      backspaceRatio.clamp(0.0, 1.0),
      0.0, // tab switch rate — N/A at enrollment
      0.0, // paste rate — N/A at enrollment
      0.0, // answer change rate — N/A at enrollment
      0.0, // max edit burst — N/A at enrollment
      0.0, // idle ratio — N/A at enrollment
    ];
    return [sample, sample, sample];
  }

  List<List<double>> _baseline() => [
        [4.2, 0.11, 0.08, 0.0, 0.0, 0.09, 0.04, 0.06],
        [3.8, 0.13, 0.09, 0.0, 0.0, 0.11, 0.05, 0.07],
        [4.5, 0.10, 0.07, 0.0, 0.0, 0.08, 0.03, 0.05],
      ];
}
