import 'dart:async';

import 'runtime_output_channels.dart';

/// Composes the default runtime output producers into one live buffer.
///
/// Producers with a real emission stream are bound through their
/// [RuntimeOutputProducerAdapter]. Producers whose manager exposes no standing
/// stream are recorded as blocked with an explicit reason, so an empty channel
/// stays visibly empty instead of being filled with synthesized events.
class RuntimeOutputProducerBindings {
  RuntimeOutputProducerBindings({
    required RuntimeOutputLiveBuffer buffer,
    RuntimeOutputProducerRegistry? producers,
  }) {
    final registry =
        producers ?? RuntimeOutputProducerRegistry.defaultProducers();
    this.producers = registry;
    _adapters = RuntimeOutputProducerAdapterRegistry.fromProducerRegistry(
      registry,
    );
    _controller = RuntimeOutputProducerBindingController(
      adapters: _adapters,
      buffer: buffer,
    );
  }

  late final RuntimeOutputProducerRegistry producers;
  late final RuntimeOutputProducerAdapterRegistry _adapters;
  late final RuntimeOutputProducerBindingController _controller;

  List<RuntimeOutputProducerBindingState> get bindings => _controller.bindings;

  bool get hasActiveBindings => _controller.hasActiveBindings;

  RuntimeOutputProducerBindingState? bindingFor(String producerId) =>
      _controller.lookup(producerId);

  RuntimeOutputProducerAdapter? adapterFor(String producerId) =>
      _adapters.lookup(producerId);

  RuntimeOutputProducerBindingState bind({
    required String producerId,
    required Stream<RuntimeOutputProducerEmission> emissions,
  }) {
    return _controller.bindProducer(
      producerId: producerId,
      emissions: emissions,
    );
  }

  RuntimeOutputProducerBindingState markUnavailable({
    required String producerId,
    required String reason,
  }) {
    return _controller.markUnavailable(producerId: producerId, reason: reason);
  }

  /// Binds every provided producer stream and records the rest as unavailable.
  ///
  /// [unavailableReasons] must cover every producer that has no stream; the
  /// fallback reason names the producer so a missing entry is still honest.
  void wireAvailable({
    required Map<String, Stream<RuntimeOutputProducerEmission>> emissions,
    required Map<String, String> unavailableReasons,
  }) {
    for (final producer in producers.producers) {
      final stream = emissions[producer.producerId];
      if (stream != null) {
        bind(producerId: producer.producerId, emissions: stream);
        continue;
      }
      markUnavailable(
        producerId: producer.producerId,
        reason:
            unavailableReasons[producer.producerId] ??
            'No runtime output stream is wired for ${producer.producerId} yet.',
      );
    }
  }

  Future<void> dispose() => _controller.dispose();

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'bindingCount': bindings.length,
      'activeBindingCount': bindings.where((binding) => binding.active).length,
      'bindings': bindings
          .map((binding) => binding.toJson())
          .toList(growable: false),
    };
  }
}
