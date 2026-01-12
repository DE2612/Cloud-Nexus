// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'cloud_node.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class CloudNodeAdapter extends TypeAdapter<CloudNode> {
  @override
  final int typeId = 0;

  @override
  CloudNode read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return CloudNode(
      id: fields[0] as String,
      parentId: fields[1] as String?,
      cloudId: fields[2] as String?,
      accountId: fields[3] as String?,
      name: fields[4] as String,
      isFolder: fields[5] as bool,
      provider: fields[6] as String,
      updatedAt: fields[7] as DateTime,
      size: fields[8] as int,
      sourceAccountId: fields[9] as String?,
    );
  }

  @override
  void write(BinaryWriter writer, CloudNode obj) {
    writer
      ..writeByte(10)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.parentId)
      ..writeByte(2)
      ..write(obj.cloudId)
      ..writeByte(3)
      ..write(obj.accountId)
      ..writeByte(4)
      ..write(obj.name)
      ..writeByte(5)
      ..write(obj.isFolder)
      ..writeByte(6)
      ..write(obj.provider)
      ..writeByte(7)
      ..write(obj.updatedAt)
      ..writeByte(8)
      ..write(obj.size)
      ..writeByte(9)
      ..write(obj.sourceAccountId);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CloudNodeAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
