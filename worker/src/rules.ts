export type Vehicle = 'Bike' | 'Auto' | 'Cab';
export type Fare = { base: number; per_km: number; per_min: number; minimum: number };
export const DEFAULT_FARES: Record<Vehicle, Fare> = {
  Bike: { base: 20, per_km: 6, per_min: 0.5, minimum: 30 },
  Auto: { base: 30, per_km: 10, per_min: 1, minimum: 40 },
  Cab: { base: 50, per_km: 14, per_min: 1.5, minimum: 80 },
};
export function fare(config: Fare, km: number, minutes: number): number {
  if (!Number.isFinite(km) || !Number.isFinite(minutes) || km < 0 || minutes < 0) throw new Error('invalid_distance');
  return Math.round(Math.max(config.minimum, config.base + config.per_km * km + config.per_min * minutes));
}
export function haversineKm(a: { lat: number; lng: number }, b: { lat: number; lng: number }): number {
  const rad = Math.PI / 180;
  const dLat = (b.lat - a.lat) * rad;
  const dLng = (b.lng - a.lng) * rad;
  const v = Math.sin(dLat / 2) ** 2 + Math.cos(a.lat * rad) * Math.cos(b.lat * rad) * Math.sin(dLng / 2) ** 2;
  return 6371 * 2 * Math.asin(Math.min(1, Math.sqrt(v)));
}
export function validCoordinates(lat: unknown, lng: unknown): lat is number {
  return typeof lat === 'number' && Number.isFinite(lat) && lat >= -90 && lat <= 90
    && typeof lng === 'number' && Number.isFinite(lng) && lng >= -180 && lng <= 180;
}
export function validPoint(v: unknown): v is { lat: number; lng: number; text: string } {
  if (!v || typeof v !== 'object') return false;
  const p = v as Record<string, unknown>;
  return validCoordinates(p.lat,p.lng) && typeof p.text === 'string' && p.text.trim().length > 1 && p.text.length <= 240;
}
export function scrubAssistantText(text: string): string {
  return text.replace(/\b[6-9]\d{9}\b/g, '[phone]').replace(/[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}/g, '[email]').slice(0, 600);
}
export const ACTIVE_STATUSES = ['searching', 'accepted', 'arrived', 'in_progress'] as const;

