import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_app/src/view_ide/backend_toolchain/bundled_toolchain_candidates.dart';

void main() {
  group('bundledToolchainCandidatePaths', () {
    test('macOS maps beside the app executable into Contents/Helpers', () {
      expect(
        bundledToolchainCandidatePaths(
          'pafio',
          executablePath: '/Applications/Vityo.app/Contents/MacOS/vityo',
          operatingSystem: 'macos',
        ),
        <String>['/Applications/Vityo.app/Contents/Helpers/pafio'],
      );
    });

    test('Windows maps into components with an .exe suffix', () {
      expect(
        bundledToolchainCandidatePaths(
          'pafio',
          executablePath: r'C:\Program Files\Vityo\vityo.exe',
          operatingSystem: 'windows',
        ),
        <String>['C:/Program Files/Vityo/components/pafio.exe'],
      );
    });

    test('Windows keeps an already-present .exe suffix', () {
      expect(
        bundledToolchainCandidatePaths(
          'styio_lspd.exe',
          executablePath: r'C:\Vityo\vityo.exe',
          operatingSystem: 'windows',
        ),
        <String>['C:/Vityo/components/styio_lspd.exe'],
      );
    });

    test('Linux maps into components', () {
      expect(
        bundledToolchainCandidatePaths(
          'styio_lspd',
          executablePath: '/opt/vityo/vityo',
          operatingSystem: 'linux',
        ),
        <String>['/opt/vityo/components/styio_lspd'],
      );
    });

    test('an empty executable path yields no candidates', () {
      expect(
        bundledToolchainCandidatePaths(
          'pafio',
          executablePath: '',
          operatingSystem: 'macos',
        ),
        isEmpty,
      );
    });

    test('an empty component name yields no candidates', () {
      expect(
        bundledToolchainCandidatePaths(
          '',
          executablePath: '/opt/vityo/vityo',
          operatingSystem: 'linux',
        ),
        isEmpty,
      );
    });
  });
}
