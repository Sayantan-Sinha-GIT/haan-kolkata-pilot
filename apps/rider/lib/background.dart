import 'dart:async';
import 'dart:ui';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:geolocator/geolocator.dart';
import 'package:haan_core/haan_core.dart';

Future<void> configureRiderService() async {
  await FlutterBackgroundService().configure(
    androidConfiguration: AndroidConfiguration(
      onStart: riderServiceMain, autoStart: false, autoStartOnBoot: false,
      isForegroundMode: true, foregroundServiceTypes: [AndroidForegroundType.location],
      initialNotificationTitle: 'Haan Rider is online',
      initialNotificationContent: 'Sharing your location for nearby trips',
    ),
    iosConfiguration: IosConfiguration(autoStart: false),
  );
}
Future<void> setRiderService(bool online) async {
  final service = FlutterBackgroundService();
  if (online) { if (!await service.isRunning()) await service.startService(); }
  else { service.invoke('stop'); }
}

@pragma('vm:entry-point')
void riderServiceMain(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();
  final api=HaanApi();await api.load();
  Timer? timer;DateTime lastSent=DateTime.fromMillisecondsSinceEpoch(0);
  final pending=<Map<String,dynamic>>[];
  bool inFlight=false;
  Future<void> tick() async {
    if(inFlight)return;inFlight=true;
    try {
      final permission=await Geolocator.checkPermission();
      if(permission!=LocationPermission.always&&permission!=LocationPermission.whileInUse)return;
      final pos=await Geolocator.getCurrentPosition(locationSettings:const LocationSettings(accuracy:LocationAccuracy.medium,timeLimit:Duration(seconds:5)));
      final interval=pos.speed>1.5?5:15;
      if(DateTime.now().difference(lastSent).inSeconds<interval)return;
      lastSent=DateTime.now();
      final location={'lat':pos.latitude,'lng':pos.longitude,'heading':pos.heading};
      pending.add(location);if(pending.length>12)pending.removeAt(0);
      final active=await api.get('/v1/trips/active');
      final tripId=active['trip']?['id'];
      while(pending.isNotEmpty){
        final next=pending.first;
        await api.post('/v1/rider/heartbeat',next);
        if(tripId!=null)await api.post('/v1/trips/$tripId/location',next);
        pending.removeAt(0);
      }
      if(service is AndroidServiceInstance)service.setForegroundNotificationInfo(title:'Haan Rider is online',content:'Location updated · waiting for nearby trips');
    }catch(_){/* Keep the newest samples and retry on the next tick. */}
    finally{inFlight=false;}
  }
  timer=Timer.periodic(const Duration(seconds:5),(_)=>tick());
  service.on('stop').listen((_){timer?.cancel();service.stopSelf();});
  tick();
}
