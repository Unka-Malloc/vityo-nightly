import 'package:flutter_test/flutter_test.dart';
import 'package:styio_view_app/src/backend_toolchain/execution_adapter.dart'
    as backend;
import 'package:styio_view_app/src/integration/execution_adapter.dart'
    as legacy;

void main() {
  test('legacy integration export forwards to backend toolchain symbols', () {
    backend.ExecutionSessionStatus status =
        legacy.ExecutionSessionStatus.succeeded;

    expect(status, backend.ExecutionSessionStatus.succeeded);
  });
}
