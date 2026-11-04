import test from 'node:test';
import assert from 'node:assert/strict';
import { validateAuthForm, registrationState } from '../entry/src/main/ets/core/AuthForm.ts';
import { DataValue } from '../entry/src/main/ets/core/Json.ts';

const form = (changes = {}) => ({ mode: 'login', email: 'qa@example.invalid', password: 'fixture-password', confirmation: 'fixture-password', agreed: true, registration: 'open', ...changes });
test('agreement guards login and registration, but password reset does not require agreement', () => {
  assert.match(validateAuthForm(form({ agreed: false })), /请先阅读/);
  assert.match(validateAuthForm(form({ mode: 'register', agreed: false })), /请先阅读/);
  assert.equal(validateAuthForm(form({ mode: 'reset', agreed: false, password: '' })), '');
});
test('email is trimmed for validation; invalid addresses cannot submit', () => {
  assert.equal(validateAuthForm(form({ email: ' qa@example.invalid ' })), '');
  for (const email of ['', 'qa', 'qa@', ' @ ']) assert.match(validateAuthForm(form({ email })), /邮箱/);
});
test('registration remains blocked for loading, unavailable, closed and malformed server state', () => {
  for (const registration of ['loading', 'unavailable', 'closed']) assert.notEqual(validateAuthForm(form({ mode: 'register', registration })), '');
  assert.equal(registrationState(DataValue.object({ open_registration: true })), 'open');
  assert.equal(registrationState(DataValue.object({ open_registration: false })), 'closed');
  for (const value of [{}, { open_registration: 'true' }, { open_registration: 1 }]) assert.equal(registrationState(DataValue.object(value)), 'unavailable');
});
test('new passwords require eight characters and matching confirmation', () => {
  assert.match(validateAuthForm(form({ mode: 'register', password: '1234567' })), /至少8位/);
  assert.match(validateAuthForm(form({ mode: 'register', confirmation: 'different' })), /不一致/);
  assert.equal(validateAuthForm(form({ mode: 'register' })), '');
  assert.equal(validateAuthForm(form({ mode: 'confirm', email: '', agreed: false })), '');
});
