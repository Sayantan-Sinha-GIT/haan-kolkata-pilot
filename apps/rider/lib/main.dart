import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image_picker/image_picker.dart';
import 'package:latlong2/latlong.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:vibration/vibration.dart';
import 'package:haan_core/haan_core.dart';
import 'background.dart';

final app = HaanState(role: 'rider');
final incomingOffer = ValueNotifier<bool>(false);
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await configureRiderService();
  runApp(const HaanRider());
  app.init();
}

class HaanRider extends StatelessWidget {
  const HaanRider({super.key});
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: app,
      builder: (_, __) => MaterialApp(
          title: 'Haan Rider',
          debugShowCheckedModeBanner: false,
          theme: haanTheme(false, mint),
          darkTheme: haanTheme(true, mint),
          themeMode: app.themeMode,
          home: !app.ready
              ? const Scaffold(body: Center(child: CircularProgressIndicator()))
              : app.updateRequired
                  ? UpdateRequired(app)
              : app.signedIn
                  ? RiderShell()
                  : RiderSignIn()));
}

class RiderSignIn extends StatefulWidget {
  const RiderSignIn({super.key});
  @override
  State<RiderSignIn> createState() => _RiderSignInState();
}

class _RiderSignInState extends State<RiderSignIn> {
  final email = TextEditingController(), code = TextEditingController();
  bool sent = false, busy = false;
  String? error;
  @override
  void dispose() {
    email.dispose();
    code.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (!sent) {
        await app.api.post('/v1/auth/request-otp',
            {'email': email.text.trim(), 'role': 'rider'});
        setState(() => sent = true);
      } else {
        await app.login(email.text.trim(), code.text.trim(), 'rider');
      }
    } catch (e) {
      setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> googleSubmit() async {
    setState(() {busy=true;error=null;});
    try { await app.googleLogin(); }
    on ApiException catch(e){if(mounted)setState(()=>error=e.message);}
    catch(_){if(mounted)setState(()=>error=app.language=='hi'
        ? 'Google से साइन इन नहीं हो सका। ईमेल कोड आज़माएँ।'
        : 'Google sign-in could not finish. Try the email code.');}
    finally{if(mounted)setState(()=>busy=false);}
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      body: SafeArea(
          child: Padding(
              padding: const EdgeInsets.all(26),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Spacer(),
                    const Icon(Icons.two_wheeler, color: mint, size: 48),
                    const SizedBox(height: 20),
                    HaanHeading(app.tr('welcome')),
                    const SizedBox(height: 30),
                    TextField(
                        controller: sent ? code : email,
                        keyboardType: sent
                            ? TextInputType.number
                            : TextInputType.emailAddress,
                        maxLength: sent ? 6 : null,
                        decoration: InputDecoration(
                            labelText:
                                sent ? app.tr('code') : app.tr('email'))),
                    if (error != null)
                      Text(error!,
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.error)),
                    const SizedBox(height: 15),
                    HaanButton(
                        busy
                            ? '…'
                            : sent
                                ? app.tr('verify')
                                : app.tr('sendCode'),
                        onPressed: busy ? null : submit),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                        onPressed: busy ? null : googleSubmit,
                        icon: const Icon(Icons.account_circle_outlined),
                        label: Text(app.language=='hi'?'Google से आगे बढ़ें':'Continue with Google')),
                    if (sent)
                      TextButton(
                          onPressed: busy
                              ? null
                              : () {
                                  setState(() => sent = false);
                                  submit();
                                },
                          child: Text(app.tr('resend'))),
                    const Spacer(),
                    TextButton(
                        onPressed: () => showPreferences(context, app),
                        child: Text(app.tr('settings')))
                  ]))));
}

class RiderShell extends StatefulWidget {
  const RiderShell({super.key});
  @override
  State<RiderShell> createState() => _RiderShellState();
}

class _RiderShellState extends State<RiderShell> {
  int tab = 0;
  final earningsKey = GlobalKey<_RiderEarningsState>();
  final historyKey = GlobalKey<_RiderHistoryState>();
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
      valueListenable: incomingOffer,
      builder: (context, offering, _) => Scaffold(
      body: IndexedStack(index: offering ? 0 : tab, children: [
        RiderHome(),
        RiderEarnings(key: earningsKey),
        RiderHistory(key: historyKey),
        RiderAccount()
      ]),
      bottomNavigationBar: offering ? null : NavigationBar(
          selectedIndex: tab,
          onDestinationSelected: (v) {
            setState(() => tab = v);
            if (v == 1) earningsKey.currentState?.load();
            if (v == 2) historyKey.currentState?.load();
          },
          destinations: [
            NavigationDestination(
                icon: const Icon(Icons.two_wheeler), label: app.tr('home')),
            NavigationDestination(
                icon: const Icon(Icons.currency_rupee),
                label: app.tr('earnings')),
            NavigationDestination(
                icon: const Icon(Icons.receipt_long), label: app.tr('history')),
            NavigationDestination(
                icon: const Icon(Icons.person), label: app.tr('profile'))
          ])));
}

const kolkata = LatLng(22.5726, 88.3639);

class RiderHome extends StatefulWidget {
  const RiderHome({super.key});
  @override
  State<RiderHome> createState() => _RiderHomeState();
}

class _RiderHomeState extends State<RiderHome> {
  Map<String, dynamic>? riderProfile, trip;
  List<LatLng>? routePoints;
  String? routeKey;
  List<dynamic> offers = [];
  LatLng center = kolkata;
  bool online = false, busy = false, lowData = false;
  String? error;
  Timer? poll, heartbeat, countdown;
  DateTime? offerExpiry;
  int remaining = 15;
  int cancellationsRemaining=3;
  DateTime? cancellationsCheckedAt;
  @override
  void initState() {
    super.initState();
    refresh();
    poll = Timer.periodic(
        const Duration(seconds: 3), (_) => refresh(silent: true));
    heartbeat =
        Timer.periodic(const Duration(seconds: 15), (_) => sendLocation());
    countdown = Timer.periodic(const Duration(seconds: 1), (_) {
      if (offerExpiry == null || !mounted) return;
      final next = offerExpiry!.difference(DateTime.now()).inSeconds.clamp(0,15);
      if (next != remaining) setState(() => remaining = next);
    });
  }

  @override
  void dispose() {
    poll?.cancel();
    heartbeat?.cancel();
    countdown?.cancel();
    incomingOffer.value = false;
    super.dispose();
  }

