import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

const apiBaseUrl = String.fromEnvironment('API_BASE_URL');
const downloadBaseUrl = String.fromEnvironment('DOWNLOAD_URL');

class ApiException implements Exception {
  final String message;
  final String code;
  final int status;
  final int? attemptsLeft;
  const ApiException(this.message, this.code, this.status, [this.attemptsLeft]);
  @override String toString() => message;
}

class HaanApi {
  final _storage = const FlutterSecureStorage();
  String? _access;
  String? _refresh;
  final http.Client _client;
  HaanApi({http.Client? client}) : _client = client ?? http.Client();
  bool get isSignedIn => _refresh != null;
  Future<void> load() async {
    _access = await _storage.read(key: 'access');
    _refresh = await _storage.read(key: 'refresh');
  }
  Future<void> saveTokens(Map<String, dynamic> data) async {
    _access = data['access_token'] as String?;
    _refresh = data['refresh_token'] as String?;
    if (_access != null) await _storage.write(key: 'access', value: _access);
    if (_refresh != null) await _storage.write(key: 'refresh', value: _refresh);
  }
  Future<void> signOut() async {
    final token = _refresh;
    if (token != null) { try { await post('/v1/auth/logout', {'refresh_token': token}); } catch (_) {} }
    _access = null; _refresh = null;
    await _storage.delete(key: 'access'); await _storage.delete(key: 'refresh');
  }
  Future<dynamic> get(String path) => _send('GET', path);
  Future<dynamic> post(String path, Object body) => _send('POST', path, body: body);
  Future<dynamic> patch(String path, Object body) => _send('PATCH', path, body: body);
  Future<dynamic> delete(String path) => _send('DELETE', path);
  Future<dynamic> uploadBytes(String path, List<int> bytes, String contentType) => _send('POST', path, bytes: bytes, contentType: contentType);
  Future<List<int>> getBytes(String path, {bool retried = false}) async {
    if (apiBaseUrl.isEmpty) throw const ApiException('The service address has not been configured.', 'not_configured', 0);
    final response = await _client.get(Uri.parse('$apiBaseUrl$path'), headers: {
      if (_access != null) 'Authorization': 'Bearer $_access',
    }).timeout(const Duration(seconds: 20));
    if (response.statusCode == 401 && !retried && _refresh != null) {
      final renewed = await _send('POST','/v1/auth/refresh',body:{'refresh_token':_refresh,'device':'Android'},retried:true);
      await saveTokens(Map<String,dynamic>.from(renewed));
      return getBytes(path,retried:true);
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException('Photo unavailable. Check your connection.', 'photo_unavailable', response.statusCode);
    }
    return response.bodyBytes;
  }
  Future<String> transcribeAudio(String filePath) async {
    if (apiBaseUrl.isEmpty) throw const ApiException('The service address has not been configured.', 'not_configured', 0);
    final file = File(filePath);
    if (await file.length() > 1000000) throw const ApiException('Record up to 15 seconds.', 'audio_too_large', 413);
    final request=http.MultipartRequest('POST',Uri.parse('$apiBaseUrl/v1/assistant/transcribe'));
    if(_access!=null)request.headers['Authorization']='Bearer $_access';
    request.files.add(await http.MultipartFile.fromPath('audio',filePath,filename:'request.m4a'));
    final response=await http.Response.fromStream(await _client.send(request).timeout(const Duration(seconds:20)));
    final decoded=jsonDecode(response.body) as Map<String,dynamic>;
    if(response.statusCode<200||response.statusCode>=300)throw ApiException('${decoded['error']??'Voice is unavailable. Please type.'}','${decoded['code']??'voice_error'}',response.statusCode);
    return '${decoded['text']??''}';
  }
  Future<dynamic> _send(String method, String path, {Object? body, List<int>? bytes, String? contentType, bool retried = false}) async {
    if (apiBaseUrl.isEmpty) throw const ApiException('The service address has not been configured.', 'not_configured', 0);
    final uri = Uri.parse('$apiBaseUrl$path');
    http.Response response;
    try {
      response = await _client.send(http.Request(method, uri)
        ..headers.addAll({'Accept':'application/json', if (_access != null) 'Authorization':'Bearer $_access', if (body != null) 'Content-Type':'application/json', if (bytes != null) 'Content-Type': contentType ?? 'image/jpeg'})
        ..bodyBytes = bytes ?? (body != null ? utf8.encode(jsonEncode(body)) : <int>[])).then(http.Response.fromStream).timeout(const Duration(seconds: 20));
    } on SocketException { throw const ApiException('No network. Reconnect and try again.', 'offline', 0); }
      on TimeoutException { throw const ApiException('The connection is slow. Please retry.', 'timeout', 0); }
    if (response.statusCode == 401 && !retried && _refresh != null && path != '/v1/auth/refresh') {
      try {
        final renewed = await _send('POST','/v1/auth/refresh',body:{'refresh_token':_refresh,'device':'Android'},retried:true);
        await saveTokens(Map<String,dynamic>.from(renewed));
      } catch (_) { await _storage.deleteAll(); _access=null; _refresh=null; }
      if (_access != null) return await _send(method,path,body:body,bytes:bytes,contentType:contentType,retried:true);
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final d = decoded is Map ? decoded : <String,dynamic>{};
      throw ApiException('${d['error'] ?? 'Request failed. Please retry.'}', '${d['code'] ?? 'error'}', response.statusCode, d['attempts_left'] as int?);
    }
    return decoded;
  }
}
