import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:haan_core/haan_core.dart';

final app = HaanState(role: 'customer');
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const HaanCustomer());
  app.init();
}

class HaanCustomer extends StatelessWidget {
  const HaanCustomer({super.key});
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: app,
      builder: (context, _) => MaterialApp(
          title: 'Haan',
          debugShowCheckedModeBanner: false,
          theme: haanTheme(false, amber),
          darkTheme: haanTheme(true, amber),
          themeMode: app.themeMode,
          home: !app.ready
              ? const Scaffold(body: Center(child: CircularProgressIndicator()))
              : app.updateRequired
                  ? UpdateRequired(app)
              : app.signedIn
                  ? const CustomerShell()
                  : const SignIn()));
}

class SignIn extends StatefulWidget {
  const SignIn({super.key});
  @override
  State<SignIn> createState() => _SignInState();
}

class _SignInState extends State<SignIn> {
  final email = TextEditingController(), code = TextEditingController();
  bool sent = false, busy = false;
  String? error;
  int attempts = 5;
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
            {'email': email.text.trim(), 'role': 'customer'});
        setState(() => sent = true);
      } else {
        await app.login(email.text.trim(), code.text.trim(), 'customer');
      }
    } on ApiException catch (e) {
      setState(() {
        error = e.message;
        attempts = e.attemptsLeft ?? attempts;
      });
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
                    const Icon(Icons.location_on, color: amber, size: 42),
                    const SizedBox(height: 20),
                    HaanHeading(app.tr('welcome')),
                    const SizedBox(height: 35),
                    Text(sent ? app.tr('code') : app.tr('email')),
                    const SizedBox(height: 8),
                    TextField(
                        controller: sent ? code : email,
                        keyboardType: sent
                            ? TextInputType.number
                            : TextInputType.emailAddress,
                        autofillHints: sent
                            ? [AutofillHints.oneTimeCode]
                            : [AutofillHints.email],
                        maxLength: sent ? 6 : null,
                        decoration: InputDecoration(
                            hintText: sent ? '000000' : 'you@example.com'),
                        onSubmitted: (_) => submit()),
                    if (error != null)
                      Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                              '$error${sent ? ' · $attempts left' : ''}',
                              style: TextStyle(
                                  color: Theme.of(context).colorScheme.error))),
                    const SizedBox(height: 16),
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
                    Row(children: [
                      TextButton(
                          onPressed: () => app
                              .setLanguage(app.language == 'en' ? 'hi' : 'en'),
                          child: Text(
                              app.language == 'en' ? 'हिन्दी' : 'English')),
                      TextButton(
                          onPressed: () => showPreferences(context, app),
                          child: Text(app.tr('settings')))
                    ]),
                    Text('KOLKATA PILOT · ANDROID',
                        style: Theme.of(context).textTheme.labelSmall)
                  ]))));
}

class CustomerShell extends StatefulWidget {
  const CustomerShell({super.key});
  @override
  State<CustomerShell> createState() => _CustomerShellState();
}

class _CustomerShellState extends State<CustomerShell> {
  int tab = 0;
  @override
  Widget build(BuildContext context) => Scaffold(
      body: IndexedStack(index: tab, children: const [
        RideHome(),
        TripHistory(),
        CustomerHelp(),
        CustomerProfile()
      ]),
      bottomNavigationBar: NavigationBar(
          selectedIndex: tab,
          onDestinationSelected: (v) => setState(() => tab = v),
          destinations: [
            NavigationDestination(
                icon: const Icon(Icons.map_outlined),
                selectedIcon: const Icon(Icons.map),
                label: app.tr('home')),
            NavigationDestination(
                icon: const Icon(Icons.receipt_long_outlined),
                label: app.tr('history')),
            NavigationDestination(
                icon: const Icon(Icons.help_outline), label: app.tr('help')),
            NavigationDestination(
                icon: const Icon(Icons.person_outline),
                label: app.tr('profile'))
          ]));
}

Map<String, dynamic> point(LatLng p, String label) =>
    {'lat': p.latitude, 'lng': p.longitude, 'text': label};
const kolkata = LatLng(22.5726, 88.3639);

class RideHome extends StatefulWidget {
  const RideHome({super.key});
  @override
  State<RideHome> createState() => _RideHomeState();
}