  Future<void> refresh({bool silent = false}) async {
    try {
      final profileData = await app.api.get('/v1/rider/profile');
      final p = profileData['profile'];
      final active = await app.api.get('/v1/trips/active');
      Map<String, dynamic>? t;
      if (active['trip'] != null) {
        final d = await app.api.get('/v1/trips/${active['trip']['id']}');
        t = Map<String, dynamic>.from(d['trip']);
      }
      var freshRoute=routePoints;
      if (t == null) { routeKey=null; freshRoute=null; }
      else {
        final nextKey='${t['id']}:${t['status']=='in_progress'?'drop':'pickup'}:${t['next_stop_index']??0}';
        if (routeKey != nextKey) {
          routeKey=nextKey;
          final pos=await currentPosition();
          if (pos!=null) {
            center=LatLng(pos.latitude,pos.longitude);
            final stops=t['stops'] is List?t['stops'] as List:[];
            final nextIndex=(t['next_stop_index'] as num?)?.toInt()??0;
            final nextStop=t['status']=='in_progress'&&nextIndex<stops.length?stops[nextIndex]:null;
            final target=t['status']=='in_progress'
              ? nextStop==null?LatLng((t['drop_lat'] as num).toDouble(),(t['drop_lng'] as num).toDouble())
                :LatLng((nextStop['lat'] as num).toDouble(),(nextStop['lng'] as num).toDouble())
              : LatLng((t['pickup_lat'] as num).toDouble(),(t['pickup_lng'] as num).toDouble());
            freshRoute=[center,target];
            try {
              final nav=await app.api.get('/v1/trips/${t['id']}/route?lat=${pos.latitude}&lng=${pos.longitude}');
              if (nav['polyline'] is String) freshRoute=decodePolyline(nav['polyline']);
            } catch (_) { /* Keep the direct route line. */ }
          }
        }
      }
      final od = await app.api.get('/v1/rider/offers');
      int? cancelRemaining;
      if(cancellationsCheckedAt==null||DateTime.now().difference(cancellationsCheckedAt!)>const Duration(seconds:30)){
        try{final d=await app.api.get('/v1/rider/cancellations');cancelRemaining=(d['remaining'] as num).toInt();
          cancellationsCheckedAt=DateTime.now();}catch(_){/* Server still enforces the limit. */}
      }
      if (!mounted) return;
      final fresh = od['offers'] as List;
      if (fresh.isNotEmpty && offers.isEmpty) {
        Vibration.vibrate(duration: 350);
        SystemSound.play(SystemSoundType.alert);
      }
      final wasOnline = online;
      incomingOffer.value = fresh.isNotEmpty && t == null;
      setState(() {
        riderProfile = p == null ? null : Map<String, dynamic>.from(p);
        online = p?['is_online'] == true;
        trip = t;
        routePoints = freshRoute;
        offers = fresh;
        if(cancelRemaining!=null)cancellationsRemaining=cancelRemaining;
        offerExpiry = fresh.isNotEmpty ? DateTime.parse('${fresh.first['expires_at']}') : null;
        if (offerExpiry != null)
          remaining = offerExpiry!
              .difference(DateTime.now())
              .inSeconds
              .clamp(0, 15);
        error = null;
      });
      if (wasOnline != online) await setRiderService(online);
    } catch (e) {
      if (!silent && mounted) setState(() => error = '$e');
    }
  }

