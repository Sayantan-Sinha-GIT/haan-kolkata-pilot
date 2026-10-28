import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'api.dart';
import 'push.dart';

class HaanState extends ChangeNotifier {
  static const googleServerClientId='12811346961-e4vs52ga2cnsen7vvt0hg4c9atafntoa.apps.googleusercontent.com';
  Future<void>? _googleReady;
  final String role;
  HaanState({required this.role});
  final HaanApi api = HaanApi();
  String language = 'en';
  ThemeMode themeMode = ThemeMode.dark;
  bool ready = false;
  bool signedIn = false;
  bool updateRequired = false;
  Map<String,dynamic>? profile;
  Future<void> init() async {
    try {
      try {
        final prefs=await SharedPreferences.getInstance();
        language=prefs.getString('language')??'en';
        themeMode=switch(prefs.getString('theme')){'light'=>ThemeMode.light,'system'=>ThemeMode.system,_=>ThemeMode.dark};
      } catch (_) { /* Local display preferences must not block sign-in. */ }
      try { await api.load(); signedIn=api.isSignedIn; } catch (_) { signedIn=false; }
      // The sign-in screen can open while the remote version check runs.
      unawaited(_checkUpdate());
      if(signedIn) { try { await refreshProfile(); await registerPush(api); } catch (_) {} }
    } finally { ready=true; notifyListeners(); }
  }
  Future<void> _checkUpdate() async {
    try {
      final config=await api.get('/v1/config');
      final installed=int.tryParse((await PackageInfo.fromPlatform()).buildNumber)??1;
      // Flutter split APKs prefix the base build number with an ABI code.
      final build=installed>=1000?installed%1000:installed;
      updateRequired=(config['minimum_versions']?[role] as num? ?? 1)>build;
      notifyListeners();
    } catch (_) { /* A network error must not block the installed app. */ }
  }
  Future<void> refreshProfile() async {
    final result=await api.get('/v1/profile');
    profile=Map<String,dynamic>.from(result['profile']);
    language='${profile?['language']??language}';
    notifyListeners();
  }
  Future<void> login(String email,String code,String role) async {
    final tokens=await api.post('/v1/auth/verify-otp',{'email':email,'code':code,'role':role,'device':'Android'});
    await api.saveTokens(Map<String,dynamic>.from(tokens));
    signedIn=true;await refreshProfile();await registerPush(api);notifyListeners();
  }
  Future<bool> googleLogin() async {
    final firebaseApp=await ensureFirebase();
    _googleReady??=GoogleSignIn.instance.initialize(serverClientId:googleServerClientId);
    await _googleReady;
    GoogleSignInAccount account;
    try{account=await GoogleSignIn.instance.authenticate();}
    on GoogleSignInException catch(e){
      if(e.code==GoogleSignInExceptionCode.canceled)return false;
      rethrow;
    }
    try{
      final credential=GoogleAuthProvider.credential(idToken:account.authentication.idToken);
      final firebaseUser=await FirebaseAuth.instanceFor(app:firebaseApp).signInWithCredential(credential);
      final idToken=await firebaseUser.user?.getIdToken(true);
      if(idToken==null)throw StateError('Google did not return a sign-in token.');
      final tokens=await api.post('/v1/auth/google',{'id_token':idToken,'role':role,'device':'Android Google'});
      await api.saveTokens(Map<String,dynamic>.from(tokens));
      signedIn=true;await refreshProfile();await registerPush(api);notifyListeners();
      return true;
    }catch(_){
      await FirebaseAuth.instanceFor(app:firebaseApp).signOut();
      rethrow;
    }
  }
  Future<void> logout() async {
    await api.signOut();
    if(Firebase.apps.isNotEmpty){try{await FirebaseAuth.instance.signOut();}catch(_){}}
    if(_googleReady!=null){try{await GoogleSignIn.instance.signOut();}catch(_){}}
    signedIn=false;profile=null;notifyListeners();
  }
  Future<void> setLanguage(String value) async {
    language=value;notifyListeners();
    try { final prefs=await SharedPreferences.getInstance();await prefs.setString('language',value); } catch (_) {}
    if(signedIn) await api.patch('/v1/profile',{'language':value});
  }
  Future<void> setTheme(ThemeMode value) async {
    themeMode=value;notifyListeners();
    try { final prefs=await SharedPreferences.getInstance();await prefs.setString('theme',value.name); } catch (_) {}
    if(signedIn) await api.patch('/v1/profile',{'theme':value.name});
  }
  String tr(String key) => words[language]?[key] ?? words['en']?[key] ?? key;
}

