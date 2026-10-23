/// Shared local-service operations required by Flow Hero feature consumers.
library;

import '../../ide/local_service/vityod_client.dart';

abstract interface class FlowHeroLocalServiceOwner {
  Future<VityodClient?> client();

  Future<void> dispose();
}
