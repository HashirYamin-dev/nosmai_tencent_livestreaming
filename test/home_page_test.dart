import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tencent_flutter_live/main.dart';

void main() {
  void configurePhoneSize(WidgetTester tester) {
    tester.view.physicalSize = const Size(900, 2100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('dashboard lists six Nosmai categories and Watch Live', (tester) async {
    configurePhoneSize(tester);
    await tester.pumpWidget(const TencentLiveApp());
    expect(find.text('Cloud Filters'), findsOneWidget);
    expect(find.text('Beauty & Makeup'), findsOneWidget);
    expect(find.text('AR Effects'), findsOneWidget);
    expect(find.text('Backgrounds'), findsOneWidget);
    expect(find.text('Color Studio'), findsOneWidget);
    expect(find.text('Interactive Effects'), findsOneWidget);
    expect(find.text('Watch Live'), findsOneWidget);
    expect(find.byKey(const ValueKey('room-id')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('viewer rejects an invalid room number', (tester) async {
    configurePhoneSize(tester);
    await tester.pumpWidget(const TencentLiveApp());
    await tester.enterText(find.byKey(const ValueKey('room-id')), '0');
    await tester.ensureVisible(find.text('Watch Live'));
    await tester.tap(find.text('Watch Live'));
    await tester.pumpAndSettle();
    expect(find.text('Invalid Room ID'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unconfigured Tencent host is prevented from streaming', (tester) async {
    configurePhoneSize(tester);
    await tester.pumpWidget(const TencentLiveApp());
    await tester.ensureVisible(find.text('Tencent Live (without Nosmai)'));
    await tester.tap(find.text('Tencent Live (without Nosmai)'));
    await tester.pumpAndSettle();
    expect(find.text('Tencent setup required'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
