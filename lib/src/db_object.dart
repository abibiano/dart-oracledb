/// Oracle Object types and collections.
library;

import 'dart:typed_data';

import 'errors.dart';

/// Oracle Object type descriptor.
///
/// Describes the structure of an Oracle Object type.
class DbObjectType {
  const DbObjectType({
    required this.schema,
    required this.name,
    required this.isCollection,
    required this.attributes,
    this.elementType,
  });

  /// Schema name
  final String schema;

  /// Type name
  final String name;

  /// Whether this is a collection type (VARRAY or nested table)
  final bool isCollection;

  /// Attributes for object types
  final List<DbObjectAttribute> attributes;

  /// Element type for collection types
  final DbObjectType? elementType;

  /// Full type name (SCHEMA.TYPE)
  String get fullName => '$schema.$name';

  /// Get attribute by name
  DbObjectAttribute? getAttribute(String name) {
    for (final attr in attributes) {
      if (attr.name.toUpperCase() == name.toUpperCase()) {
        return attr;
      }
    }
    return null;
  }

  @override
  String toString() => 'DbObjectType($fullName)';
}

/// Attribute of an Oracle Object type.
class DbObjectAttribute {
  const DbObjectAttribute({
    required this.name,
    required this.typeCode,
    this.typeName,
    this.precision,
    this.scale,
    this.maxSize,
    this.objectType,
  });

  /// Attribute name
  final String name;

  /// Oracle type code
  final int typeCode;

  /// Type name (for named types)
  final String? typeName;

  /// Numeric precision
  final int? precision;

  /// Numeric scale
  final int? scale;

  /// Maximum size for strings
  final int? maxSize;

  /// Nested object type (if this attribute is an object)
  final DbObjectType? objectType;

  @override
  String toString() => 'DbObjectAttribute($name: $typeName)';
}

/// Oracle Database Object instance.
///
/// Represents an instance of an Oracle Object type, which can contain
/// attributes or elements (for collections).
///
/// ## Example
///
/// ```dart
/// // Create an object type
/// final addressType = await conn.getType('HR.ADDRESS_TYPE');
///
/// // Create an object instance
/// final address = DbObject(addressType);
/// address['STREET'] = '123 Main St';
/// address['CITY'] = 'San Francisco';
/// address['STATE'] = 'CA';
/// address['ZIP'] = '94102';
///
/// // Use in INSERT
/// await conn.execute(
///   'INSERT INTO employees (name, address) VALUES (:name, :addr)',
///   params: {'name': 'John Doe', 'addr': address},
/// );
/// ```
class DbObject {
  DbObject(this.type) : _values = {};

  /// Object type descriptor
  final DbObjectType type;

  /// Attribute values
  final Map<String, dynamic> _values;

  /// TDS (Type Descriptor Segment) for wire protocol
  Uint8List? tds;

  /// Get attribute value by name.
  dynamic operator [](String name) => _values[name.toUpperCase()];

  /// Set attribute value by name.
  void operator []=(String name, dynamic value) {
    final upperName = name.toUpperCase();
    final attr = type.getAttribute(upperName);
    if (attr == null && !type.isCollection) {
      throw DataTypeError('Attribute $name not found in type ${type.fullName}');
    }
    _values[upperName] = value;
  }

  /// Get all attribute names.
  Iterable<String> get attributeNames => _values.keys;

  /// Get all attribute values.
  Iterable<dynamic> get attributeValues => _values.values;

  /// Check if an attribute exists.
  bool hasAttribute(String name) => _values.containsKey(name.toUpperCase());

  /// Convert to a Map.
  Map<String, dynamic> toMap() => Map.from(_values);

  /// Create from a Map.
  factory DbObject.fromMap(DbObjectType type, Map<String, dynamic> map) {
    final obj = DbObject(type);
    for (final entry in map.entries) {
      obj[entry.key] = entry.value;
    }
    return obj;
  }

  @override
  String toString() => 'DbObject(${type.fullName}, $_values)';
}

