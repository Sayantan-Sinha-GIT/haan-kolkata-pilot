import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api.dart';
import 'push.dart';

class HaanState extends ChangeNotifier {
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
    final prefs=await SharedPreferences.getInstance();
    language=prefs.getString('language')??'en';
    themeMode=switch(prefs.getString('theme')){'light'=>ThemeMode.light,'system'=>ThemeMode.system,_=>ThemeMode.dark};
    await api.load(); signedIn=api.isSignedIn;
    try { final config=await api.get('/v1/config');updateRequired=(config['minimum_versions']?[role] as num? ?? 1)>1; } catch (_) {}
    if(signedIn) { try { await refreshProfile(); await registerPush(api); } catch (_) {} }
    ready=true; notifyListeners();
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
  Future<void> logout() async { await api.signOut(); signedIn=false;profile=null;notifyListeners(); }
  Future<void> setLanguage(String value) async {
    language=value; final prefs=await SharedPreferences.getInstance();await prefs.setString('language',value);notifyListeners();
    if(signedIn) await api.patch('/v1/profile',{'language':value});
  }
  Future<void> setTheme(ThemeMode value) async {
    themeMode=value;final prefs=await SharedPreferences.getInstance();await prefs.setString('theme',value.name);notifyListeners();
    if(signedIn) await api.patch('/v1/profile',{'theme':value.name});
  }
  String tr(String key) => words[language]?[key] ?? words['en']?[key] ?? key;
}