class _RideHomeState extends State<RideHome> {
  LatLng center = kolkata, pickup = kolkata;
  LatLng? drop, rider;
  String pickupLabel = 'Kolkata', dropLabel = '';
  String vehicle = 'Bike';
  Map<String, dynamic>? estimate, trip;
  String? pin;
  bool busy = false, viaAssistant = false;
  String? error;
  Timer? timer;
  String? receiptOpenedFor;
  final secure = const FlutterSecureStorage();
  @override
  void initState() {
    super.initState();
    _position();
    _loadActive();
    timer = Timer.periodic(
        const Duration(seconds: 4), (_) => _loadActive(silent: true));
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> _position() async {
    final p = await currentPosition();
    if (p != null && mounted)
      setState(() {
        center = LatLng(p.latitude, p.longitude);
        pickup = center;
        pickupLabel = 'Current location';
      });
  }

  Future<void> _loadActive({bool silent = false}) async {
    try {
      final data = await app.api.get('/v1/trips/active');
      final active = data['trip'];
      if (active == null) {
        final previousId = trip?['id']?.toString();
        if (previousId != null && receiptOpenedFor != previousId) {
          final finished = await app.api.get('/v1/trips/$previousId');
          if (!mounted) return;
          if (finished['trip']?['status'] == 'completed') {
            receiptOpenedFor = previousId;
            Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => ReceiptPage(id: previousId)));
          }
        }
        if (trip != null && mounted)
          setState(() {
            trip = null;
            rider = null;
            pin = null;
          });
        return;
      }
      final id = '${active['id']}';
      final full = await app.api.get('/v1/trips/$id');
      final t = Map<String, dynamic>.from(full['trip']);
      final loc = full['location'];
      final localPin = await secure.read(key: 'pin:$id');
      if (mounted)
        setState(() {
          trip = t;
          pin = localPin;
          rider = loc == null
              ? null
              : LatLng((loc['lat'] as num).toDouble(),
                  (loc['lng'] as num).toDouble());
        });
    } catch (e) {
      if (!silent && mounted) setState(() => error = '$e');
    }
  }

  Future<void> choosePlace(bool isPickup) async {
    final selected = await showModalBottomSheet<Map<String, dynamic>>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: true,
        builder: (context) => PlacePicker(initial: isPickup ? pickup : drop));
    if (selected != null && mounted) {
      setState(() {
        final p = LatLng((selected['lat'] as num).toDouble(),
            (selected['lng'] as num).toDouble());
        if (isPickup) {
          pickup = p;
          pickupLabel = '${selected['name']}';
        } else {
          drop = p;
          dropLabel = '${selected['name']}';
        }
        estimate = null;
      });
      if (drop != null) _estimate();
    }
  }

  Future<void> _estimate() async {
    if (drop == null) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final d = await app.api.post('/v1/fare/estimate', {
        'pickup': point(pickup, pickupLabel),
        'drop': point(drop!, dropLabel),
        'vehicle': vehicle
      });
      if (mounted) setState(() => estimate = Map<String, dynamic>.from(d));
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _book() async {
    if (drop == null || estimate == null) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final d = await app.api.post('/v1/trips', {
        'pickup': point(pickup, pickupLabel),
        'drop': point(drop!, dropLabel),
        'vehicle': vehicle,
        'confirmed': true,
        'via_assistant': viaAssistant
      });
      final id = '${d['trip']['id']}';
      await secure.write(key: 'pin:$id', value: '${d['pin']}');
      setState(() {
        pin = '${d['pin']}';
        trip = Map<String, dynamic>.from(d['trip']);
      });
      await _loadActive();
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _cancel() async {
    final reason = await showModalBottomSheet<String>(
        context: context,
        builder: (context) => SafeArea(
            child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  'Changed plans',
                  'Rider is delayed',
                  'Wrong pickup',
                  'Other'
                ]
                    .map((r) => ListTile(
                        title: Text(r), onTap: () => Navigator.pop(context, r)))
                    .toList())));
    if (reason == null || trip == null) return;
    try {
      await app.api.post('/v1/trips/${trip!['id']}/cancel', {'reason': reason});
      await _loadActive();
    } catch (e) {
      if (mounted) showMessage(context, '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = '${trip?['status'] ?? ''}';
    return Stack(children: [
      Positioned.fill(
          child: HaanMap(
              center: center,
              pickup: pickup,
              drop: drop,
              rider: rider,
              onTap: trip == null
                  ? (p) => setState(() {
                        drop = p;
                        dropLabel =
                            'Map pin · ${p.latitude.toStringAsFixed(4)}, ${p.longitude.toStringAsFixed(4)}';
                        _estimate();
                      })
                  : null)),
      Positioned(
          top: MediaQuery.paddingOf(context).top + 12,
          left: 16,
          right: 16,
          child: Row(children: [
            Expanded(
                child: Card(
                    child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 18, vertical: 10),
                        child: Row(children: [
                          const Icon(Icons.location_on, color: amber),
                          const SizedBox(width: 8),
                          Text('HAAN',
                              style:
                                  Theme.of(context).appBarTheme.titleTextStyle)
                        ])))),
            IconButton.filledTonal(
                onPressed: () => _assistant(),
                icon: const Icon(Icons.mic_rounded),
                tooltip: app.tr('assistant'))
          ])),
      Align(
          alignment: Alignment.bottomCenter,
          child: Container(
              constraints: const BoxConstraints(maxHeight: 500),
              decoration: BoxDecoration(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(28)),
                  boxShadow: const [
                    BoxShadow(blurRadius: 24, color: Colors.black26)
                  ]),
              child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(22, 12, 22, 24),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Center(
                            child: Container(
                                width: 40,
                                height: 4,
                                decoration: BoxDecoration(
                                    color: Colors.grey,
                                    borderRadius: BorderRadius.circular(4)))),
                        const SizedBox(height: 18),
                        if (trip == null) ...[
                          _bookingPanel()
                        ] else ...[
                          _tripPanel(status)
                        ],
                        if (error != null)
                          Padding(
                              padding: const EdgeInsets.only(top: 12),
                              child: HaanError(error!,
                                  retry: () => trip == null
                                      ? _estimate()
                                      : _loadActive()))
                      ]))))
    ]);
  }

  Widget _bookingPanel() =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        HaanHeading(app.tr('whereTo')),
        const SizedBox(height: 17),
        ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.trip_origin, color: amber),
            title: Text(app.tr('pickup')),
            subtitle:
                Text(pickupLabel, maxLines: 1, overflow: TextOverflow.ellipsis),
            onTap: () => choosePlace(true)),
        ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.location_on, color: Color(0xfffa805d)),
            title: Text(app.tr('destination')),
            subtitle: Text(dropLabel.isEmpty ? app.tr('search') : dropLabel,
                maxLines: 1, overflow: TextOverflow.ellipsis),
            onTap: () => choosePlace(false)),
        if (drop != null) ...[
          const SizedBox(height: 8),
          SegmentedButton<String>(
              segments: [
                ButtonSegment(
                    value: 'Bike',
                    label: Text(app.tr('bike')),
                    icon: const Icon(Icons.two_wheeler)),
                ButtonSegment(
                    value: 'Auto',
                    label: Text(app.tr('auto')),
                    icon: const Icon(Icons.electric_rickshaw)),
                ButtonSegment(
                    value: 'Cab',
                    label: Text(app.tr('cab')),
                    icon: const Icon(Icons.local_taxi))
              ],
              selected: {
                vehicle
              },
              onSelectionChanged: (v) {
                setState(() => vehicle = v.first);
                _estimate();
              }),
          const SizedBox(height: 14),
          if (estimate != null)
            Card(
                child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                              '${estimate!['km']} km · ${estimate!['minutes']} min'),
                          Text('₹${estimate!['rupees']}',
                              style: Theme.of(context).textTheme.headlineMedium)
                        ]))),
          const SizedBox(height: 10),
          HaanButton(busy ? '…' : app.tr('book'),
              onPressed:
                  busy || estimate == null ? null : () => _confirmBooking())
        ],
        const SizedBox(height: 12),
        TextButton.icon(
            onPressed: _assistant,
            icon: const Icon(Icons.mic),
            label: Text(app.tr('assistant')))
      ]);
  Future<void> _confirmBooking() async {
    final yes = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
                title: Text(app.tr('readBack')),
                content: Text(
                    '$pickupLabel → $dropLabel\n$vehicle · ₹${estimate?['rupees']}'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(c, false),
                      child: Text(app.tr('no'))),
                  FilledButton(
                      onPressed: () => Navigator.pop(c, true),
                      child: Text(app.tr('confirm')))
                ]));
    if (yes == true) _book();
  }

  Widget _tripPanel(String status) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        HaanHeading(app.tr(switch (status) {
          'searching' => 'finding',
          'accepted' => 'riderAssigned',
          'arrived' => 'arrived',
          'in_progress' => 'inProgress',
          'completed' => 'completed',
          _ => 'status'
        })),
        const SizedBox(height: 14),
        Text(
            '${trip?['pickup_text'] ?? pickupLabel} → ${trip?['drop_text'] ?? dropLabel}'),
        const SizedBox(height: 12),
        if (status == 'searching') const LinearProgressIndicator(),
        if (['accepted', 'arrived', 'in_progress'].contains(status)) ...[
          Card(
              child: Padding(
                  padding: const EdgeInsets.all(15),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                            '${trip?['rider_name'] ?? 'Rider'} · ${trip?['vehicle_number'] ?? ''}',
                            style: Theme.of(context).textTheme.titleLarge),
                        if (pin != null && status != 'in_progress')
                          Text('${app.tr('pin')}: $pin',
                              style:
                                  Theme.of(context).textTheme.headlineMedium),
                        if (rider == null)
                          const Text('Rider connection pending',
                              style: TextStyle(color: Colors.orange))
                      ])))
        ],
        const SizedBox(height: 8),
        Text(
            '${app.tr('fare')}: ₹${trip?['final_rupees'] ?? trip?['estimate_rupees'] ?? ''}'),
        if (status != 'in_progress')
          TextButton(onPressed: _cancel, child: Text(app.tr('cancel'))),
        if (status == 'in_progress')
          Row(children: [
            TextButton.icon(
                onPressed: () => launchUrl(Uri.parse('tel:112')),
                icon: const Icon(Icons.sos),
                label: Text(app.tr('sos'))),
            TextButton.icon(
                onPressed: () => showMessage(context,
                    'Share the trip ID ${trip?['id']} with your emergency contact.'),
                icon: const Icon(Icons.share),
                label: Text(app.tr('share')))
          ]),
        if (status == 'completed') Text(app.tr('payDirect'))
      ]);
  Future<void> _assistant() async {
    final result = await Navigator.push<Map<String, dynamic>>(
        context,
        MaterialPageRoute(
            builder: (_) =>
                AssistantPage(pickup: pickup, pickupLabel: pickupLabel)));
    if (result != null && mounted) {
      setState(() {
        drop = LatLng((result['lat'] as num).toDouble(),
            (result['lng'] as num).toDouble());
        dropLabel = '${result['name']}';
        vehicle = '${result['vehicle'] ?? 'Bike'}';
        viaAssistant = true;
      });
      _estimate();
    }
  }
}

