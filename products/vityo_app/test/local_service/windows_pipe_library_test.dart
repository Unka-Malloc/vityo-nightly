import 'package:test/test.dart';
import 'package:vityo_app/src/ide/local_service/transport/windows_pipe_library.dart';

void main() {
  test('default DLL belongs to the executable directory', () {
    expect(
      windowsPipeLibraryPath(r'C:\Program Files\Vityo\vityo_app.exe'),
      r'C:\Program Files\Vityo\vityo_windows_pipe.dll',
    );
  });

  test('explicit build override is absolute and normalized', () {
    expect(
      windowsPipeLibraryPath(
        r'C:\sdk\dart.exe',
        overridePath: r'D:\build\native\..\Release\vityo_windows_pipe.dll',
      ),
      r'D:\build\Release\vityo_windows_pipe.dll',
    );
  });

  test('no relative, drive-relative, network, device or ADS loading', () {
    for (final path in [
      'vityo_windows_pipe.dll',
      'C:/../vityo_windows_pipe.dll',
      'C:/../../vityo_windows_pipe.dll',
      'C:/bad\u0000/vityo_windows_pipe.dll',
      r'C:vityo_windows_pipe.dll',
      r'\vityo_windows_pipe.dll',
      r'\\server\share\vityo_windows_pipe.dll',
      r'\\?\C:\vityo_windows_pipe.dll',
      r'C:\file:stream\vityo_windows_pipe.dll',
      r'C:\vityo_windows_pipe.dll:stream',
      r'C:\unexpected.dll',
    ]) {
      expect(
        () => windowsPipeLibraryPath(r'C:\sdk\dart.exe', overridePath: path),
        throwsArgumentError,
        reason: path,
      );
    }
    expect(() => windowsPipeLibraryPath('dart.exe'), throwsArgumentError);
  });
}