  Future<void> goOnline() async {
    setState(() => busy = true);
    try {
      final pos = online ? null : await currentPosition();
      if (!online && pos == null) {
        showMessage(context, app.tr('gpsOff'));
        return;
      }
      final d = await app.api.post('/v1/rider/online',
          {'online': !online, 'lat': pos?.latitude, 'lng': pos?.longitude});
      setState(() => online = d['online'] == true);
      await setRiderService(online);
      if (pos != null) center = LatLng(pos.latitude, pos.longitude);
    } catch (e) {
      if (mounted) showMessage(context, '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> sendLocation() async {
    if (!online && trip == null) return;
    final p = await currentPosition();
    if (p == null) return;
    center = LatLng(p.latitude, p.longitude);
    try {
      if (online)
        await app.api.post(
            '/v1/rider/heartbeat', {'lat': p.latitude, 'lng': p.longitude});
      if (trip != null)
        await app.api.post('/v1/trips/${trip!['id']}/location',
            {'lat': p.latitude, 'lng': p.longitude, 'heading': p.heading});
    } catch (_) {/* next heartbeat retries */}
  }

  Future<void> offerAction(bool accept) async {
    if (offers.isEmpty) return;
    final o = offers.first;
    setState(() => busy = true);
    try {
      await app.api.post(
          '/v1/rider/offers/${o['id']}/${accept ? 'accept' : 'decline'}', {});
      await refresh();
    } catch (e) {
      if (mounted) showMessage(context, '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> tripAction(String action,
      {Map<String, dynamic> body = const {}}) async {
    if (trip == null) return;
    setState(() => busy = true);
    try {
      await app.api.post('/v1/trips/${trip!['id']}/$action', body);
      if(action=='cancel')cancellationsCheckedAt=null;
      await refresh();
    } catch (e) {
      if (mounted) showMessage(context, '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> startWithPin() async {
    final ctl = TextEditingController();
    final pin = await showDialog<String>(
        context: context,
        builder: (c) => AlertDialog(
                title: Text(app.language == 'hi'
                    ? 'ग्राहक से बोर्डिंग PIN पूछें'
                    : 'Ask customer for boarding PIN'),
                content: TextField(
                    controller: ctl,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    maxLength: 4,
                    autofocus: true,
                    decoration: const InputDecoration(hintText: '0000')),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(c),
                      child: Text(app.tr('no'))),
                  FilledButton(
                      onPressed: () => Navigator.pop(c, ctl.text),
                      child: Text(app.tr('start')))
                ]));
    if (pin != null && RegExp(r'^\d{4}$').hasMatch(pin)) {
      tripAction('start', body: {'pin': pin});
    } else if (pin != null && mounted) {
      showMessage(context, app.language == 'hi' ? 'ग्राहक से 4 अंकों का PIN पूछें।' : 'Ask the customer for the 4-digit PIN.');
    }
  }

  Future<void> navigate(bool toPickup) async {
    if (trip == null) return;
    final stops=trip!['stops'] is List?trip!['stops'] as List:[];
    final nextIndex=(trip!['next_stop_index'] as num?)?.toInt()??0;
    final nextStop=!toPickup&&nextIndex<stops.length?stops[nextIndex]:null;
    final lat = nextStop?['lat']??trip![toPickup ? 'pickup_lat' : 'drop_lat'],
        lng = nextStop?['lng']??trip![toPickup ? 'pickup_lng' : 'drop_lng'];
    final uri = googleMapsDirections(
        lat: (lat as num).toDouble(),
        lng: (lng as num).toDouble(),
        bike: trip!['vehicle_type'] == 'Bike');
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication) && mounted)
      showMessage(context, app.language == 'hi' ? 'Google Maps नहीं खुला। ऐप में रास्ता देखें।' : 'Could not open Google Maps. Follow the in-app map.');
  }

  Future<void> shareTrip() async {
    if(trip==null)return;
    try {
      final result=await app.api.get('/v1/trips/${trip!['id']}/share');
      final url='${result['url']}';
      final sms=Uri(scheme:'sms',queryParameters:{'body':'Haan live trip: $url'});
      if(!await launchUrl(sms,mode:LaunchMode.externalApplication)) {
        await Clipboard.setData(ClipboardData(text:url));
        if(mounted)showMessage(context,app.language=='hi'?'ट्रिप लिंक कॉपी हुआ।':'Trip link copied.');
      }
    } catch(e) {if(mounted)showMessage(context,'$e');}
  }

  Future<void> chooseDestinationFilter() async {
    final selected=await showModalBottomSheet<Map<String,dynamic>>(
      context:context,isScrollControlled:true,useSafeArea:true,showDragHandle:true,
      builder:(_)=>const RiderDestinationPicker());
    if(selected==null||!mounted)return;
    try{
      await app.api.patch('/v1/rider/destination-filter',{
        'destination':selected['clear']==true?null:selected,
      });
      await refresh();
      if(mounted)showMessage(context,selected['clear']==true?'Destination filter cleared.':'Trips will move toward ${selected['text']}.');
    }catch(e){if(mounted)showMessage(context,'$e');}
  }

  @override
  Widget build(BuildContext context) {
    final verified = riderProfile?['verification_status'] == 'approved' &&
        riderProfile?['registration_complete'] == true;
    if (verified && trip == null && offers.isNotEmpty) {
      return Container(
          decoration: const BoxDecoration(gradient: LinearGradient(
              begin: Alignment.topLeft, end: Alignment.bottomRight,
              colors: [Color(0xff10251f), Color(0xff07100d)])),
          child: SafeArea(child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Icon(Icons.two_wheeler, color: mint, size: 48),
                const SizedBox(height: 30),
                Text('NEW RIDE · KOLKATA', style: Theme.of(context).textTheme.labelLarge?.copyWith(color: mint)),
                const Spacer(),
                _offerPanel(),
                const Spacer(),
                LinearProgressIndicator(value: remaining / 15, color: mint),
                const SizedBox(height: 10),
                Text('Offer closes automatically in $remaining seconds.'),
              ]))));
    }
    return Stack(children: [
      Positioned.fill(
          child: HaanMap(
              center: center,
              lowData: lowData,
              pickup: trip == null
                  ? null
                  : LatLng((trip!['pickup_lat'] as num).toDouble(),
                      (trip!['pickup_lng'] as num).toDouble()),
              drop: trip == null
                  ? null
                  : LatLng((trip!['drop_lat'] as num).toDouble(),
                      (trip!['drop_lng'] as num).toDouble()),
              rider: trip == null ? null : center,
              routePoints: routePoints)),
      Positioned(
          top: MediaQuery.paddingOf(context).top + 12,
          left: 16,
          right: 16,
          child: Card(
              child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(children: [
                    const Icon(Icons.two_wheeler, color: mint),
                    const SizedBox(width: 10),
                    Text('HAAN / RIDER',
                        style: Theme.of(context).textTheme.titleLarge),
                    const Spacer(),
                    const CircleAvatar(radius: 5, backgroundColor: mint),
                    const SizedBox(width: 5),
                    Text(online ? 'LIVE' : 'OFF')
                  ])))),
      Align(
          alignment: Alignment.bottomCenter,
          child: Container(
              decoration: BoxDecoration(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(28))),
              constraints: const BoxConstraints(maxHeight: 550),
              child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(22, 14, 22, 28),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (error != null) HaanError(error!, retry: refresh),
                        if (trip != null)
                          _tripPanel()
                        else if (riderProfile == null || !verified)
                          _approvalPanel()
                        else if (offers.isNotEmpty)
                          _offerPanel()
                        else
                          _onlinePanel()
                      ]))))
    ]);
  }

  Widget _approvalPanel() =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        HaanHeading(app.tr('approval')),
        const SizedBox(height: 12),
        Text(
            riderProfile == null
                ? 'Add your vehicle and documents.'
                : app.tr('${riderProfile!['verification_status']}'),
            style: Theme.of(context).textTheme.titleLarge),
        if (riderProfile?['verification_status'] == 'approved' &&
            riderProfile?['registration_complete'] != true)
          Text(app.language == 'hi'
              ? 'गाड़ी या दस्तावेज़ की जानकारी अधूरी या समाप्त है। अपडेट करके फिर जमा करें।'
              : 'Vehicle or document details are incomplete or expired. Update them for review.'),
        if (riderProfile?['rejection_reason'] != null)
          Text('${riderProfile!['rejection_reason']}',
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
        const SizedBox(height: 18),
        HaanButton(app.tr('documents'),
            onPressed: () => Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const Onboarding()))
                .then((_) => refresh()))
      ]);
  Widget _onlinePanel() =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        HaanHeading(online ? 'On the road.' : 'Ready to ride?'),
        const SizedBox(height: 12),
        Text(online
            ? app.tr('noOffers')
            : 'Switch on to receive nearby requests.'),
        const SizedBox(height: 18),
        HaanButton(
            busy
                ? '…'
                : online
                    ? app.tr('offlineRider')
                    : app.tr('online'),
            onPressed: busy ? null : goOnline),
        SwitchListTile(
            title: Text(app.tr('lowData')),
            value: lowData,
            onChanged: (v) => setState(() => lowData = v)),
        const SizedBox(height:8),
        OutlinedButton.icon(onPressed:chooseDestinationFilter,
          icon:const Icon(Icons.route),
          label:Text('${app.language=='hi'?'घर की ओर यात्राएँ':'Trips toward'}: ${riderProfile?['destination_filter_text']??(app.language=='hi'?'कोई फ़िल्टर नहीं':'anywhere')}')),
        if(riderProfile?['destination_filter_text']!=null)
          Text(app.language=='hi'?'केवल उस दिशा में जाने वाली राइड मिलेंगी।':'Offers are filtered to trips moving toward this destination.'),
      ]);
  Widget _offerPanel() {
    final o = offers.first;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: HaanHeading(app.tr('offer'), accent: mint)),
        Text('${remaining}s', style: Theme.of(context).textTheme.displaySmall)
      ]),
      const SizedBox(height: 12),
      Text('${o['pickup_text']} → ${o['drop_text']}',
          style: Theme.of(context).textTheme.titleLarge),
      if(o['service_mode']=='shared_preview')
        Text('Shared preview · no co-rider matching yet'),
      if(o['service_mode']=='intercity')Text('One-way intercity Cab'),
      if(o['stops'] is List&&(o['stops'] as List).isNotEmpty)
        Text('Stops: ${(o['stops'] as List).map((s)=>s['text']).join(' → ')}'),
      if('${o['guest_name']??''}'.isNotEmpty)Text('Passenger: ${o['guest_name']}'),
      if (o['pickup_distance_km'] != null)
        Text('${app.language == 'hi' ? 'पिकअप' : 'Pickup'}: ~${o['pickup_distance_km']} km ${app.language == 'hi' ? 'दूर' : 'away'}'),
      const SizedBox(height: 10),
      Text('${o['estimated_km']} km  ·  ₹${o['estimate_rupees']}',
          style: Theme.of(context).textTheme.headlineMedium),
      Text(app.language=='hi'
        ? 'अनुमानित आपकी कमाई ₹${((o['estimate_rupees'] as num).toInt()*0.8).round()} · Haan 20% रखता है'
        : 'Estimated earnings ₹${((o['estimate_rupees'] as num).toInt()*0.8).round()} · Haan keeps 20%'),
      const SizedBox(height: 16),
      Row(children: [
        Expanded(
            child: OutlinedButton(
                onPressed: busy ? null : () => offerAction(false),
                child: Text(app.tr('decline')))),
        const SizedBox(width: 12),
        Expanded(
            child: FilledButton(
                onPressed: busy || remaining == 0 ? null : () => offerAction(true),
                child: Text(app.tr('accept'))))
      ])
    ]);
  }

  Widget _tripPanel() {
    final status = '${trip!['status']}';
    final stops=trip!['stops'] is List?trip!['stops'] as List:[];
    final nextStopIndex=(trip!['next_stop_index'] as num?)?.toInt()??0;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      HaanHeading(
          app.tr(switch (status) {
            'accepted' => 'riderAssigned',
            'arrived' => 'arrived',
            'in_progress' => 'inProgress',
            _ => 'status'
          }),
          accent: mint),
      const SizedBox(height: 15),
      Text('${trip!['pickup_text']} → ${trip!['drop_text']}',
          style: Theme.of(context).textTheme.titleLarge),
      if ('${trip!['customer_name'] ?? ''}'.isNotEmpty)
        Text('${app.language == 'hi' ? 'ग्राहक' : 'Customer'}: ${trip!['customer_name']}'),
      if('${trip!['guest_name']??''}'.isNotEmpty)
        Text('${app.language=='hi'?'यात्री':'Passenger'}: ${trip!['guest_name']} · ${trip!['guest_phone']??''}'),
      if(trip!['service_mode']=='shared_preview')Text('Shared preview · no co-rider matching'),
      if(trip!['service_mode']=='intercity')Text('One-way intercity ride'),
      if(stops.isNotEmpty)Text('Stops: ${stops.map((s)=>s['text']).join(' → ')}'),
      if ('${trip!['pickup_note'] ?? ''}'.isNotEmpty)
        Card(child: Padding(padding: const EdgeInsets.all(12),
          child: Text('${app.tr('pickupNote')}: ${trip!['pickup_note']}'))),
      if(status!='in_progress')
        Text(trip!['vehicle_type']=='Bike'
          ? (app.language=='hi'?'ग्राहक को यात्री हेलमेट दें, फिर PIN माँगें।':'Provide the passenger helmet before asking for the PIN.')
          : (app.language=='hi'?'ग्राहक को सीट बेल्ट लगाने को कहें।':'Remind the customer to fasten their seat belt.')),
      const SizedBox(height: 6),
      Text('${trip!['vehicle_type']} · ₹${trip!['estimate_rupees']}',
          style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 14),
      HaanButton(status == 'in_progress'&&nextStopIndex<stops.length
          ? '${app.language=='hi'?'अगले स्टॉप जाएँ':'Google Maps to next stop'}: ${stops[nextStopIndex]['text']}'
          : status == 'in_progress' ? app.tr('navigateDrop') : app.tr('navigatePickup'),
          onPressed: () => navigate(status != 'in_progress')),
      const SizedBox(height: 10),
      if (status == 'accepted')
        OutlinedButton.icon(onPressed: busy ? null : () => tripAction('arrived'),
          icon: const Icon(Icons.flag), label: Text(app.tr('arrived'))),
      if (status == 'arrived')
        OutlinedButton.icon(onPressed: busy ? null : startWithPin,
          icon: const Icon(Icons.pin), label: Text(app.tr('askPin'))),
      if (status == 'arrived') ...[
        Text(() {
          final at=DateTime.tryParse('${trip!['arrived_at']??''}');
          final minutes=at==null?0:DateTime.now().difference(at).inMinutes.clamp(0,999);
          return app.language=='hi'
            ? 'पिकअप पर $minutes मिनट से इंतज़ार। 5 मिनट बाद नो-शो चुन सकते हैं।'
            : 'Waiting at pickup for $minutes min. No-show is available after 5 min.';
        }()),
        if (DateTime.tryParse('${trip!['arrived_at']??''}')
          ?.isBefore(DateTime.now().subtract(const Duration(minutes:5)))??false)
          TextButton.icon(onPressed:busy?null:()=>tripAction('no-show'),
            icon:const Icon(Icons.person_off),
            label:Text(app.language=='hi'?'ग्राहक नहीं आए':'Customer did not arrive')),
      ],
      if (status == 'in_progress')
        if(nextStopIndex<stops.length)
          OutlinedButton.icon(onPressed:busy?null:()=>tripAction('stops/arrive'),
            icon:const Icon(Icons.flag_circle),
            label:Text('${app.language=='hi'?'स्टॉप पूरा':'Mark stop reached'} · ${nextStopIndex+1}/${stops.length}'))
        else OutlinedButton.icon(onPressed: busy ? null : () => tripAction('complete'),
          icon: const Icon(Icons.check_circle), label: Text(app.tr('end'))),
      if ('${trip!['customer_phone'] ?? ''}'.isNotEmpty)
        TextButton.icon(
          onPressed: () => launchUrl(Uri(scheme: 'tel', path: '${trip!['customer_phone']}'), mode: LaunchMode.externalApplication),
          icon: const Icon(Icons.call), label: Text(app.tr('contact'))),
      Wrap(spacing:8,children:[
        TextButton.icon(onPressed:()=>launchUrl(Uri.parse('tel:112'),mode:LaunchMode.externalApplication),
          icon:const Icon(Icons.sos),label:Text(app.tr('sos'))),
        TextButton.icon(onPressed:shareTrip,icon:const Icon(Icons.share),label:Text(app.tr('share'))),
        TextButton.icon(
          onPressed:()=>Navigator.push(context,MaterialPageRoute(
            builder:(_)=>RiderHelp(tripId:'${trip!['id']}'))),
          icon:const Icon(Icons.support_agent),label:Text(app.tr('help'))),
      ]),
      if (status != 'in_progress')
        TextButton(
            onPressed: cancellationsRemaining==0?null:() async {
              final reason = await showDialog<String>(
                  context: context,
                  builder: (c) {
                    final ctl = TextEditingController();
                    return AlertDialog(
                        title: Text(app.tr('cancel')),
                        content: TextField(
                            controller: ctl,
                            decoration:
                                const InputDecoration(hintText: 'Reason')),
                        actions: [
                          TextButton(
                              onPressed: () => Navigator.pop(c),
                              child: Text(app.tr('no'))),
                          FilledButton(
                              onPressed: () => Navigator.pop(c, ctl.text),
                              child: Text(app.tr('cancel')))
                        ]);
                  });
              if (reason != null && reason.isNotEmpty)
                tripAction('cancel', body: {'reason': reason});
            },
            child: Text('${app.tr('cancel')} · $cancellationsRemaining/3 ${app.language=='hi'?'आज बचे':'left today'}'))
    ]);
  }
}