class PlacePicker extends StatefulWidget {
  final LatLng? initial;
  const PlacePicker({super.key, this.initial});
  @override
  State<PlacePicker> createState() => _PlacePickerState();
}

class _PlacePickerState extends State<PlacePicker> {
  final controller = TextEditingController();
  List<dynamic> places = [];
  bool loading = false;
  String? error;
  Timer? debounce;
  @override
  void dispose() {
    debounce?.cancel();
    controller.dispose();
    super.dispose();
  }

  void search(String q) {
    debounce?.cancel();
    if (q.trim().length < 3) {
      setState(() => places = []);
      return;
    }
    debounce = Timer(const Duration(milliseconds: 450), () async {
      setState(() {
        loading = true;
        error = null;
      });
      try {
        final d = await app.api
            .get('/v1/places/search?q=${Uri.encodeQueryComponent(q)}');
        if (mounted) setState(() => places = d['places'] as List);
      } catch (e) {
        if (mounted) setState(() => error = '$e');
      } finally {
        if (mounted) setState(() => loading = false);
      }
    });
  }

  @override
  Widget build(BuildContext context) => FractionallySizedBox(
      heightFactor: .84,
      child: Padding(
          padding: EdgeInsets.fromLTRB(
              18, 8, 18, MediaQuery.viewInsetsOf(context).bottom + 18),
          child: Column(children: [
            TextField(
                controller: controller,
                autofocus: true,
                decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search),
                    hintText: app.tr('destination')),
                onChanged: search),
            if (loading) const LinearProgressIndicator(),
            if (error != null)
              Text(error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            Expanded(
                child: places.isEmpty
                    ? HaanEmpty(
                        controller.text.length < 3
                            ? app.tr('search')
                            : app.tr('noResults'),
                        icon: Icons.place_outlined)
                    : ListView.builder(
                        itemCount: places.length,
                        itemBuilder: (c, i) {
                          final p = places[i];
                          return ListTile(
                              leading: const Icon(Icons.place_outlined),
                              title: Text('${p['name']}',
                                  maxLines: 2, overflow: TextOverflow.ellipsis),
                              onTap: () => Navigator.pop(context, p));
                        })),
            TextButton.icon(
                onPressed: () {
                  final p = widget.initial ?? kolkata;
                  Navigator.pop(context, {
                    'name': 'Map pin',
                    'lat': p.latitude,
                    'lng': p.longitude
                  });
                },
                icon: const Icon(Icons.add_location_alt_outlined),
                label: Text(app.tr('mapPin')))
          ])));
}