const words=<String,Map<String,String>>{
'en':{
'welcome':'Say where. Say haan. Ride.','continue':'Continue','email':'Email address','sendCode':'Send code','code':'Six-digit code','verify':'Verify code','resend':'Resend code','yourName':'Your name','save':'Save','whereTo':'Where to?','pickup':'Pickup','destination':'Destination','search':'Search','mapPin':'Choose on map','bike':'Bike','auto':'Auto','cab':'Cab','estimate':'Estimated fare','book':'Book ride','confirm':'Haan, book','no':'Nahi','finding':'Finding a rider','riderAssigned':'Rider on the way','arrived':'Rider arrived','inProgress':'Trip in progress','completed':'Trip complete','pin':'Tell your rider this PIN','cancel':'Cancel trip','history':'Trips','help':'Help','profile':'Profile','settings':'Settings','language':'Language','theme':'Theme','dark':'Dark','light':'Light','system':'System','logout':'Sign out','retry':'Try again','offline':'No network. Connect to book a ride.','gpsOff':'Location is off. Choose your pickup manually.','saved':'Saved places','home':'Home','work':'Work','fare':'Fare','payDirect':'Pay the rider directly by cash or UPI.','rate':'Rate this trip','ticket':'Support ticket','send':'Send','delete':'Delete account','emergency':'Emergency contact','sos':'Call 112','share':'Share trip','assistant':'Speak or type your trip','listen':'Listening…','readBack':'Please confirm your trip','back':'Back','done':'Done','update':'Update required','updateBody':'Install the latest APK to continue.','online':'Go online','offlineRider':'Go offline','approval':'Verification','pending':'Waiting for review','approved':'Approved','rejected':'Changes needed','documents':'Documents','licence':'Driving licence','rc':'Registration certificate','selfie':'Selfie','vehicle':'Vehicle','vehicleNumber':'Vehicle number','offer':'New trip request','accept':'Accept','decline':'Decline','navigate':'Navigate','start':'Start trip','end':'End trip','earnings':'Earnings','today':'Today','week':'This week','upi':'UPI ID','wrongPin':'Wrong PIN. Try again.','collect':'Collect payment','contact':'Call customer','lowData':'Low-data mode','status':'Status','noTrips':'No trips yet. Your next trip will appear here.','noOffers':'Stay online. New requests appear here.','noTickets':'No support requests yet.','confirmDelete':'Delete this account and anonymise trip history?','yesDelete':'Delete my account','noResults':'No places found. Try another landmark or choose on map.'
},
'hi':{
'welcome':'जगह बताइए। हाँ कहिए। चलिए।','continue':'आगे बढ़ें','email':'ईमेल पता','sendCode':'कोड भेजें','code':'छह अंकों का कोड','verify':'कोड जाँचें','resend':'फिर कोड भेजें','yourName':'आपका नाम','save':'सहेजें','whereTo':'कहाँ जाना है?','pickup':'कहाँ से','destination':'कहाँ तक','search':'खोजें','mapPin':'नक्शे पर चुनें','bike':'बाइक','auto':'ऑटो','cab':'कैब','estimate':'अनुमानित किराया','book':'राइड बुक करें','confirm':'हाँ, बुक करें','no':'नहीं','finding':'राइडर खोज रहे हैं','riderAssigned':'राइडर आ रहे हैं','arrived':'राइडर पहुँच गए','inProgress':'सफ़र चल रहा है','completed':'सफ़र पूरा हुआ','pin':'राइडर को यह पिन बताएँ','cancel':'राइड रद्द करें','history':'यात्राएँ','help':'मदद','profile':'प्रोफ़ाइल','settings':'सेटिंग','language':'भाषा','theme':'रंग','dark':'गहरा','light':'हल्का','system':'फ़ोन जैसा','logout':'साइन आउट','retry':'फिर कोशिश करें','offline':'इंटरनेट नहीं है। राइड बुक करने के लिए जुड़ें।','gpsOff':'लोकेशन बंद है। पिकअप जगह खुद चुनें।','saved':'सहेजी जगहें','home':'घर','work':'काम','fare':'किराया','payDirect':'राइडर को सीधे नकद या UPI से भुगतान करें।','rate':'इस यात्रा को रेट करें','ticket':'सहायता अनुरोध','send':'भेजें','delete':'खाता मिटाएँ','emergency':'आपातकालीन संपर्क','sos':'112 पर कॉल','share':'यात्रा साझा करें','assistant':'बोलकर या लिखकर बताइए','listen':'सुन रहे हैं…','readBack':'अपनी यात्रा पक्की करें','back':'वापस','done':'हो गया','update':'नया ऐप ज़रूरी है','updateBody':'आगे बढ़ने के लिए नया APK इंस्टॉल करें।','online':'ऑनलाइन जाएँ','offlineRider':'ऑफ़लाइन जाएँ','approval':'जाँच','pending':'जाँच बाकी है','approved':'मंज़ूर','rejected':'बदलाव ज़रूरी','documents':'दस्तावेज़','licence':'ड्राइविंग लाइसेंस','rc':'रजिस्ट्रेशन सर्टिफिकेट','selfie':'सेल्फ़ी','vehicle':'गाड़ी','vehicleNumber':'गाड़ी का नंबर','offer':'नई राइड आई है','accept':'स्वीकारें','decline':'मना करें','navigate':'रास्ता देखें','start':'यात्रा शुरू करें','end':'यात्रा खत्म करें','earnings':'कमाई','today':'आज','week':'इस हफ़्ते','upi':'UPI ID','wrongPin':'पिन गलत है। फिर कोशिश करें।','collect':'भुगतान लें','contact':'ग्राहक को कॉल करें','lowData':'कम डेटा मोड','status':'स्थिति','noTrips':'अभी कोई यात्रा नहीं। अगली यात्रा यहाँ दिखेगी।','noOffers':'ऑनलाइन रहें। नई राइड यहाँ दिखेगी।','noTickets':'अभी कोई सहायता अनुरोध नहीं।','confirmDelete':'खाता मिटाएँ और यात्राओं का निजी विवरण हटाएँ?','yesDelete':'मेरा खाता मिटाएँ','noResults':'जगह नहीं मिली। दूसरा नाम लिखें या नक्शे पर चुनें।'
}};