class Onboarding extends StatefulWidget {
  const Onboarding({super.key});
  @override
  State<Onboarding> createState() => _OnboardingState();
}

class _OnboardingState extends State<Onboarding> {
  final name = TextEditingController(), phone = TextEditingController(),
      plate = TextEditingController(), make = TextEditingController(),
      model = TextEditingController(), color = TextEditingController(),
      year = TextEditingController(), licenceNumber = TextEditingController(),
      insuranceExpiry = TextEditingController(), permitExpiry = TextEditingController(),
      upi = TextEditingController();
  String vehicle = 'Bike';
  Map<String, dynamic>? profile;
  String? error;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    name.text='${app.profile?['name'] ?? ''}';
    phone.text='${app.profile?['phone'] ?? ''}';
    load();
  }

  Future<void> load() async {
    try {
      final d = await app.api.get('/v1/rider/profile');
      setState(() {
        profile =
            d['profile'] == null ? {} : Map<String, dynamic>.from(d['profile']);
        plate.text = '${profile?['vehicle_number'] ?? ''}';
        make.text = '${profile?['vehicle_make'] ?? ''}';
        model.text = '${profile?['vehicle_model'] ?? ''}';
        color.text = '${profile?['vehicle_color'] ?? ''}';
        year.text = '${profile?['vehicle_year'] ?? ''}';
        licenceNumber.text = '${profile?['licence_number'] ?? ''}';
        insuranceExpiry.text = '${profile?['insurance_expiry'] ?? ''}'.split('T').first;
        permitExpiry.text = '${profile?['permit_expiry'] ?? ''}'.split('T').first;
        phone.text = '${profile?['phone'] ?? app.profile?['phone'] ?? ''}';
        upi.text = '${profile?['upi_id'] ?? ''}';
        vehicle = '${profile?['vehicle_type'] ?? 'Bike'}';
      });
    } catch (e) {
      setState(() => error = '$e');
    }
  }

  @override
  void dispose() {
    name.dispose();
    phone.dispose();
    plate.dispose();
    make.dispose();model.dispose();color.dispose();year.dispose();
    licenceNumber.dispose();insuranceExpiry.dispose();permitExpiry.dispose();
    upi.dispose();
    super.dispose();
  }

  Future<void> save() async {
    setState(() => busy = true);
    try {
      if(name.text.trim().length<2)throw const ApiException('Enter your name for rider review.','missing_name',400);
      await app.api.patch('/v1/profile',{'name':name.text.trim(),'phone':phone.text.trim()});
      await app.refreshProfile();
      await app.api.patch('/v1/rider/profile', {
        'vehicle_type': vehicle,
        'vehicle_number': plate.text,
        'vehicle_make': make.text,
        'vehicle_model': model.text,
        'vehicle_color': color.text,
        'vehicle_year': int.tryParse(year.text),
        'licence_number': licenceNumber.text,
        'insurance_expiry': insuranceExpiry.text,
        'permit_expiry': vehicle == 'Bike' ? null : permitExpiry.text,
        'upi_id': upi.text
      });
      await load();
      if (mounted) showMessage(context, app.tr('done'));
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> pickExpiry(TextEditingController controller) async {
    final now = DateTime.now();
    final selected = await showDatePicker(context: context,
      initialDate: (DateTime.tryParse(controller.text)?.isAfter(now) ?? false)
          ? DateTime.parse(controller.text) : now,
      firstDate: now, lastDate: DateTime(now.year + 15));
    if (selected != null) setState(() => controller.text =
      '${selected.year.toString().padLeft(4, '0')}-${selected.month.toString().padLeft(2, '0')}-${selected.day.toString().padLeft(2, '0')}');
  }

  Future<void> upload(String kind) async {
    final image = await ImagePicker().pickImage(
        source: kind == 'selfie' ? ImageSource.camera : ImageSource.gallery,
        imageQuality: 75,
        maxWidth: 1280,
        maxHeight: 1280);
    if (image == null) return;
    setState(() => busy = true);
    try {
      final compressed = await FlutterImageCompress.compressWithFile(image.path,
          minWidth: 960,
          minHeight: 960,
          quality: 70,
          format: CompressFormat.jpeg);
      if (compressed == null || compressed.length > 500000)
        throw const ApiException(
            'Please choose a smaller photo (under 500 KB).',
            'file_too_large',
            413);
      await app.api
          .uploadBytes('/v1/rider/documents/$kind', compressed, 'image/jpeg');
      await load();
      if (mounted) showMessage(context, app.tr('done'));
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: Text(app.tr('documents'))),
      body: profile == null
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(bottom: true, child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: const EdgeInsets.fromLTRB(22, 22, 22, 96), children: [
              HaanHeading(app.tr('approval'), accent: mint),
              const SizedBox(height: 12),
              Text(app.tr('${profile!['verification_status'] ?? 'pending'}')),
              if (profile!['rejection_reason'] != null)
                Text('${profile!['rejection_reason']}',
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error)),
              const SizedBox(height: 24),
              TextField(
                  controller: name,
                  maxLength: 80,
                  textCapitalization: TextCapitalization.words,
                  decoration: InputDecoration(labelText: app.tr('yourName'))),
              TextField(controller: phone, keyboardType: TextInputType.phone,
                maxLength: 13, decoration: InputDecoration(labelText: app.tr('phone'),
                  helperText: app.tr('phoneHelp'))),
              const SizedBox(height: 10),
              SegmentedButton<String>(segments: [
                ButtonSegment(value: 'Bike', label: Text(app.tr('bike'))),
                ButtonSegment(value: 'Auto', label: Text(app.tr('auto'))),
                ButtonSegment(value: 'Cab', label: Text(app.tr('cab')))
              ], selected: {
                vehicle
              }, onSelectionChanged: (v) => setState(() => vehicle = v.first)),
              const SizedBox(height: 14),
              TextField(
                  controller: plate,
                  textCapitalization: TextCapitalization.characters,
                  decoration:
                      InputDecoration(labelText: app.tr('vehicleNumber'))),
              TextField(controller: make, textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(labelText: app.tr('vehicleMake'))),
              TextField(controller: model, textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(labelText: app.tr('vehicleModel'))),
              TextField(controller: color, textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(labelText: app.tr('vehicleColor'))),
              TextField(controller: year, keyboardType: TextInputType.number,
                maxLength: 4, decoration: InputDecoration(labelText: app.tr('vehicleYear'))),
              TextField(controller: licenceNumber, textCapitalization: TextCapitalization.characters,
                decoration: InputDecoration(labelText: app.tr('licenceNumber'))),
              TextField(controller: insuranceExpiry, readOnly: true,
                onTap: () => pickExpiry(insuranceExpiry),
                decoration: InputDecoration(labelText: app.tr('insuranceExpiry'),
                  suffixIcon: const Icon(Icons.calendar_month))),
              if (vehicle != 'Bike') TextField(controller: permitExpiry, readOnly: true,
                onTap: () => pickExpiry(permitExpiry),
                decoration: InputDecoration(labelText: app.tr('permitExpiry'),
                  suffixIcon: const Icon(Icons.calendar_month))),
              const SizedBox(height: 12),
              TextField(
                  controller: upi,
                  decoration: InputDecoration(labelText: app.tr('upi'))),
              const SizedBox(height: 15),
              HaanButton(busy ? '…' : app.tr('save'),
                  onPressed: busy ? null : save),
              const SizedBox(height: 25),
              Text(app.tr('documentsHelp'), style: Theme.of(context).textTheme.bodyMedium),
              for (final kind in ['licence', 'rc', 'selfie', 'insurance', if (vehicle != 'Bike') 'permit'])
                Card(
                    child: ListTile(
                        leading: Icon(
                            profile!['${kind}_uploaded'] == true
                                ? Icons.check_circle
                                : Icons.add_photo_alternate,
                            color: mint),
                        title: Text(app.tr(kind)),
                        subtitle: Text(profile!['${kind}_uploaded'] == true
                            ? app.tr('done')
                            : 'JPEG or PNG, under 500 KB'),
                        onTap: busy ? null : () => upload(kind))),
              if (error != null) HaanError(error!)
            ])));
}

