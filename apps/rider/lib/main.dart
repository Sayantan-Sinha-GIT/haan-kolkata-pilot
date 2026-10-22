import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image_picker/image_picker.dart';
import 'package:latlong2/latlong.dart';
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
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
      valueListenable: incomingOffer,
      builder: (context, offering, _) => Scaffold(
      body: IndexedStack(index: offering ? 0 : tab, children: [
        RiderHome(),
        RiderEarnings(),
        RiderHistory(),
        RiderAccount()
      ]),
      bottomNavigationBar: offering ? null : NavigationBar(
          selectedIndex: tab,
          onDestinationSelected: (v) => setState(() => tab = v),
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
        final nextKey='${t['id']}:${t['status']=='in_progress'?'drop':'pickup'}';
        if (routeKey != nextKey) {
          routeKey=nextKey;
          final pos=await currentPosition();
          if (pos!=null) {
            center=LatLng(pos.latitude,pos.longitude);
            final target=t['status']=='in_progress'
              ? LatLng((t['drop_lat'] as num).toDouble(),(t['drop_lng'] as num).toDouble())
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
                title: Text(app.tr('pin')),
                content: TextField(
                    controller: ctl,
                    keyboardType: TextInputType.number,
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
    if (pin != null) tripAction('start', body: {'pin': pin});
  }

  Future<void> navigate(bool toPickup) async {
    if (trip == null) return;
    final lat = trip![toPickup ? 'pickup_lat' : 'drop_lat'],
        lng = trip![toPickup ? 'pickup_lng' : 'drop_lng'];
    final uri = Uri.parse('geo:$lat,$lng?q=$lat,$lng');
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication) && mounted)
      showMessage(context, 'Could not open maps. Follow the in-app map.');
  }

  @override
  Widget build(BuildContext context) {
    final verified = riderProfile?['verification_status'] == 'approved';
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
                        if (riderProfile == null || !verified)
                          _approvalPanel()
                        else if (trip != null)
                          _tripPanel()
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
            onChanged: (v) => setState(() => lowData = v))
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
      const SizedBox(height: 10),
      Text('${o['estimated_km']} km  ·  ₹${o['estimate_rupees']}',
          style: Theme.of(context).textTheme.headlineMedium),
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
      const SizedBox(height: 6),
      Text('${trip!['vehicle_type']} · ₹${trip!['estimate_rupees']}',
          style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 14),
      if (status == 'accepted')
        HaanButton(app.tr('arrived'),
            onPressed: busy ? null : () => tripAction('arrived')),
      if (status == 'arrived')
        HaanButton(app.tr('start'), onPressed: busy ? null : startWithPin),
      if (status == 'in_progress')
        HaanButton(app.tr('end'),
            onPressed: busy ? null : () => tripAction('complete')),
      const SizedBox(height: 10),
      OutlinedButton.icon(
          onPressed: () => navigate(status != 'in_progress'),
          icon: const Icon(Icons.navigation),
          label: Text(app.language=='hi'?'मैप ऐप में खोलें':'Open in maps app')),
      if (status != 'in_progress')
        TextButton(
            onPressed: () async {
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
            child: Text(app.tr('cancel')))
    ]);
  }
}

class Onboarding extends StatefulWidget {
  const Onboarding({super.key});
  @override
  State<Onboarding> createState() => _OnboardingState();
}

class _OnboardingState extends State<Onboarding> {
  final name = TextEditingController(), plate = TextEditingController(), upi = TextEditingController();
  String vehicle = 'Bike';
  Map<String, dynamic>? profile;
  String? error;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    name.text='${app.profile?['name'] ?? ''}';
    load();
  }

  Future<void> load() async {
    try {
      final d = await app.api.get('/v1/rider/profile');
      setState(() {
        profile =
            d['profile'] == null ? {} : Map<String, dynamic>.from(d['profile']);
        plate.text = '${profile?['vehicle_number'] ?? ''}';
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
    plate.dispose();
    upi.dispose();
    super.dispose();
  }

  Future<void> save() async {
    setState(() => busy = true);
    try {
      if(name.text.trim().length<2)throw const ApiException('Enter your name for rider review.','missing_name',400);
      await app.api.patch('/v1/profile',{'name':name.text.trim()});
      await app.refreshProfile();
      await app.api.patch('/v1/rider/profile', {
        'vehicle_type': vehicle,
        'vehicle_number': plate.text,
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
          : ListView(padding: const EdgeInsets.all(22), children: [
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
                  decoration:
                      InputDecoration(labelText: app.tr('vehicleNumber'))),
              const SizedBox(height: 12),
              TextField(
                  controller: upi,
                  decoration: InputDecoration(labelText: app.tr('upi'))),
              const SizedBox(height: 15),
              HaanButton(busy ? '…' : app.tr('save'),
                  onPressed: busy ? null : save),
              const SizedBox(height: 25),
              for (final kind in ['licence', 'rc', 'selfie'])
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
            ]));
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
      setState(() => data = Map<String, dynamic>.from(d['earnings']));
    } catch (e) {
      setState(() => error = '$e');
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
                              Text('${data!['trips_today']} trips')
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
      setState(() => trips = d['trips'] as List);
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
                                  trailing: Text(
                                      '₹${t['final_rupees'] ?? t['estimate_rupees']}'),
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
  @override
  void initState() {
    super.initState();
    app.api.get('/v1/trips/${widget.id}').then((d) {
      if (mounted) setState(() => trip = Map<String, dynamic>.from(d['trip']));
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: Text(app.tr('history'))),
      body: trip == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.all(22), children: [
              HaanHeading(app.tr('completed'), accent: mint),
              const SizedBox(height: 20),
              Card(
                  child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                                '${trip!['pickup_text']} → ${trip!['drop_text']}'),
                            Text(
                                '₹${trip!['final_rupees'] ?? trip!['estimate_rupees']}',
                                style:
                                    Theme.of(context).textTheme.displayMedium),
                            Text(app.tr('collect'))
                          ]))),
              Text(app.tr('rate')),
              Row(
                  children: List.generate(
                      5,
                      (i) => IconButton(
                          onPressed: () async {
                            setState(() => stars = i + 1);
                            try {
                              await app.api.post(
                                  '/v1/trips/${widget.id}/rating',
                                  {'stars': stars});
                            } catch (e) {
                              if (context.mounted) showMessage(context, '$e');
                            }
                          },
                          icon: Icon(i < stars ? Icons.star : Icons.star_border,
                              color: mint)))),
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
