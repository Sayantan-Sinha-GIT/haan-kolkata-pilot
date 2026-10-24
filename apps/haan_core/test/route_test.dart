import 'package:flutter_test/flutter_test.dart';
import 'package:haan_core/haan_core.dart';

void main() {
  test('decodes an encoded directions polyline', () {
    final route = decodePolyline('_p~iF~ps|U_ulLnnqC_mqNvxq`@');
    expect(route.length, 3);
    expect(route[0].latitude, closeTo(38.5, 0.00001));
    expect(route[0].longitude, closeTo(-120.2, 0.00001));
    expect(route[2].latitude, closeTo(43.252, 0.00001));
  });
  test('Google Maps URL goes directly to the requested coordinate', () {
    final pickup=googleMapsDirections(lat:22.5726,lng:88.3639,bike:true);
    final drop=googleMapsDirections(lat:22.5839,lng:88.3425,bike:false);
    expect(pickup.host,'www.google.com');
    expect(pickup.queryParameters['api'],'1');
    expect(pickup.queryParameters['destination'],'22.5726,88.3639');
    expect(pickup.queryParameters['travelmode'],'two-wheeler');
    expect(pickup.queryParameters['dir_action'],'navigate');
    expect(drop.queryParameters['destination'],'22.5839,88.3425');
    expect(drop.queryParameters['travelmode'],'driving');
    expect(() => googleMapsDirections(lat:100,lng:88,bike:false),throwsArgumentError);
  });
}