class RiderEarnings extends StatefulWidget {
  const RiderEarnings({super.key});
  @override
  State<RiderEarnings> createState() => _RiderEarningsState();
}

class _RiderEarningsState extends State<RiderEarnings> {
  Map<String, dynamic>? data;
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final d = await app.api.get('/v1/rider/earnings');
      if (mounted) setState(() { data = Map<String, dynamic>.from(d['earnings']); error = null; });
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: Text(app.tr('earnings'))),
      body: data == null
          ? Center(
              child: error == null
                  ? const CircularProgressIndicator()
                  : HaanError(error!, retry: load))
          : RefreshIndicator(
              onRefresh: load,
              child: ListView(padding: const EdgeInsets.all(22), children: [
                HaanHeading(app.tr('earnings'), accent: mint),
                const SizedBox(height: 22),
                Card(
                    child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(app.tr('today')),
                              Text('₹${data!['today']}',
                                  style: Theme.of(context)
                                      .textTheme
                                      .displayMedium),
                              Text('${data!['trips_today']} trips'),
                              Text(app.language=='hi'
                                  ? 'आज Haan शुल्क ₹${data!['today_platform_fee']}'
                                  : 'Haan fees today ₹${data!['today_platform_fee']}')
                            ]))),
                Card(
                    child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(app.tr('week')),
                              Text('₹${data!['week']}',
                                  style:
                                      Theme.of(context).textTheme.displayMedium)
                            ]))),
                Text(app.language=='hi'
                  ? 'Haan को देना बाकी ₹${data!['pending_to_haan']} · Haan से लेना बाकी ₹${data!['pending_from_haan']}. ग्राहक का भुगतान अलग से जाँचें।'
                  : 'Pending to Haan ₹${data!['pending_to_haan']} · Haan owes you ₹${data!['pending_from_haan']}. Verify customer payment separately.'),
                Text(app.tr('payDirect'))
              ])));
}