/// Oracle collection (VARRAY or nested table).
///
/// ## Example
///
/// ```dart
/// // Create a collection type
/// final numbersType = await conn.getType('HR.NUMBER_ARRAY');
///
/// // Create a collection instance
/// final numbers = DbCollection(numbersType);
/// numbers.addAll([1, 2, 3, 4, 5]);
///
/// // Use in procedure call
/// await conn.executePlSql(
///   'BEGIN process_numbers(:nums); END;',
///   params: {'nums': numbers},
/// );
/// ```
class DbCollection extends DbObject implements Iterable<dynamic> {
  DbCollection(super.type) : _elements = [];

  /// Collection elements
  final List<dynamic> _elements;

  /// Number of elements
  @override
  int get length => _elements.length;

  /// Whether the collection is empty
  @override
  bool get isEmpty => _elements.isEmpty;

  /// Whether the collection has elements
  @override
  bool get isNotEmpty => _elements.isNotEmpty;

  /// Get element at index
  @override
  dynamic elementAt(int index) => _elements[index];

  /// Add an element
  void add(dynamic element) => _elements.add(element);

  /// Add multiple elements
  void addAll(Iterable<dynamic> elements) => _elements.addAll(elements);

  /// Remove an element
  bool remove(dynamic element) => _elements.remove(element);

  /// Remove element at index
  dynamic removeAt(int index) => _elements.removeAt(index);

  /// Clear all elements
  void clear() => _elements.clear();

  /// Get elements as a list
  @override
  List<dynamic> toList({bool growable = true}) =>
      _elements.toList(growable: growable);

  @override
  Iterator<dynamic> get iterator => _elements.iterator;

  @override
  dynamic get first => _elements.first;

  @override
  dynamic get last => _elements.last;

  @override
  dynamic get single => _elements.single;

  @override
  bool any(bool Function(dynamic) test) => _elements.any(test);

  @override
  bool every(bool Function(dynamic) test) => _elements.every(test);

  @override
  bool contains(Object? element) => _elements.contains(element);

  @override
  Iterable<T> cast<T>() => _elements.cast<T>();

  @override
  Iterable<T> expand<T>(Iterable<T> Function(dynamic) toElements) =>
      _elements.expand(toElements);

  @override
  dynamic firstWhere(bool Function(dynamic) test,
          {dynamic Function()? orElse}) =>
      _elements.firstWhere(test, orElse: orElse);

  @override
  T fold<T>(T initialValue, T Function(T, dynamic) combine) =>
      _elements.fold(initialValue, combine);

  @override
  Iterable<dynamic> followedBy(Iterable<dynamic> other) =>
      _elements.followedBy(other);

  @override
  void forEach(void Function(dynamic) action) => _elements.forEach(action);

  @override
  String join([String separator = '']) => _elements.join(separator);

  @override
  dynamic lastWhere(bool Function(dynamic) test,
          {dynamic Function()? orElse}) =>
      _elements.lastWhere(test, orElse: orElse);

  @override
  Iterable<T> map<T>(T Function(dynamic) toElement) => _elements.map(toElement);

  @override
  dynamic reduce(dynamic Function(dynamic, dynamic) combine) =>
      _elements.reduce(combine);

  @override
  dynamic singleWhere(bool Function(dynamic) test,
          {dynamic Function()? orElse}) =>
      _elements.singleWhere(test, orElse: orElse);

  @override
  Iterable<dynamic> skip(int count) => _elements.skip(count);

  @override
  Iterable<dynamic> skipWhile(bool Function(dynamic) test) =>
      _elements.skipWhile(test);

  @override
  Iterable<dynamic> take(int count) => _elements.take(count);

  @override
  Iterable<dynamic> takeWhile(bool Function(dynamic) test) =>
      _elements.takeWhile(test);

  @override
  Set<dynamic> toSet() => _elements.toSet();

  @override
  Iterable<dynamic> where(bool Function(dynamic) test) => _elements.where(test);

  @override
  Iterable<T> whereType<T>() => _elements.whereType<T>();

  @override
  String toString() => 'DbCollection(${type.fullName}, $_elements)';
}
