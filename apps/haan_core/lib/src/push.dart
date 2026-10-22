import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'api.dart';

const firebaseProjectId=String.fromEnvironment('FIREBASE_PROJECT_ID');
const firebaseAppId=String.fromEnvironment('FIREBASE_APP_ID');
const firebaseSenderId=String.fromEnvironment('FIREBASE_SENDER_ID');
const firebaseApiKey=String.fromEnvironment('FIREBASE_API_KEY');

Future<void> registerPush(HaanApi api)async{
  if(firebaseProjectId.isEmpty||firebaseAppId.isEmpty||firebaseSenderId.isEmpty||firebaseApiKey.isEmpty||!api.isSignedIn)return;
  try{
    if(Firebase.apps.isEmpty){await Firebase.initializeApp(options:const FirebaseOptions(apiKey:firebaseApiKey,appId:firebaseAppId,messagingSenderId:firebaseSenderId,projectId:firebaseProjectId));}
    final messaging=FirebaseMessaging.instance;
    await messaging.requestPermission();
    final token=await messaging.getToken();
    if(token!=null)await api.patch('/v1/profile',{'push_token':token});
    messaging.onTokenRefresh.listen((token)async{try{await api.patch('/v1/profile',{'push_token':token});}catch(_){}});
  }catch(_){/* Explicit trips polling remains available when push is unavailable. */}
}
