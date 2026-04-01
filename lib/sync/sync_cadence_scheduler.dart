import 'dart:async';

enum SyncCadencePhase { burst, steady }

class SyncCadenceScheduler {
  SyncCadenceScheduler({
    required this.action,
    required this.onPhaseChanged,
    this.burstDuration = const Duration(seconds: 10),
    this.burstInterval = const Duration(seconds: 2),
    this.steadyInterval = const Duration(seconds: 15),
  });

  final FutureOr<void> Function() action;
  final void Function(SyncCadencePhase phase) onPhaseChanged;
  final Duration burstDuration;
  final Duration burstInterval;
  final Duration steadyInterval;

  Timer? _timer;
  DateTime? _burstStartedAt;
  SyncCadencePhase? _currentPhase;

  void start({bool fireImmediately = true}) {
    _beginBurst();
    if (fireImmediately) {
      unawaited(Future.sync(action));
    }
    _scheduleNext();
  }

  void retriggerBurst({bool fireImmediately = true}) {
    _beginBurst();
    if (fireImmediately) {
      unawaited(Future.sync(action));
    }
    _scheduleNext();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void _beginBurst() {
    _timer?.cancel();
    _burstStartedAt = DateTime.now();
    _setPhase(SyncCadencePhase.burst);
  }

  void _scheduleNext() {
    _timer?.cancel();
    final interval = _currentInterval();
    _timer = Timer(interval, () {
      unawaited(Future.sync(action));
      _scheduleNext();
    });
  }

  Duration _currentInterval() {
    final startedAt = _burstStartedAt;
    if (startedAt == null) {
      _setPhase(SyncCadencePhase.steady);
      return steadyInterval;
    }

    final elapsed = DateTime.now().difference(startedAt);
    if (elapsed < burstDuration) {
      _setPhase(SyncCadencePhase.burst);
      return burstInterval;
    }

    _setPhase(SyncCadencePhase.steady);
    return steadyInterval;
  }

  void _setPhase(SyncCadencePhase phase) {
    if (_currentPhase == phase) return;
    _currentPhase = phase;
    onPhaseChanged(phase);
  }
}