const words=<String,Map<String,String>>{
'en':{
'welcome':'Say where. Say haan. Ride.','continue':'Continue','email':'Email address','sendCode':'Send code','code':'Six-digit code','verify':'Verify code','resend':'Resend code','yourName':'Your name','save':'Save','whereTo':'Where to?','pickup':'Pickup','destination':'Destination','search':'Search','mapPin':'Choose on map','bike':'Bike','auto':'Auto','cab':'Cab','estimate':'Estimated fare','book':'Book ride','confirm':'Haan, book','no':'No','finding':'Finding a rider','riderAssigned':'Rider on the way','arrived':'Rider arrived','inProgress':'Trip in progress','completed':'Trip complete','pin':'Tell your rider this PIN','cancel':'Cancel trip','history':'Trips','help':'Help','profile':'Profile','settings':'Settings','language':'Language','theme':'Theme','dark':'Dark','light':'Light','system':'System','logout':'Sign out','retry':'Try again','offline':'No network. Connect to book a ride.','gpsOff':'Location is off. Choose your pickup manually.','saved':'Saved places','home':'Home','work':'Work','fare':'Fare','payDirect':'Pay the rider directly by cash or UPI.','rate':'Rate this trip','ticket':'Support ticket','send':'Send','delete':'Delete account','emergency':'Emergency contact','sos':'Call 112','share':'Share trip','assistant':'Speak or type your trip','listen':'Listening…','readBack':'Please confirm your trip','back':'Back','done':'Done','update':'Update required','updateBody':'Install the latest APK to continue.','online':'Go online','offlineRider':'Go offline','approval':'Verification','pending':'Waiting for review','approved':'Approved','rejected':'Changes needed','documents':'Documents','licence':'Driving licence','rc':'Registration certificate','selfie':'Selfie','insurance':'Vehicle insurance','permit':'Commercial permit','vehicle':'Vehicle','vehicleNumber':'Vehicle number','offer':'New trip request','accept':'Accept','decline':'Decline','navigate':'Navigate','start':'Start trip','end':'End trip','earnings':'Earnings','today':'Today','week':'This week','upi':'UPI ID','wrongPin':'Wrong PIN. Try again.','collect':'Collect payment','contact':'Call customer','lowData':'Low-data mode','status':'Status','noTrips':'No trips yet. Your next trip will appear here.','noOffers':'Stay online. New requests appear here.','noTickets':'No support requests yet.','confirmDelete':'Delete this account and anonymise trip history?','yesDelete':'Delete my account','noResults':'No places found. Try another landmark or choose on map.','phone':'Mobile number','phoneHelp':'For trip calls. Indian mobile number.','vehicleMake':'Make (e.g. Maruti)','vehicleModel':'Model (e.g. WagonR)','vehicleColor':'Colour','vehicleYear':'Year','licenceNumber':'Licence number','insuranceExpiry':'Insurance valid until','permitExpiry':'Permit valid until','documentsHelp':'Upload clear photos. Insurance is required; Auto and Cab also need a permit.','pickupNote':'Pickup instructions (optional)','pickupNoteHint':'Gate, landmark or where to meet','navigatePickup':'Google Maps to pickup','navigateDrop':'Google Maps to drop','askPin':'Ask customer for PIN to start','verifyPlate':'Check the plate before boarding.','callDriver':'Call driver'
},
'hi':{
'welcome':'जगह बताइए। हाँ कहिए। चलिए।','continue':'आगे बढ़ें','email':'ईमेल पता','sendCode':'कोड भेजें','code':'छह अंकों का कोड','verify':'कोड जाँचें','resend':'फिर कोड भेजें','yourName':'आपका नाम','save':'सहेजें','whereTo':'कहाँ जाना है?','pickup':'कहाँ से','destination':'कहाँ तक','search':'खोजें','mapPin':'नक्शे पर चुनें','bike':'बाइक','auto':'ऑटो','cab':'कैब','estimate':'अनुमानित किराया','book':'राइड बुक करें','confirm':'हाँ, बुक करें','no':'नहीं','finding':'राइडर खोज रहे हैं','riderAssigned':'राइडर आ रहे हैं','arrived':'राइडर पहुँच गए','inProgress':'सफ़र चल रहा है','completed':'सफ़र पूरा हुआ','pin':'राइडर को यह पिन बताएँ','cancel':'राइड रद्द करें','history':'यात्राएँ','help':'मदद','profile':'प्रोफ़ाइल','settings':'सेटिंग','language':'भाषा','theme':'रंग','dark':'गहरा','light':'हल्का','system':'फ़ोन जैसा','logout':'साइन आउट','retry':'फिर कोशिश करें','offline':'इंटरनेट नहीं है। राइड बुक करने के लिए जुड़ें।','gpsOff':'लोकेशन बंद है। पिकअप जगह खुद चुनें।','saved':'सहेजी जगहें','home':'घर','work':'काम','fare':'किराया','payDirect':'राइडर को सीधे नकद या UPI से भुगतान करें।','rate':'इस यात्रा को रेट करें','ticket':'सहायता अनुरोध','send':'भेजें','delete':'खाता मिटाएँ','emergency':'आपातकालीन संपर्क','sos':'112 पर कॉल','share':'यात्रा साझा करें','assistant':'बोलकर या लिखकर बताइए','listen':'सुन रहे हैं…','readBack':'अपनी यात्रा पक्की करें','back':'वापस','done':'हो गया','update':'नया ऐप ज़रूरी है','updateBody':'आगे बढ़ने के लिए नया APK इंस्टॉल करें।','online':'ऑनलाइन जाएँ','offlineRider':'ऑफ़लाइन जाएँ','approval':'जाँच','pending':'जाँच बाकी है','approved':'मंज़ूर','rejected':'बदलाव ज़रूरी','documents':'दस्तावेज़','licence':'ड्राइविंग लाइसेंस','rc':'रजिस्ट्रेशन सर्टिफिकेट','selfie':'सेल्फ़ी','vehicle':'गाड़ी','vehicleNumber':'गाड़ी का नंबर','offer':'नई राइड आई है','accept':'स्वीकारें','decline':'मना करें','navigate':'रास्ता देखें','start':'यात्रा शुरू करें','end':'यात्रा खत्म करें','earnings':'कमाई','today':'आज','week':'इस हफ़्ते','upi':'UPI ID','wrongPin':'पिन गलत है। फिर कोशिश करें।','collect':'भुगतान लें','contact':'ग्राहक को कॉल करें','lowData':'कम डेटा मोड','status':'स्थिति','noTrips':'अभी कोई यात्रा नहीं। अगली यात्रा यहाँ दिखेगी।','noOffers':'ऑनलाइन रहें। नई राइड यहाँ दिखेगी।','noTickets':'अभी कोई सहायता अनुरोध नहीं।','confirmDelete':'खाता मिटाएँ और यात्राओं का निजी विवरण हटाएँ?','yesDelete':'मेरा खाता मिटाएँ','noResults':'जगह नहीं मिली। दूसरा नाम लिखें या नक्शे पर चुनें।','phone':'मोबाइल नंबर','phoneHelp':'राइड के दौरान कॉल के लिए भारतीय मोबाइल नंबर।','vehicleMake':'कंपनी','vehicleModel':'मॉडल','vehicleColor':'रंग','vehicleYear':'वर्ष','licenceNumber':'लाइसेंस नंबर','insuranceExpiry':'बीमा कब तक मान्य है','permitExpiry':'परमिट कब तक मान्य है','insurance':'वाहन बीमा','permit':'व्यावसायिक परमिट','documentsHelp':'साफ़ फ़ोटो अपलोड करें। बीमा ज़रूरी है; ऑटो और कैब के लिए परमिट भी।','pickupNote':'पिकअप निर्देश (वैकल्पिक)','pickupNoteHint':'गेट या मिलने की जगह','navigatePickup':'Google Maps से पिकअप जाएँ','navigateDrop':'Google Maps से ड्रॉप जाएँ','askPin':'ग्राहक से PIN लेकर सफ़र शुरू करें','verifyPlate':'बैठने से पहले नंबर प्लेट जाँचें।','callDriver':'ड्राइवर को कॉल करें'
}};
