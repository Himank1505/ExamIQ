class WebExamGuard {
  void start({
    required void Function(String action) onClipboardBlocked,
    required void Function(String source) onTabSwitched,
    required void Function(String source) onTabReturned,
    void Function()? onScreenShareDetected,
  }) {}

  void stop() {}
}
