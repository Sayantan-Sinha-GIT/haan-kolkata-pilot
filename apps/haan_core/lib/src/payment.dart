/// Builds a direct UPI request to the driver's own account. Haan never receives
/// funds or treats opening this link as proof that the driver was paid.
Uri? directUpiUri({required String? upiId, required String? name, required int amount}) {
  final handle=upiId?.trim()??'';
  if (!RegExp(r'^[A-Za-z0-9._-]{2,64}@[A-Za-z0-9.-]{2,32}$').hasMatch(handle)
      || amount<1 || amount>100000) return null;
  return Uri(scheme:'upi',host:'pay',queryParameters:{
    'pa':handle,
    'pn':(name?.trim().isNotEmpty??false)?name!.trim():'Haan driver',
    'am':'$amount',
    'cu':'INR',
    'tn':'Haan trip fare',
  });
}
