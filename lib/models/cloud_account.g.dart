// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'cloud_account.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class CloudAccountAdapter extends TypeAdapter<CloudAccount> {
  @override
  final int typeId = 1;

  @override
  CloudAccount read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return CloudAccount(
      id: fields[0] as String,
      provider: fields[1] as String,
      name: fields[2] as String,
      email: fields[3] as String,
      accessToken: fields[4] as String?,
      refreshToken: fields[5] as String?,
      tokenExpiry: fields[6] as DateTime?,
      credentials: fields[7] as String?,
      encryptUploads: fields[8] == null ? false : fields[8] as bool,
      orderIndex: fields[9] == null ? 0 : fields[9] as int,
    );
  }

  @override
  void write(BinaryWriter writer, CloudAccount obj) {
    writer
      ..writeByte(10)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.provider)
      ..writeByte(2)
      ..write(obj.name)
      ..writeByte(3)
      ..write(obj.email)
      ..writeByte(4)
      ..write(obj.accessToken)
      ..writeByte(5)
      ..write(obj.refreshToken)
      ..writeByte(6)
      ..write(obj.tokenExpiry)
      ..writeByte(7)
      ..write(obj.credentials)
      ..writeByte(8)
      ..write(obj.encryptUploads)
      ..writeByte(9)
      ..write(obj.orderIndex);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CloudAccountAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
