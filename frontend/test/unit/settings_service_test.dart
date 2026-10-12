import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SettingsService Unit Tests', () {
    late File tempFile;
    late SettingsService service;

    setUp(() {
      service = SettingsService.instance;
      final tempDir = Directory.systemTemp.createTempSync('settings_test_');
      tempFile = File('${tempDir.path}/test_settings.json');
      service.customSettingsPath = tempFile.path;
    });

    tearDown(() {
      if (tempFile.parent.existsSync()) {
        tempFile.parent.deleteSync(recursive: true);
      }
      service.customSettingsPath = null;
    });

    test('Returns empty set when settings file does not exist', () async {
      expect(tempFile.existsSync(), isFalse);
      final types = await service.loadSelectedTournamentTypeNames();
      expect(types, isEmpty);
    });

    test('Saves and loads selected tournament type names', () async {
      await service.saveSelectedTournamentTypeNames({'smash', 'champions'});
      expect(tempFile.existsSync(), isTrue);

      final loaded = await service.loadSelectedTournamentTypeNames();
      expect(loaded, {'smash', 'champions'});
    });

    test('Overwrites previous settings when updating tournament types', () async {
      await service.saveSelectedTournamentTypeNames({'smash'});
      var loaded = await service.loadSelectedTournamentTypeNames();
      expect(loaded, {'smash'});

      await service.saveSelectedTournamentTypeNames({'contender', 'youthContender'});
      loaded = await service.loadSelectedTournamentTypeNames();
      expect(loaded, {'contender', 'youthContender'});

      await service.saveSelectedTournamentTypeNames({});
      loaded = await service.loadSelectedTournamentTypeNames();
      expect(loaded, isEmpty);
    });

    test('Gracefully handles corrupt or empty file', () async {
      tempFile.writeAsStringSync('invalid-json{{{');
      var loaded = await service.loadSelectedTournamentTypeNames();
      expect(loaded, isEmpty);

      tempFile.writeAsStringSync('');
      loaded = await service.loadSelectedTournamentTypeNames();
      expect(loaded, isEmpty);
    });
  });
}
