import 'package:hive/hive.dart';

part 'history.g.dart';

@HiveType(typeId: 2)
class History {
  History({
    required this.id,
    required this.roomId,
    required this.siteId,
    required this.userName,
    required this.face,
    required this.updateTime,
    this.visitCount,
  });

  ///id=siteId_roomId
  @HiveField(0)
  String id;

  @HiveField(1)
  String roomId;

  @HiveField(2)
  String siteId;

  @HiveField(3)
  String userName;

  @HiveField(4)
  String face;

  @HiveField(5)
  DateTime updateTime;

  /// 累计访问次数，「按观看喜好排序」的主要依据。
  /// 声明为可空以兼容旧数据：老库记录没有该字段，Hive 读出来是 null，
  /// 若非空 int，字段强转会抛异常导致历史与关注列表全部读取失败。
  @HiveField(6)
  int? visitCount;

  factory History.fromJson(Map<String, dynamic> json) => History(
        id: json["id"],
        roomId: json["roomId"],
        siteId: json["siteId"],
        userName: json["userName"],
        face: json["face"],
        updateTime: DateTime.parse(json["updateTime"]),
        // 旧备份包与局域网同步过来的 JSON 没有该键，兼容为 0
        visitCount: json["visitCount"] ?? 0,
      );

  Map<String, dynamic> toJson() => {
        "id": id,
        "roomId": roomId,
        "siteId": siteId,
        "userName": userName,
        "face": face,
        "updateTime": updateTime.toString(),
        "visitCount": visitCount ?? 0,
      };
}
