import { randomBytes } from 'crypto';

const ALPHA_NUMERIC = 'abcdefghijklmnopqrstuvwxyz0123456789';

export function randomString(length: number, charset = ALPHA_NUMERIC): string {
  const bytes = randomBytes(length * 2);
  let result = '';
  for (let i = 0; i < length; i++) {
    result += charset[bytes[i] % charset.length];
  }
  return result;
}
