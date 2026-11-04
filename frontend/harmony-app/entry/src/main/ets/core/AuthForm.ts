import { DataValue } from './Json';

export interface AuthFormInput {
  mode: string;
  email: string;
  password: string;
  confirmation: string;
  agreed: boolean;
  registration: string;
}
export function registrationState(value: DataValue): string {
  const raw = value.get('open_registration').raw;
  return raw === true ? 'open' : raw === false ? 'closed' : 'unavailable';
}
export function validateAuthForm(input: AuthFormInput): string {
  if (input.mode === 'register' && input.registration !== 'open') {
    return input.registration === 'closed' ? '暂未开放注册，请联系管理员' : input.registration === 'loading' ? '正在确认注册状态…' : '暂时无法获取注册状态，请重试';
  }
  if ((input.mode === 'login' || input.mode === 'register') && !input.agreed) return '请先阅读并同意用户协议和隐私政策';
  const email = input.email.trim();
  if (input.mode !== 'confirm' && (!email.includes('@') || email.endsWith('@') || email.startsWith('@'))) return '请输入有效的邮箱地址';
  if (input.mode === 'register' || input.mode === 'confirm') {
    if (input.password.length < 8) return '密码至少8位';
    if (input.password !== input.confirmation) return '两次密码不一致';
  }
  if (input.mode === 'login' && !input.password) return '请输入密码';
  return '';
}
