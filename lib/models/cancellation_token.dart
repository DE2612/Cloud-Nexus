/// Cancellation token for pausing/cancelling tasks
class CancellationToken {
  bool _isCancelled = false;
  bool _isPaused = false;

  bool get isCancelled => _isCancelled;
  bool get isPaused => _isPaused;
  bool get canContinue => !_isCancelled && !_isPaused;

  void cancel() {
    _isCancelled = true;
    _isPaused = false;
  }

  void pause() {
    _isPaused = true;
    _isCancelled = false;
  }

  void resume() {
    _isPaused = false;
  }

  void reset() {
    _isCancelled = false;
    _isPaused = false;
  }
}