class AssistantPage extends StatefulWidget {
  final LatLng pickup;
  final String pickupLabel;
  const AssistantPage(
      {super.key, required this.pickup, required this.pickupLabel});
  @override
  State<AssistantPage> createState() => _AssistantPageState();
}

class _AssistantPageState extends State<AssistantPage> {
  final text = TextEditingController(), tts = FlutterTts();
  final recorder = AudioRecorder();
  Map<String, dynamic>? parsed, place;
  String? error;
  bool busy = false, recording = false;
  Timer? recordTimer;
  @override
  void dispose() {
    text.dispose();
    recordTimer?.cancel();
    recorder.dispose();
    tts.stop();
    super.dispose();
  }

  Future<void> toggleRecording() async {
    if (recording) {
      recordTimer?.cancel();
      final path = await recorder.stop();
      if (mounted) setState(() { recording = false; busy = true; });
      if (path == null) return;
      try {
        text.text = await app.api.transcribeAudio(path);
        await parse();
      } catch (e) {
        if (mounted) setState(() => error = '$e');
      } finally {
        try { await File(path).delete(); } catch (_) {}
        if (mounted) setState(() => busy = false);
      }
      return;
    }
    if (!await recorder.hasPermission()) {
      setState(() => error = 'Allow microphone access to speak a trip.');
      return;
    }
    final dir = await getTemporaryDirectory();
    await recorder.start(const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 32000, sampleRate: 16000), path: '${dir.path}/haan-request.m4a');
    if (mounted) setState(() { recording = true; error = null; });
    recordTimer = Timer(const Duration(seconds: 15), () { if (recording) toggleRecording(); });
  }

  Future<void> parse() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final d = await app.api.post('/v1/assistant/parse', {'text': text.text});
      if (d['fallback'] != null) {
        setState(() => error = '${d['message']}');
        return;
      }
      setState(() => parsed = Map<String, dynamic>.from(d));
      final dest = '${d['destination'] ?? ''}';
      if (dest.isNotEmpty) {
        final search = await app.api
            .get('/v1/places/search?q=${Uri.encodeQueryComponent(dest)}');
        final options = search['places'] as List;
        if (options.isNotEmpty)
          setState(() => place = Map<String, dynamic>.from(options.first));
      }
      await tts.setLanguage(app.language == 'hi' ? 'hi-IN' : 'en-IN');
      await tts.speak('${place?['name'] ?? dest}. ${d['vehicle'] ?? 'Bike'}.');
    } catch (e) {
      setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: Text(app.tr('assistant'))),
      body: SafeArea(
          child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    HaanHeading(app.tr('assistant')),
                    const SizedBox(height: 22),
                    TextField(
                        controller: text,
                        maxLines: 3,
                        decoration: const InputDecoration(
                            hintText: 'Mujhe Howrah station jaana hai…'),
                        onSubmitted: (_) => parse()),
                    const SizedBox(height: 12),
                    FilledButton.icon(onPressed: busy ? null : toggleRecording,
                        icon: Icon(recording ? Icons.stop_circle : Icons.mic_rounded),
                        label: Text(recording ? app.tr('listen') : app.tr('assistant'))),
                    const SizedBox(height: 12),
                    HaanButton(busy ? '…' : app.tr('continue'),
                        onPressed: busy ? null : parse),
                    if (error != null) HaanError(error!),
                    if (parsed != null) ...[
                      const SizedBox(height: 24),
                      Text(app.tr('readBack'),
                          style: Theme.of(context).textTheme.headlineSmall),
                      if (parsed!['needs_clarification'] == true)
                        Text(
                            '${parsed!['clarification_question'] ?? 'Which place?'}'),
                      if (place != null)
                        ListTile(
                            leading: const Icon(Icons.place),
                            title: Text('${place!['name']}'),
                            subtitle: Text('${parsed!['vehicle'] ?? 'Bike'}'),
                            onTap: () => _choosePlace()),
                      if (place == null)
                        TextButton(
                            onPressed: _choosePlace,
                            child: Text(app.tr('search'))),
                      const Spacer(),
                      Row(children: [
                        Expanded(
                            child: OutlinedButton(
                                onPressed: () => Navigator.pop(context),
                                child: Text(app.tr('no')))),
                        const SizedBox(width: 10),
                        Expanded(
                            child: FilledButton(
                                onPressed: place == null
                                    ? null
                                    : () => Navigator.pop(context, {
                                          ...place!,
                                          'vehicle':
                                              parsed?['vehicle'] ?? 'Bike'
                                        }),
                                child: Text(app.tr('confirm'))))
                      ])
                    ]
                  ]))));
  Future<void> _choosePlace() async {
    final p = await showModalBottomSheet<Map<String, dynamic>>(
        context: context,
        isScrollControlled: true,
        builder: (context) => PlacePicker(initial: widget.pickup));
    if (p != null) setState(() => place = p);
  }
}

