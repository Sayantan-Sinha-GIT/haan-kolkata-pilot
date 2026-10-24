/// Opens turn-by-turn directions to the active trip's next stop in Google Maps.
/// The destination is a coordinate so a landmark name cannot resolve elsewhere.
Uri googleMapsDirections({required double lat, required double lng, required bool bike}) {
  if (!lat.isFinite || !lng.isFinite || lat.abs() > 90 || lng.abs() > 180) {
    throw ArgumentError('Invalid navigation destination');
  }
  return Uri.https('www.google.com', '/maps/dir/', {
    'api': '1',
    'destination': '$lat,$lng',
    'travelmode': bike ? 'two-wheeler' : 'driving',
    'dir_action': 'navigate',
  });
}
