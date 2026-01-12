// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'search_index.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class SearchIndexEntryAdapter extends TypeAdapter<SearchIndexEntry> {
  @override
  final int typeId = 30;

  @override
  SearchIndexEntry read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return SearchIndexEntry(
      provider: fields[0] as String,
      email: fields[1] as String,
      nodeId: fields[2] as String,
      parentId: fields[3] as String?,
      nodeName: fields[4] as String,
      isFolder: fields[5] as bool,
      cloudId: fields[6] as String?,
      accountId: fields[7] as String?,
      sourceAccountId: fields[8] as String?,
    );
  }

  @override
  void write(BinaryWriter writer, SearchIndexEntry obj) {
    writer
      ..writeByte(9)
      ..writeByte(0)
      ..write(obj.provider)
      ..writeByte(1)
      ..write(obj.email)
      ..writeByte(2)
      ..write(obj.nodeId)
      ..writeByte(3)
      ..write(obj.parentId)
      ..writeByte(4)
      ..write(obj.nodeName)
      ..writeByte(5)
      ..write(obj.isFolder)
      ..writeByte(6)
      ..write(obj.cloudId)
      ..writeByte(7)
      ..write(obj.accountId)
      ..writeByte(8)
      ..write(obj.sourceAccountId);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SearchIndexEntryAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
