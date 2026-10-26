import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:json_schema/json_schema.dart';

/// Environment variable that points at the shared RUM event contract
/// (`contracts/rum/events` of the MoleSignal server repository).
const String contractEnvironmentVariable = 'MOLESIGNAL_CONTRACTS';

const String _defaultContractPath = '../molesignal/contracts/rum/events';

/// The contract directory, or `null` when `v1.schema.json` cannot be found.
final Directory? contractDirectory = _findContractDirectory();

/// Why contract validation is unavailable, or `null` when it is available.
///
/// Pass it as `skip:` so a missing checkout is reported instead of passing
/// silently.
final String? contractSkipReason = contractDirectory == null
    ? 'RUM event contract not found. Set $contractEnvironmentVariable to the '
          "server repository's contracts/rum/events directory "
          '(default: $_defaultContractPath relative to the package root).'
    : null;

/// The `$defs` entry that describes the body of each event type.
const Map<String, String> _bodyDefinitions = <String, String>{
  'view': 'viewBody',
  'action': 'actionBody',
  'error': 'errorBody',
  'resource': 'resourceBody',
  'long_task': 'longTaskBody',
  'vital': 'vitalBody',
};

JsonSchema? _schema;

JsonSchema get _eventSchema => _schema ??= JsonSchema.create(
  jsonDecode(
        File('${contractDirectory!.path}/v1.schema.json').readAsStringSync(),
      )
      as Map<String, dynamic>,
);

/// Issues the contract finds in one event, empty when the event is valid.
///
/// Always call this with the decoded request body, not the in-memory event, so
/// the check covers what actually goes over the wire.
List<String> contractIssues(Object? event) {
  if (contractDirectory == null) return const <String>[];
  final ValidationResults results = _eventSchema.validate(event);
  if (results.isValid) return const <String>[];
  final List<String> issues = <String>[
    for (final ValidationError error in results.errors)
      if (!error.message.contains('allOf violated'))
        '${error.instancePath}: ${error.message}',
  ];
  // `allOf` reports only that something inside failed. The typed body is
  // validated on its own to say what.
  if (event is Map<dynamic, dynamic>) {
    final String? definition = _bodyDefinitions[event['type']];
    final Object? body = definition == null ? null : event[event['type']];
    if (definition != null && body != null) {
      final JsonSchema bodySchema = _eventSchema.resolvePath(
        Uri.parse('#/\$defs/$definition'),
      );
      for (final ValidationError error in bodySchema.validate(body).errors) {
        issues.add('${event['type']}${error.instancePath}: ${error.message}');
      }
    }
  }
  return issues.isEmpty
      ? <String>['event does not satisfy the contract: ${jsonEncode(event)}']
      : issues;
}

/// Objects that carry arbitrary keys by design; their members are not checked.
const Set<String> _openObjects = <String>{
  'context',
  'feature_flags',
  'usr',
  'account',
  'error.meta',
};

/// Paths of fields in [event] that the contract does not define.
///
/// A field the schema does not know is accepted and kept, so a misspelled name
/// would pass [contractIssues]; this finds it. Free-form objects (`context`,
/// `feature_flags`, `usr`, `account`, `error.meta`, `view.custom_timings`) are
/// not descended into.
List<String> unknownFields(Object? event) {
  if (contractDirectory == null || event is! Map<dynamic, dynamic>) {
    return const <String>[];
  }
  final Object? type = event['type'];
  final Map<String, dynamic> root = _schemaJson;
  final Map<String, dynamic> tree = _flatten(root);
  // The typed body of this event type replaces the generic `view` reference.
  final Map<String, dynamic> properties = Map<String, dynamic>.of(
    tree['properties'] as Map<String, dynamic>? ?? <String, dynamic>{},
  );
  for (final dynamic branch in root['allOf'] as List<dynamic>? ?? <dynamic>[]) {
    final Map<String, dynamic> map = branch as Map<String, dynamic>;
    final Map<String, dynamic>? condition = map['if'] as Map<String, dynamic>?;
    final Object? expected =
        (condition?['properties'] as Map<String, dynamic>?)?['type'] is Map
        ? ((condition!['properties'] as Map<String, dynamic>)['type']
              as Map<String, dynamic>)['const']
        : null;
    if (expected == type) {
      final Map<String, dynamic> then = map['then'] as Map<String, dynamic>;
      properties.addAll(then['properties'] as Map<String, dynamic>);
    }
  }
  final List<String> unknown = <String>[];
  _compare(event, <String, dynamic>{'properties': properties}, '', unknown);
  return unknown;
}

