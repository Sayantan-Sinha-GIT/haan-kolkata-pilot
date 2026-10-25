import 'package:flutter_test/flutter_test.dart';
import 'package:haan_core/haan_core.dart';

void main(){
  test('direct UPI link encodes recipient and amount',(){
    final uri=directUpiUri(upiId:'driver.123@upi',name:'Asha Roy',amount:146)!;
    expect(uri.scheme,'upi');
    expect(uri.host,'pay');
    expect(uri.queryParameters['pa'],'driver.123@upi');
    expect(uri.queryParameters['pn'],'Asha Roy');
    expect(uri.queryParameters['am'],'146');
  });
  test('rejects bad handles and amounts',(){
    expect(directUpiUri(upiId:'bad &am=1',name:null,amount:100),isNull);
    expect(directUpiUri(upiId:'driver@upi',name:null,amount:0),isNull);
  });
}