class RiderHistory extends StatefulWidget {
  const RiderHistory({super.key});
  @override
  State<RiderHistory> createState() => _RiderHistoryState();
}

class _RiderHistoryState extends State<RiderHistory> {
  List<dynamic>? trips;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final d = await app.api.get('/v1/trips/history');
      if (mounted) setState(() => trips = d['trips'] as List);
    } catch (e) {
      if (mounted) showMessage(context, '$e');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: Text(app.tr('history'))),
      body: trips == null
          ? const Center(child: CircularProgressIndicator())
          : trips!.isEmpty
              ? HaanEmpty(app.tr('noTrips'))
              : RefreshIndicator(
                  onRefresh: load,
                  child: ListView(
                      children: trips!
                          .map((t) => Card(
                              margin: const EdgeInsets.all(10),
                              child: ListTile(
                                  title: Text(
                                      '${t['pickup_text']} → ${t['drop_text']}'),
                                  subtitle: Text(
                                      '${t['status']} · ${t['created_at']}'),
                                  trailing: Text(t['status']=='completed'
                                      ? '₹${t['rider_earnings_rupees'] ?? '—'}' : '—'),
                                  onTap: () => Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                          builder: (_) => RiderReceipt(
                                              id: '${t['id']}'))))))
                          .toList())));
}

