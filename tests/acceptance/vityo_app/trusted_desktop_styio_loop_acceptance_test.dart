import 'dart:convert';
import 'dart:io';

/// Validates the engineering report only. It never launches the product matrix.
Future<void> main(List<String> arguments) async {
  try {
    final manifest =
        jsonDecode(
              await File.fromUri(
                Platform.script.resolve(
                  '../../../toolchain/vityo-product-cases.json',
                ),
              ).readAsString(),
            )
            as Map;
    final expected = Map<String, dynamic>.from(manifest['cases'] as Map);
    if (arguments.isEmpty) {
      // Admission counterexample: a missing mandatory case cannot pass.
      final cases = expected.entries
          .map(
            (entry) => <String, Object?>{
              'schema_version': 2,
              'scenario': manifest['scenario'],
              'evidence_kind': 'real-production-services',
              'case': entry.key,
              'outcome': entry.value,
              'accepted': true,
            },
          )
          .toList();
      validateCases(cases, expected);
      var rejected = false;
      try {
        validateCases(cases.sublist(1), expected);
      } on FormatException {
        rejected = true;
      }
      if (!rejected) throw const FormatException('Missing case was admitted');
    } else {
      final options = <String, String>{};
      for (var index = 0; index < arguments.length; index += 2) {
        if (index + 1 >= arguments.length ||
            !['--report', '--platform'].contains(arguments[index])) {
          throw const FormatException('Expected --report and --platform');
        }
        options[arguments[index]] = arguments[index + 1];
      }
      if (options.length != 2) {
        throw const FormatException('Report and platform required');
      }
      final report =
          jsonDecode(await File(options['--report']!).readAsString()) as Map;
      if (report['gate'] != 'vityo-desktop-product-gate' ||
          report['platform'] != options['--platform'] ||
          report['ok'] != true ||
          report['required'] != true ||
          report['skipped'] != false ||
          report['failure_category'] != null ||
          report['evidence_kind'] != 'real-production-services') {
        throw const FormatException('Product evidence did not pass');
      }
      final body = report['report'] as Map;
      validateCases(body['scenarios'] as List, expected);
      validateContracts(body['contract_cases'] as List);
      if (body['scenario_count'] != expected.length ||
          body['contract_case_count'] != 4) {
        throw const FormatException('Evidence counts mismatch');
      }
    }
    stdout.writeln('trusted-desktop-styio-loop report contract: ok');
  } on Object {
    stderr.writeln('trusted-desktop-styio-loop report contract: invalid');
    exitCode = 1;
  }
}

void validateCases(List cases, Map<String, dynamic> expected) {
  final seen = <String>{};
  for (final item in cases) {
    if (item is! Map ||
        item.length != 6 ||
        item['schema_version'] != 2 ||
        item['scenario'] != 'trusted-desktop-styio-loop' ||
        item['evidence_kind'] != 'real-production-services' ||
        item['accepted'] != true ||
        item['case'] is! String ||
        !expected.containsKey(item['case']) ||
        item['outcome'] != expected[item['case']] ||
        !seen.add(item['case'] as String)) {
      throw const FormatException('Invalid or duplicated case');
    }
  }
  if (seen.length != expected.length) {
    throw const FormatException('Missing mandatory cases');
  }
}

void validateContracts(List reports) {
  const expected = {
    'missing-styio': ('blocked', 'styio_missing'),
    'incompatible-machine-contract': (
      'blocked',
      'styio_machine_contract_incompatible',
    ),
    'compiler-execution-failure': ('failed', 'compiler_execution_failed'),
    'canonical-owner-paths': ('succeeded', 'owner_paths_contained'),
  };
  final seen = <String>{};
  for (final report in reports) {
    if (report is! Map ||
        report.length != 8 ||
        report['schema_version'] != 1 ||
        report['scenario'] != 'trusted-desktop-styio-loop' ||
        report['evidence_kind'] != 'deterministic-contract' ||
        report['accepted'] != true ||
        report['success_observation'] != false ||
        report['case'] is! String ||
        !expected.containsKey(report['case']) ||
        !seen.add(report['case'] as String)) {
      throw const FormatException('Invalid boundary contract');
    }
    final outcome = expected[report['case']]!;
    if (report['outcome'] != outcome.$1 ||
        report['error_category'] != outcome.$2) {
      throw const FormatException('Incorrect boundary outcome');
    }
  }
  if (seen.length != expected.length)
    throw const FormatException('Missing boundary contracts');
}