class TripHistory extends StatefulWidget {
  const TripHistory({super.key});
  @override
  State<TripHistory> createState() => _TripHistoryState();
}

class _TripHistoryState extends State<TripHistory> {
  List<dynamic>? trips;
  String? error;
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
      setState(() => error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: Text(app.tr('history'))),
      body: trips == null
          ? Center(
              child: error != null
                  ? HaanError(error!, retry: load)
                  : const CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: load,
              child: trips!.isEmpty
                  ? ListView(children: [
                      SizedBox(
                          height: MediaQuery.sizeOf(context).height * .55,
                          child: HaanEmpty(app.tr('noTrips')))
                    ])
                  : ListView.builder(
                      itemCount: trips!.length,
                      itemBuilder: (c, i) {
                        final t = trips![i];
                        return Card(
                            margin: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 6),
                            child: ListTile(
                                title: Text(
                                    '${t['pickup_text']} → ${t['drop_text']}',
                                    maxLines: 2),
                                subtitle: Text(
                                    '${t['vehicle_type']} · ${t['status']} · ${t['created_at']}'),
                                trailing: Text(
                                    '₹${t['final_rupees'] ?? t['estimate_rupees']}'),
                                onTap: () => Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                        builder: (_) =>
                                            ReceiptPage(id: '${t['id']}')))));
                      })));
}

