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
}
