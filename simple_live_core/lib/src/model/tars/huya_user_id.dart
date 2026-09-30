import 'package:tars_dart/tars/codec/tars_displayer.dart';
import 'package:tars_dart/tars/codec/tars_input_stream.dart';
import 'package:tars_dart/tars/codec/tars_output_stream.dart';
import 'package:tars_dart/tars/codec/tars_struct.dart';

class HuyaUserId extends TarsStruct {
  int lUid = 0;
  String sGuid = "";
  String sToken = "";
  String sHuYaUA = "";
  String sCookie = "";
  int iTokenType = 0;
  String sDeviceInfo = "";
  String sQIMEI = "";

  @override
  void readFrom(TarsInputStream input) {
    lUid = input.read(lUid, 0, false);
    sGuid = input.read(sGuid, 1, false);
    sToken = input.read(sToken, 2, false);
    sHuYaUA = input.read(sHuYaUA, 3, false);
    sCookie = input.read(sCookie, 4, false);
    iTokenType = input.read(iTokenType, 5, false);
    sDeviceInfo = input.read(sDeviceInfo, 6, false);
    sQIMEI = input.read(sQIMEI, 7, false);
  }

  @override
  void writeTo(TarsOutputStream os) {
    os.write(lUid, 0);
    os.write(sGuid, 1);
    os.write(sToken, 2);
    os.write(sHuYaUA, 3);
    os.write(sCookie, 4);
    os.write(iTokenType, 5);
    os.write(sDeviceInfo, 6);
    os.write(sQIMEI, 7);
  }

  @override
  Object deepCopy() {
    return HuyaUserId()
      ..lUid = lUid
      ..sGuid = sGuid
      ..sToken = sToken
      ..sHuYaUA = sHuYaUA
      ..sCookie = sCookie
      ..iTokenType = iTokenType
      ..sDeviceInfo = sDeviceInfo
      ..sQIMEI = sQIMEI;
  }

  @override
  void displayAsString(StringBuffer sb, int level) {
    TarsDisplayer ds = TarsDisplayer(sb, level: level);
    ds.DisplayInt(lUid, "lUid");
    ds.DisplayString(sGuid, "sGuid");
    ds.DisplayString(sToken, "sToken");
    ds.DisplayString(sHuYaUA, "sHuYaUA");
    ds.DisplayString(sCookie, "sCookie");
    ds.DisplayInt(iTokenType, "iTokenType");
    ds.DisplayString(sDeviceInfo, "sDeviceInfo");
    ds.DisplayString(sQIMEI, "sQIMEI");
  }
}