class ReceiptPage extends StatefulWidget {
  final String id;
  const ReceiptPage({super.key, required this.id});
  @override
  State<ReceiptPage> createState() => _ReceiptPageState();
}

class _ReceiptPageState extends State<ReceiptPage> {
  Map<String, dynamic>? trip;
  int stars = 0;
  String? error;
  @override
  void initState() {
    super.initState();
    app.api.get('/v1/trips/${widget.id}').then((d) {
      if (mounted) setState(() => trip = Map<String, dynamic>.from(d['trip']));
    }).catchError((e) {
      if (mounted) setState(() => error = '$e');
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: Text(app.tr('history'))),
      body: trip == null
          ? Center(child: Text(error ?? '…'))
          : ListView(padding: const EdgeInsets.all(24), children: [
              HaanHeading(app.tr('completed')),
              const SizedBox(height: 20),
              Card(
                  child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                                '${trip!['pickup_text']} → ${trip!['drop_text']}',
                                style: Theme.of(context).textTheme.titleLarge),
                            const Divider(),
                            Text(
                                '${trip!['vehicle_type']} · ${trip!['completed_at'] ?? trip!['created_at']}'),
                            Text(
                                '₹${trip!['final_rupees'] ?? trip!['estimate_rupees']}',
                                style:
                                    Theme.of(context).textTheme.displaySmall),
                            Text(app.tr('payDirect'))
                          ]))),
              const SizedBox(height: 20),
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
                              if (context.mounted)
                                showMessage(context, app.tr('done'));
                            } catch (e) {
                              if (context.mounted) showMessage(context, '$e');
                            }
                          },
                          icon: Icon(i < stars ? Icons.star : Icons.star_border,
                              color: amber, size: 34)))),
              TextButton(
                  onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => TicketForm(tripId: widget.id))),
                  child: Text(app.tr('help')))
            ]));
}