class RiderReceipt extends StatefulWidget {
  final String id;
  const RiderReceipt({super.key, required this.id});
  @override
  State<RiderReceipt> createState() => _RiderReceiptState();
}

class _RiderReceiptState extends State<RiderReceipt> {
  Map<String, dynamic>? trip;
  int stars = 0;
  bool ratingSubmitted = false, ratingSkipped = false;
  @override
  void initState() {
    super.initState();
    app.api.get('/v1/trips/${widget.id}').then((d) {
      if (mounted) setState(() {
        trip = Map<String, dynamic>.from(d['trip']);
        stars = (trip?['my_rating_stars'] as num?)?.toInt() ?? 0;
        ratingSubmitted = stars > 0;
      });
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: Text(app.tr('history'))),
      body: trip == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.all(22), children: [
              HaanHeading(trip!['status']=='completed' ? app.tr('completed')
                  : '${app.tr('status')}: ${trip!['status']}', accent: mint),
              const SizedBox(height: 20),
              Card(
                  child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                                '${trip!['pickup_text']} → ${trip!['drop_text']}'),
                            if(trip!['status']=='completed') Text(
                                '₹${trip!['customer_final_rupees'] ?? trip!['final_rupees']}',
                                style:Theme.of(context).textTheme.displayMedium),
                            if(trip!['status']=='completed') Text(app.language=='hi'?'ग्राहक से लें':'Collect from customer'),
                            if(trip!['status']=='completed') Text(app.language=='hi'
                              ? 'आपकी कमाई ₹${trip!['rider_earnings_rupees'] ?? '—'} · Haan शुल्क ₹${trip!['platform_fee_rupees'] ?? '—'}'
                              : 'Your earnings ₹${trip!['rider_earnings_rupees'] ?? '—'} · Haan fee ₹${trip!['platform_fee_rupees'] ?? '—'}'),
                            if(trip!['status']=='completed'&&(trip!['promotion_topup_rupees'] as num?)?.toInt()!=0)
                              Text('₹${trip!['promotion_topup_rupees']} ${app.language=='hi'?'प्रोमो टॉप-अप — ऑपरेटर से अलग':'promotion top-up — settle separately with operator'}'),
                            if(trip!['status']=='completed') Text(app.language=='hi'
                              ? 'Haan सेटलमेंट ₹${trip!['net_due_to_platform_rupees'] ?? '—'} (धनात्मक: Haan को दें)'
                              : 'Net settlement ₹${trip!['net_due_to_platform_rupees'] ?? '—'} (positive: remit to Haan)'),
                            if(trip!['status']=='completed') Text(app.language=='hi'
                              ? 'सेटलमेंट: ${trip!['settlement_status'] ?? 'pending'}'
                              : 'Settlement: ${trip!['settlement_status'] ?? 'pending'}'),
                            if(trip!['status']!='completed') Text(app.language=='hi'
                              ? 'यह सफ़र पूरा नहीं हुआ। कोई कमाई या वसूली नहीं दिखा रहे हैं।'
                              : 'This trip was not completed. No earnings or amount to collect.'),
                          ]))),
              const SizedBox(height:16),
              if(trip!['status']=='completed') Builder(builder:(context){
                final amount=(trip!['customer_final_rupees'] as num?)?.toInt()
                  ??(trip!['customer_estimate_rupees'] as num?)?.toInt()
                  ??(trip!['final_rupees'] as num?)?.toInt()
                  ??(trip!['estimate_rupees'] as num?)?.toInt()??0;
                final uri=directUpiUri(upiId:trip!['rider_upi_id'] as String?,
                  name:trip!['rider_name'] as String?,amount:amount);
                if(uri==null)return Text(app.language=='hi'
                  ? 'UPI ID जोड़ने के लिए प्रोफ़ाइल खोलें। अभी नकद लें।'
                  : 'Add a UPI ID in your profile to show a payment QR. Collect cash for now.');
                return Card(child:Padding(padding:const EdgeInsets.all(18),
                  child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
                    Text(app.language=='hi'?'ग्राहक को यह UPI QR दिखाएँ':'Show this UPI QR to the customer',
                      style:Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height:12),
                    Center(child:QrImageView(data:uri.toString(),version:QrVersions.auto,
                      size:190,backgroundColor:Colors.white,
                      semanticsLabel:'UPI QR for ₹$amount')),
                    SelectableText('${trip!['rider_upi_id']} · ₹$amount'),
                    Text(app.language=='hi'
                      ? 'भुगतान अपने UPI ऐप में जाँचें। Haan इसकी पुष्टि नहीं कर सकता।'
                      : 'Check your own UPI app for payment. Haan cannot confirm it.'),
                  ])));
              }),
              if(trip!['status']=='completed' && ratingSubmitted)
                Text(app.language == 'hi' ? 'आपने ग्राहक को $stars स्टार दिए।'
                    : 'You rated this customer $stars stars.'),
              if(trip!['status']=='completed' && !ratingSubmitted && !ratingSkipped)
                Text(app.language == 'hi' ? 'ग्राहक को रेट करें' : 'Rate your customer',
                  style: Theme.of(context).textTheme.titleLarge),
              if(trip!['status']=='completed' && !ratingSubmitted && !ratingSkipped) Row(
                  children: List.generate(
                      5,
                      (i) => IconButton(
                          onPressed: () async {
                            setState(() => stars = i + 1);
                            try {
                              await app.api.post(
                                  '/v1/trips/${widget.id}/rating',
                                  {'stars': stars});
                              if (mounted) setState(() => ratingSubmitted = true);
                            } catch (e) {
                              if (context.mounted) showMessage(context, '$e');
                            }
                          },
                          icon: Icon(i < stars ? Icons.star : Icons.star_border,
                              color: mint)))),
              if(trip!['status']=='completed' && !ratingSubmitted && !ratingSkipped)
                TextButton(onPressed: () => setState(() => ratingSkipped = true),
                  child: Text(app.language == 'hi' ? 'अभी छोड़ें' : 'Skip for now')),
              TextButton(
                  onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => RiderHelp(tripId: widget.id))),
                  child: Text(app.tr('help')))
            ]));
}

