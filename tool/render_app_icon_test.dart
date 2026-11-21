import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('生成图标资源并检查安全区域及小尺寸', (tester) async {
    final svg = File('assets/branding/app-icon.svg').readAsStringSync();
    expect(svg, isNot(contains('<image')));
    expect(svg, isNot(contains('gradient')));
    tester.view.physicalSize = const Size(1024, 1024);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    await tester.pumpWidget(Directionality(textDirection: TextDirection.ltr, child: RepaintBoundary(key: key, child: SvgPicture.string(svg))));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
    final image = await (key.currentContext!.findRenderObject() as RenderRepaintBoundary).toImage();
    final png = (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
    File('assets/branding/app-icon-foreground.png').writeAsBytesSync(png);
    final recorder = ui.PictureRecorder();
    Canvas(recorder)..drawColor(Colors.white, BlendMode.src)..drawImage(image, Offset.zero, Paint());
    final white = await recorder.endRecording().toImage(1024, 1024);
    File('assets/branding/app-icon.png').writeAsBytesSync((await white.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List());
    for (final entry in {'mdpi':48, 'hdpi':72, 'xhdpi':96, 'xxhdpi':144, 'xxxhdpi':192}.entries) {
      final codec = await ui.instantiateImageCodec((await white.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List(), targetWidth: entry.value);
      final frame = await codec.getNextFrame();
      final file = File('android/app/src/main/res/mipmap-${entry.key}/ic_launcher.png');
      file.writeAsBytesSync((await frame.image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List());
      frame.image.dispose(); codec.dispose();
    }
    final raw = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
    for (var y=0; y<1024; y++) {
      for (var x=0; x<1024; x++) {
        if (raw[(y*1024+x)*4+3] > 0) {
          expect(x, inInclusiveRange(184, 840));
          expect(y, inInclusiveRange(184, 840));
        }
      }
    }
    final sheetRecorder = ui.PictureRecorder();
    final sheet = Canvas(sheetRecorder)..drawColor(const Color(0xffe5e7eb), BlendMode.src);
    for (var i=0; i<4; i++) {
      final size = i==3 ? 48.0 : 180.0;
      final rect = Rect.fromLTWH(20+i*200.0, 20, size, size);
      sheet.save();
      if(i==1) sheet.clipPath(Path()..addOval(rect));
      if(i==2) sheet.clipRRect(RRect.fromRectAndRadius(rect, const Radius.circular(44)));
      sheet.drawRect(rect, Paint()..color=Colors.white);
      sheet.drawImageRect(image, const Rect.fromLTWH(0,0,1024,1024), rect, Paint()..filterQuality=FilterQuality.high);
      sheet.restore();
    }
    final preview=await sheetRecorder.endRecording().toImage(820,220);
    File('assets/branding/app-icon-preview.png').writeAsBytesSync((await preview.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List());
    preview.dispose(); image.dispose(); white.dispose();
    });
    expect(tester.takeException(), isNull);
  });
}