class CustomerHelp extends StatefulWidget {
  const CustomerHelp({super.key});
  @override
  State<CustomerHelp> createState() => _CustomerHelpState();
}

class _CustomerHelpState extends State<CustomerHelp> {
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
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: Text(app.tr('help'))),
      floatingActionButton: FloatingActionButton.extended(
          onPressed: () async {
            await Navigator.push(
                context, MaterialPageRoute(builder: (_) => const TicketForm()));
            load();
          },
          icon: const Icon(Icons.add),
          label: Text(app.tr('ticket'))),
      body: tickets == null
          ? const Center(child: CircularProgressIndicator())
          : tickets!.isEmpty
              ? HaanEmpty(app.tr('noTickets'), icon: Icons.support_agent)
              : ListView(
                  children: tickets!
                      .map((t) => ListTile(
                          title: Text('${t['subject']}'),
                          subtitle: Text('${t['status']}'),
                          onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) =>
                                      TicketDetail(id: '${t['id']}')))))
                      .toList()));
}

class TicketForm extends StatefulWidget {
  final String? tripId;
  const TicketForm({super.key, this.tripId});
  @override
  State<TicketForm> createState() => _TicketFormState();
}

class _TicketFormState extends State<TicketForm> {
  final subject = TextEditingController(), message = TextEditingController();
  bool busy = false;
  @override
  void dispose() {
    subject.dispose();
    message.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: Text(app.tr('ticket'))),
      body: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(children: [
            TextField(
                controller: subject,
                decoration: const InputDecoration(labelText: 'Subject'),
                maxLength: 120),
            const SizedBox(height: 14),
            TextField(
                controller: message,
                decoration: const InputDecoration(labelText: 'What happened?'),
                maxLines: 5,
                maxLength: 2000),
            const SizedBox(height: 16),
            HaanButton(busy ? '…' : app.tr('send'),
                onPressed: busy
                    ? null
                    : () async {
                        setState(() => busy = true);
                        try {
                          await app.api.post('/v1/tickets', {
                            'subject': subject.text,
                            'message': message.text,
                            if (widget.tripId != null) 'trip_id': widget.tripId
                          });
                          if (context.mounted) Navigator.pop(context);
                        } catch (e) {
                          if (context.mounted) showMessage(context, '$e');
                        } finally {
                          if (mounted) setState(() => busy = false);
                        }
                      })
          ])));
}

class TicketDetail extends StatefulWidget {
  final String id;
  const TicketDetail({super.key, required this.id});
  @override
  State<TicketDetail> createState() => _TicketDetailState();
}

class _TicketDetailState extends State<TicketDetail> {
  Map<String, dynamic>? data;
  final reply = TextEditingController();
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    reply.dispose();
    super.dispose();
  }

  Future<void> load() async {
    try {
      final d = await app.api.get('/v1/tickets/${widget.id}');
      setState(() => data = Map<String, dynamic>.from(d));
    } catch (e) {
      if (mounted) showMessage(context, '$e');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar:
          AppBar(title: Text(data?['ticket']?['subject'] ?? app.tr('help'))),
      body: data == null
          ? const Center(child: CircularProgressIndicator())
          : Column(children: [
              Expanded(
                  child: ListView(
                      padding: const EdgeInsets.all(18),
                      children: (data!['messages'] as List)
                          .map((m) => Card(
                              child: Padding(
                                  padding: const EdgeInsets.all(15),
                                  child: Text('${m['body']}'))))
                          .toList())),
              Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(children: [
                    Expanded(
                        child: TextField(
                            controller: reply,
                            decoration:
                                InputDecoration(hintText: app.tr('send')))),
                    IconButton(
                        onPressed: () async {
                          try {
                            await app.api.post(
                                '/v1/tickets/${widget.id}/messages',
                                {'body': reply.text});
                            reply.clear();
                            load();
                          } catch (e) {
                            if (context.mounted) showMessage(context, '$e');
                          }
                        },
                        icon: const Icon(Icons.send))
                  ]))
            ]));
}

