import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';
import 'app_state.dart';
import 'api.dart';

const amber=Color(0xffffc21a), mint=Color(0xff38e0a0), ink=Color(0xff0a0907), cream=Color(0xfff4efe4);
ThemeData haanTheme(bool dark, Color accent) {
  final bg=dark?ink:const Color(0xfff5efe0), fg=dark?cream:const Color(0xff17140d);
  final base=ThemeData(useMaterial3:true,brightness:dark?Brightness.dark:Brightness.light,scaffoldBackgroundColor:bg,colorScheme:ColorScheme.fromSeed(seedColor:accent,brightness:dark?Brightness.dark:Brightness.light,surface:bg),fontFamily:GoogleFonts.hind().fontFamily);
  return base.copyWith(textTheme:base.textTheme.apply(bodyColor:fg,displayColor:fg),appBarTheme:AppBarTheme(backgroundColor:bg,foregroundColor:fg,elevation:0,titleTextStyle:GoogleFonts.bigShouldersDisplay(fontSize:30,fontWeight:FontWeight.w700,color:fg)),inputDecorationTheme:InputDecorationTheme(filled:true,fillColor:dark?const Color(0xff191813):Colors.white,border:OutlineInputBorder(borderRadius:BorderRadius.circular(16),borderSide:BorderSide.none),contentPadding:const EdgeInsets.symmetric(horizontal:17,vertical:15)),cardTheme:CardThemeData(color:dark?const Color(0xff171611):Colors.white,elevation:0,shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(20))),filledButtonTheme:FilledButtonThemeData(style:FilledButton.styleFrom(backgroundColor:accent,foregroundColor:ink,minimumSize:const Size.fromHeight(54),textStyle:const TextStyle(fontWeight:FontWeight.w700,fontSize:16),shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(16)))));
}