Map<String, dynamic>? _json;

Map<String, dynamic> get _schemaJson => _json ??=
    jsonDecode(
          File('${contractDirectory!.path}/v1.schema.json').readAsStringSync(),
        )
        as Map<String, dynamic>;

/// A schema with `$ref` and `allOf` merged (conditional `allOf` entries, which
/// only add requirements, are ignored).
Map<String, dynamic> _flatten(Map<String, dynamic> schema) =>
    _flattened.putIfAbsent(schema, () => _flattenSchema(schema));

final Map<Map<String, dynamic>, Map<String, dynamic>> _flattened =
    HashMap<Map<String, dynamic>, Map<String, dynamic>>.identity();

Map<String, dynamic> _flattenSchema(Map<String, dynamic> schema) {
  final Map<String, dynamic> result = <String, dynamic>{};
  void merge(Map<String, dynamic> part) {
    final Map<String, dynamic> flat = _flatten(part);
    final Map<String, dynamic> properties = <String, dynamic>{
      ...?result['properties'] as Map<String, dynamic>?,
      ...?flat['properties'] as Map<String, dynamic>?,
    };
    result.addAll(flat);
    if (properties.isNotEmpty) result['properties'] = properties;
  }

  final Object? reference = schema[r'$ref'];
  if (reference is String) {
    merge(_resolve(reference));
  }
  for (final dynamic part in schema['allOf'] as List<dynamic>? ?? <dynamic>[]) {
    final Map<String, dynamic> map = part as Map<String, dynamic>;
    if (!map.containsKey('if')) merge(map);
  }
  for (final String key in <String>[
    'properties',
    'items',
    'additionalProperties',
    'propertyNames',
  ]) {
    if (!schema.containsKey(key)) continue;
    if (key == 'properties') {
      result['properties'] = <String, dynamic>{
        ...?result['properties'] as Map<String, dynamic>?,
        ...schema['properties'] as Map<String, dynamic>,
      };
    } else {
      result[key] = schema[key];
    }
  }
  return result;
}

Map<String, dynamic> _resolve(String reference) {
  Object? current = _schemaJson;
  for (final String part in reference.substring(2).split('/')) {
    current = (current! as Map<String, dynamic>)[part];
  }
  return current! as Map<String, dynamic>;
}

void _compare(
  Object? value,
  Map<String, dynamic> schema,
  String path,
  List<String> unknown,
) {
  final Map<String, dynamic> flat = _flatten(schema);
  if (value is List<dynamic>) {
    final Object? items = flat['items'];
    if (items is Map<String, dynamic>) {
      for (final dynamic item in value) {
        _compare(item, items, path, unknown);
      }
    }
    return;
  }
  if (value is! Map<dynamic, dynamic>) return;
  final Map<String, dynamic>? properties =
      flat['properties'] as Map<String, dynamic>?;
  // A map with no listed properties (custom_timings, headers) is free-form.
  if (properties == null) return;
  for (final MapEntry<dynamic, dynamic> entry in value.entries) {
    final String key = entry.key as String;
    final String child = path.isEmpty ? key : '$path.$key';
    final Object? known = properties[key];
    if (known == null) {
      unknown.add(child);
    } else if (!_openObjects.contains(child)) {
      _compare(entry.value, known as Map<String, dynamic>, child, unknown);
    }
  }
}

Directory? _findContractDirectory() {
  final String configured =
      Platform.environment[contractEnvironmentVariable]?.trim() ?? '';
  final Directory directory = Directory(
    configured.isEmpty ? _defaultContractPath : configured,
  );
  return File('${directory.path}/v1.schema.json').existsSync()
      ? directory
      : null;
}
