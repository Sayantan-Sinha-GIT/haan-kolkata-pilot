export const COMMISSION_PERCENT = 20;

export function settlementForFare(grossFare: number, customerFare: number) {
  if (!Number.isInteger(grossFare) || !Number.isInteger(customerFare) ||
      customerFare < 1 || customerFare > grossFare) throw new Error('invalid_settlement_fare');
  // The rider's promised earnings are based on the undiscounted fare.
  const platformFee = Math.round(customerFare * COMMISSION_PERCENT / 100);
  const riderEarnings = grossFare - Math.round(grossFare * COMMISSION_PERCENT / 100);
  const promotionTopup = Math.max(0, riderEarnings - (customerFare - platformFee));
  // Positive: rider remits Haan. Negative: Haan pays the rider.
  const netDueToPlatform = customerFare - riderEarnings;
  return { platformFee, riderEarnings, promotionTopup, netDueToPlatform };
}