class HaanHeading extends StatelessWidget { final String text; final Color? accent; const HaanHeading(this.text,{super.key,this.accent}); @override Widget build(BuildContext context)=>Text(text,style:GoogleFonts.bigShouldersDisplay(fontSize:58,height:.92,fontWeight:FontWeight.w700,color:accent??Theme.of(context).colorScheme.onSurface)); }
class HaanButton extends StatelessWidget { final String text; final VoidCallback? onPressed; final IconData? icon; const HaanButton(this.text,{super.key,this.onPressed,this.icon}); @override Widget build(BuildContext context)=>FilledButton(onPressed:onPressed,child:Padding(padding:const EdgeInsets.symmetric(vertical:10),child:Row(mainAxisAlignment:MainAxisAlignment.center,children:[Text(text),if(icon!=null)...[const SizedBox(width:8),Icon(icon)]]))); }
class HaanError extends StatelessWidget { final String message; final VoidCallback? retry; const HaanError(this.message,{super.key,this.retry}); @override Widget build(BuildContext context)=>Card(child:Padding(padding:const EdgeInsets.all(20),child:Column(mainAxisSize:MainAxisSize.min,children:[const Icon(Icons.wifi_off_rounded,size:38),const SizedBox(height:12),Text(message,textAlign:TextAlign.center),if(retry!=null)TextButton(onPressed:retry,child:const Text('Try again'))]))); }
class HaanEmpty extends StatelessWidget {final IconData icon;final String title;final String? subtitle;const HaanEmpty(this.title,{super.key,this.icon=Icons.route_rounded,this.subtitle});@override Widget build(BuildContext context)=>Center(child:Padding(padding:const EdgeInsets.all(30),child:Column(mainAxisSize:MainAxisSize.min,children:[Icon(icon,size:64,color:Theme.of(context).colorScheme.primary),const SizedBox(height:15),Text(title,textAlign:TextAlign.center,style:Theme.of(context).textTheme.titleLarge),if(subtitle!=null)Text(subtitle!,textAlign:TextAlign.center)])));}
List<LatLng> decodePolyline(String encoded) {
  final points=<LatLng>[];
  var index=0, latitude=0, longitude=0;
  int component() {
    var shift=0, result=0, byte=0;
    do {
      if (index>=encoded.length) throw const FormatException('Incomplete route');
      byte=encoded.codeUnitAt(index++)-63;
      result|=(byte&31)<<shift;
      shift+=5;
    } while (byte>=32);
    return (result&1)!=0 ? ~(result>>1) : result>>1;
  }
  while(index<encoded.length) {
    latitude+=component();
    longitude+=component();
    points.add(LatLng(latitude/1e5,longitude/1e5));
  }
  return points;
}
class HaanMap extends StatelessWidget {
  final LatLng center;
  final LatLng? pickup,drop,rider;
  final List<LatLng>? routePoints;
  final ValueChanged<LatLng>? onTap;
  final bool lowData;
  final bool fitRoute;
  const HaanMap({super.key,required this.center,this.pickup,this.drop,this.rider,this.routePoints,this.onTap,this.lowData=false,this.fitRoute=false});
  @override Widget build(BuildContext context){
    final markers=<Marker>[];
    if(pickup!=null)markers.add(Marker(point:pickup!,width:46,height:46,child:const Icon(Icons.trip_origin,color:amber,size:36)));
    if(drop!=null)markers.add(Marker(point:drop!,width:46,height:46,child:const Icon(Icons.location_on,color:Color(0xfffa805d),size:40)));
    if(rider!=null)markers.add(Marker(point:rider!,width:50,height:50,child:const Icon(Icons.two_wheeler,color:mint,size:38)));
    final line=routePoints!=null&&routePoints!.length>=2 ? routePoints! : pickup!=null&&drop!=null ? [pickup!,drop!] : <LatLng>[];
    final mapKey='${center.latitude.toStringAsFixed(5)},${center.longitude.toStringAsFixed(5)}:${fitRoute ? '${drop?.latitude},${drop?.longitude}' : ''}';
    return FlutterMap(key:ValueKey(mapKey),options:MapOptions(initialCenter:center,initialZoom:13,
      initialCameraFit:fitRoute&&line.length>=2 ? CameraFit.coordinates(coordinates:line,
        padding:EdgeInsets.fromLTRB(30,105,30,MediaQuery.sizeOf(context).height*.60),maxZoom:14) : null,
      onTap:onTap==null?null:(_,p)=>onTap!(p)),children:[TileLayer(urlTemplate:'https://tile.openstreetmap.org/{z}/{x}/{y}.png',userAgentPackageName:'in.haan.${lowData?'rider':'customer'}',maxNativeZoom:19),if(line.length>=2)PolylineLayer(polylines:[Polyline(points:line,strokeWidth:5,color:Theme.of(context).colorScheme.primary)]),MarkerLayer(markers:markers),const RichAttributionWidget(attributions:[TextSourceAttribution('© OpenStreetMap contributors')])]);
  }
}
Future<Position?> currentPosition() async {
  if(!await Geolocator.isLocationServiceEnabled())return null;
  var permission=await Geolocator.checkPermission();
  if(permission==LocationPermission.denied)permission=await Geolocator.requestPermission();
  if(permission==LocationPermission.denied||permission==LocationPermission.deniedForever)return null;
  try{return await Geolocator.getCurrentPosition(locationSettings:const LocationSettings(accuracy:LocationAccuracy.high,timeLimit:Duration(seconds:9)));}catch(_){return null;}
}
void showMessage(BuildContext context,String message){ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(message),behavior:SnackBarBehavior.floating));}
class UpdateRequired extends StatelessWidget{final HaanState app;const UpdateRequired(this.app,{super.key});@override Widget build(BuildContext context)=>Scaffold(body:SafeArea(child:Padding(padding:const EdgeInsets.all(28),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[const Spacer(),const Icon(Icons.system_update_alt,size:64,color:amber),const SizedBox(height:24),HaanHeading(app.tr('update')),const SizedBox(height:20),Text(app.tr('updateBody')),const SizedBox(height:25),HaanButton(app.tr('update'),onPressed:downloadBaseUrl.isEmpty?null:()=>launchUrl(Uri.parse(downloadBaseUrl),mode:LaunchMode.externalApplication)),const Spacer()]))));}
Future<void> showPreferences(BuildContext context,HaanState app) async {
  await showModalBottomSheet<void>(
    context:context,
    isScrollControlled:true,
    showDragHandle:true,
    builder:(context)=>SafeArea(
      child:Padding(
        padding:const EdgeInsets.all(22),
        child:Column(
          mainAxisSize:MainAxisSize.min,
          crossAxisAlignment:CrossAxisAlignment.start,
          children:[
            Text(app.tr('language'),style:Theme.of(context).textTheme.headlineSmall),
            SegmentedButton<String>(
              segments:const [
                ButtonSegment(value:'en',label:Text('English')),
                ButtonSegment(value:'hi',label:Text('हिन्दी')),
              ],
              selected:{app.language},
              onSelectionChanged:(v)=>app.setLanguage(v.first),
            ),
            const SizedBox(height:20),
            Text(app.tr('theme'),style:Theme.of(context).textTheme.headlineSmall),
            SegmentedButton<ThemeMode>(
              segments:[
                ButtonSegment(value:ThemeMode.dark,label:Text(app.tr('dark'))),
                ButtonSegment(value:ThemeMode.light,label:Text(app.tr('light'))),
                ButtonSegment(value:ThemeMode.system,label:Text(app.tr('system'))),
              ],
              selected:{app.themeMode},
              onSelectionChanged:(v)=>app.setTheme(v.first),
            ),
            const SizedBox(height:20),
          ],
        ),
      ),
    ),
  );
}
