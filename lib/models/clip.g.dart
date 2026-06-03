// Manually written Hive TypeAdapter for Clip.

part of 'clip.dart';

class ClipAdapter extends TypeAdapter<Clip> {
  @override
  final int typeId = 0;

  @override
  Clip read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return Clip(
      id: fields[0] as String,
      name: fields[1] as String,
      filePath: fields[2] as String,
      sourcePath: fields[3] as String,
      sourceName: fields[4] as String,
      startMs: fields[5] as int,
      endMs: fields[6] as int,
      thumbnailPath: fields[7] as String,
      createdAtMs: fields[8] as int,
    );
  }

  @override
  void write(BinaryWriter writer, Clip obj) {
    writer
      ..writeByte(9)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.name)
      ..writeByte(2)
      ..write(obj.filePath)
      ..writeByte(3)
      ..write(obj.sourcePath)
      ..writeByte(4)
      ..write(obj.sourceName)
      ..writeByte(5)
      ..write(obj.startMs)
      ..writeByte(6)
      ..write(obj.endMs)
      ..writeByte(7)
      ..write(obj.thumbnailPath)
      ..writeByte(8)
      ..write(obj.createdAtMs);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ClipAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