class RiderAccount extends StatefulWidget {
  const RiderAccount({super.key});
  @override
  State<RiderAccount> createState() => _RiderAccountState();
}

class _RiderAccountState extends State<RiderAccount> {
  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: Text(app.tr('profile'))),
      body: ListView(padding: const EdgeInsets.all(22), children: [
        HaanHeading('Ride with Haan.', accent: mint),
        const SizedBox(height: 14),
        Text('${app.profile?['email'] ?? ''}'),
        const SizedBox(height: 18),
        ListTile(
            leading: const Icon(Icons.verified_user_outlined),
            title: Text(app.tr('approval')),
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const Onboarding()))),
        ListTile(
            leading: const Icon(Icons.help_outline),
            title: Text(app.tr('help')),
            onTap: () => Navigator.push(
                context, MaterialPageRoute(builder: (_) => const RiderHelp()))),
        ListTile(
            leading: const Icon(Icons.settings_outlined),
            title: Text(app.tr('settings')),
            onTap: () => showPreferences(context, app)),
        ListTile(
            leading: const Icon(Icons.logout),
            title: Text(app.tr('logout')),
            onTap: () async { await setRiderService(false); await app.logout(); }),
        ListTile(
            leading: const Icon(Icons.delete_outline),
            title: Text(app.tr('delete')),
            onTap: () async {
              final yes = await showDialog<bool>(
                  context: context,
                  builder: (c) => AlertDialog(
                          title: Text(app.tr('delete')),
                          content: Text(app.tr('confirmDelete')),
                          actions: [
                            TextButton(
                                onPressed: () => Navigator.pop(c, false),
                                child: Text(app.tr('no'))),
                            FilledButton(
                                onPressed: () => Navigator.pop(c, true),
                                child: Text(app.tr('yesDelete')))
                          ]));
              if (yes == true) {
                try {
                  await app.api.delete('/v1/profile');
                  await setRiderService(false);
                  await app.logout();
                } catch (e) {
                  if (context.mounted) showMessage(context, '$e');
                }
              }
            })
      ]));
}

class RiderHelp extends StatefulWidget {
  final String? tripId;
  const RiderHelp({super.key, this.tripId});
  @override
  State<RiderHelp> createState() => _RiderHelpState();
}

class _RiderHelpState extends State<RiderHelp> {
  final subject = TextEditingController(), message = TextEditingController();
  List<dynamic>? tickets;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final d = await app.api.get('/v1/tickets');
      setState(() => tickets = d['tickets'] as List);
    } catch (e) {
      if (mounted) showMessage(context, '$e');
    }
  }

  @override
  void dispose() {
    subject.dispose();
    message.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: Text(app.tr('help'))),
      body: ListView(padding: const EdgeInsets.all(22), children: [
        HaanHeading(app.tr('ticket'), accent: mint),
        const SizedBox(height: 16),
        TextField(
            controller: subject,
            decoration: const InputDecoration(labelText: 'Subject'),
            maxLength: 120),
        const SizedBox(height: 10),
        TextField(
            controller: message,
            decoration: const InputDecoration(labelText: 'Message'),
            maxLines: 4,
            maxLength: 2000),
        const SizedBox(height: 12),
        HaanButton(app.tr('send'), onPressed: () async {
          try {
            await app.api.post('/v1/tickets', {
              'subject': subject.text,
              'message': message.text,
              if (widget.tripId != null) 'trip_id': widget.tripId
            });
            subject.clear();
            message.clear();
            load();
          } catch (e) {
            if (context.mounted) showMessage(context, '$e');
          }
        }),
        const SizedBox(height: 22),
        if (tickets != null)
          ...tickets!.map((t) => ListTile(
              title: Text('${t['subject']}'),
              subtitle: Text('${t['status']}'),
              onTap: () async {
                final d = await app.api.get('/v1/tickets/${t['id']}');
                if (context.mounted)
                  showModalBottomSheet(
                      context: context,
                      builder: (_) => ListView(
                          children: (d['messages'] as List)
                              .map((m) => ListTile(title: Text('${m['body']}')))
                              .toList()));
              }))
      ]));
}

class RiderDestinationPicker extends StatefulWidget {
  const RiderDestinationPicker({super.key});
  @override
  State<RiderDestinationPicker> createState()=>_RiderDestinationPickerState();
}
class _RiderDestinationPickerState extends State<RiderDestinationPicker> {
  final search=TextEditingController();
  List<dynamic> places=[];
  bool busy=false;
  String? error;
  @override
  void dispose(){search.dispose();super.dispose();}
  Future<void> find() async {
    if(search.text.trim().length<3){setState(()=>error='Type at least three letters.');return;}
    setState((){busy=true;error=null;});
    try{final d=await app.api.get('/v1/places/search?q=${Uri.encodeQueryComponent(search.text.trim())}');
      if(mounted)setState(()=>places=List<dynamic>.from(d['places']??[]));}
    catch(e){if(mounted)setState(()=>error='$e');}
    finally{if(mounted)setState(()=>busy=false);}
  }
  @override
  Widget build(BuildContext context)=>Padding(
    padding:EdgeInsets.fromLTRB(20,12,20,MediaQuery.viewInsetsOf(context).bottom+24),
    child:ConstrainedBox(constraints:const BoxConstraints(maxHeight:520),
      child:Column(mainAxisSize:MainAxisSize.min,crossAxisAlignment:CrossAxisAlignment.start,children:[
        Text(app.language=='hi'?'किस दिशा में जाना है?':'Where are you headed?',style:Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height:12),
        TextField(controller:search,autofocus:true,textInputAction:TextInputAction.search,
          onSubmitted:(_)=>find(),decoration:InputDecoration(labelText:app.language=='hi'?'मंज़िल खोजें':'Search destination',
            suffixIcon:IconButton(onPressed:find,icon:const Icon(Icons.search)))),
        if(busy)const LinearProgressIndicator(),
        if(error!=null)Text(error!,style:TextStyle(color:Theme.of(context).colorScheme.error)),
        Flexible(child:ListView(shrinkWrap:true,children:places.map((p)=>ListTile(
          title:Text('${p['name']??p['text']??'Place'}'),
          onTap:()=>Navigator.pop(context,{'lat':p['lat'],'lng':p['lng'],'text':'${p['name']??p['text']}'}))).toList())),
        TextButton.icon(onPressed:()=>Navigator.pop(context,{'clear':true}),
          icon:const Icon(Icons.close),label:Text(app.language=='hi'?'फ़िल्टर हटाएँ':'Clear destination filter')),
      ])));
}