class CustomerProfile extends StatefulWidget {
  const CustomerProfile({super.key});
  @override
  State<CustomerProfile> createState() => _CustomerProfileState();
}

class _CustomerProfileState extends State<CustomerProfile> {
  final name = TextEditingController(), phone = TextEditingController();
  bool loaded = false;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!loaded) {
      name.text = '${app.profile?['name'] ?? ''}';
      phone.text = '${app.profile?['phone'] ?? ''}';
      loaded = true;
    }
  }

  @override
  void dispose() {
    name.dispose();
    phone.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: Text(app.tr('profile'))),
      body: ListView(padding: const EdgeInsets.all(22), children: [
        HaanHeading('Your Haan.'),
        const SizedBox(height: 14),
        Text('${app.profile?['email'] ?? ''}'),
        const SizedBox(height: 24),
        TextField(
            controller: name,
            decoration: InputDecoration(labelText: app.tr('yourName'))),
        const SizedBox(height: 12),
        TextField(
            controller: phone,
            keyboardType: TextInputType.phone,
            decoration: InputDecoration(labelText: app.tr('emergency'))),
        const SizedBox(height: 14),
        HaanButton(app.tr('save'), onPressed: () async {
          try {
            await app.api
                .patch('/v1/profile', {'name': name.text, 'phone': phone.text});
            await app.refreshProfile();
            if (context.mounted) showMessage(context, app.tr('done'));
          } catch (e) {
            if (context.mounted) showMessage(context, '$e');
          }
        }),
        const SizedBox(height: 22),
        ListTile(
            leading: const Icon(Icons.bookmark_border),
            title: Text(app.tr('saved')),
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const SavedPlaces()))),
        ListTile(
            leading: const Icon(Icons.settings_outlined),
            title: Text(app.tr('settings')),
            onTap: () => showPreferences(context, app)),
        ListTile(
            leading: const Icon(Icons.logout),
            title: Text(app.tr('logout')),
            onTap: () => app.logout()),
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
                  await app.logout();
                } catch (e) {
                  if (context.mounted) showMessage(context, '$e');
                }
              }
            })
      ]));
}

class SavedPlaces extends StatefulWidget {
  const SavedPlaces({super.key});
  @override
  State<SavedPlaces> createState() => _SavedPlacesState();
}

class _SavedPlacesState extends State<SavedPlaces> {
  List<dynamic>? places;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final d = await app.api.get('/v1/places/saved');
      setState(() => places = d['places'] as List);
    } catch (e) {
      if (mounted) showMessage(context, '$e');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: Text(app.tr('saved'))),
      floatingActionButton: FloatingActionButton(
          onPressed: () async {
            final p = await showModalBottomSheet<Map<String, dynamic>>(
                context: context,
                isScrollControlled: true,
                builder: (_) => const PlacePicker());
            if (p == null) return;
            final label = await showDialog<String>(
                context: context,
                builder: (c) {
                  final ctl = TextEditingController();
                  return AlertDialog(
                      title: Text(app.tr('saved')),
                      content: TextField(
                          controller: ctl,
                          decoration: InputDecoration(hintText: 'Home / Work')),
                      actions: [
                        TextButton(
                            onPressed: () => Navigator.pop(c),
                            child: Text(app.tr('no'))),
                        FilledButton(
                            onPressed: () => Navigator.pop(c, ctl.text),
                            child: Text(app.tr('save')))
                      ]);
                });
            if (label == null || label.trim().isEmpty) return;
            try {
              await app.api.post('/v1/places/saved', {
                'label': label,
                'lat': p['lat'],
                'lng': p['lng'],
                'text': p['name']
              });
              load();
            } catch (e) {
              if (context.mounted) showMessage(context, '$e');
            }
          },
          child: const Icon(Icons.add)),
      body: places == null
          ? const Center(child: CircularProgressIndicator())
          : places!.isEmpty
              ? HaanEmpty(app.tr('saved'), icon: Icons.bookmark_border)
              : ListView(
                  children: places!
                      .map((p) => ListTile(
                          title: Text('${p['label']}'),
                          subtitle: Text('${p['text']}'),
                          trailing: IconButton(
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () async {
                                await app.api
                                    .delete('/v1/places/saved/${p['id']}');
                                load();
                              })))
                      .toList()));
}
