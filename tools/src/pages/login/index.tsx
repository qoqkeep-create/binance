import { useState, useEffect } from 'react'
import { useNavigate, Link, useSearchParams } from 'react-router-dom'
import { TrendingUp } from 'lucide-react'
import { useAuthStore, showToast } from '@/shared/store'
import { api, ApiError } from '@/shared/lib/api'
import { primeAppViewport } from '@/shared/lib/device'

type AuthView = 'login' | 'register' | 'reset-request' | 'reset-confirm'

export function LoginPage() {
  const navigate = useNavigate()
  const [searchParams, setSearchParams] = useSearchParams()
  const login = useAuthStore(state => state.login)
  const resetUid = searchParams.get('reset_uid') || ''
  const resetToken = searchParams.get('reset_token') || ''
  const hasResetLink = Boolean(resetUid && resetToken)
  const [currentView, setCurrentView] = useState<AuthView>(() => hasResetLink ? 'reset-confirm' : 'login')
  const [agreed, setAgreed] = useState(true)
  const [showAgreementPrompt, setShowAgreementPrompt] = useState(false)
  const [submittingLogin, setSubmittingLogin] = useState(false)

  // 登录表单状态
  const [loginForm, setLoginForm] = useState({ account: '', password: '' })
  const [registerForm, setRegisterForm] = useState({
    email: '', password: '', confirmPassword: '',
  })
  const [resetForm, setResetForm] = useState({ email: '', newPassword: '', confirmPassword: '' })
  const [resetEmailSent, setResetEmailSent] = useState(false)
  const [submittingReset, setSubmittingReset] = useState(false)

  // 开放注册状态：null=未知（未返回前不提示），关闭时注册页展示“暂未开放注册，请联系管理员”
  const [registrationClosed, setRegistrationClosed] = useState<boolean | null>(null)
  useEffect(() => {
    let cancelled = false
    api
      .get<{ open_registration: boolean }>('/auth/admin-settings', { skipAuth: true })
      .then(data => {
        if (!cancelled) setRegistrationClosed(!data.open_registration)
      })
      .catch(() => {
        // 查询失败不阻断页面，后端注册接口仍会兜底拦截
      })
    return () => {
      cancelled = true
    }
  }, [])

  // 错误状态
  const [loginErrors, setLoginErrors] = useState({ account: false, password: false })
  const [registerErrors, setRegisterErrors] = useState({
    email: false, password: false, confirmPassword: false,
  })
  const [resetErrors, setResetErrors] = useState({
    email: false, newPassword: false, confirmPassword: false,
  })

  useEffect(() => {
    if (hasResetLink) setCurrentView('reset-confirm')
  }, [hasResetLink])

  useEffect(() => {
    void primeAppViewport('login-page-prime')

    const handleResume = () => {
      if (document.visibilityState !== 'visible') return
      void primeAppViewport('login-page-resume')
    }

    window.addEventListener('pageshow', handleResume, { passive: true })
    document.addEventListener('visibilitychange', handleResume, { passive: true })

    return () => {
      window.removeEventListener('pageshow', handleResume)
      document.removeEventListener('visibilitychange', handleResume)
    }
  }, [])

  // 通用延迟清除错误 hook
  useEffect(() => {
    if (currentView === 'login') {
      if (!loginForm.account && !loginForm.password) return
      const timer = setTimeout(() => {
        setLoginErrors({ account: false, password: false })
      }, 1000)
      return () => clearTimeout(timer)
    }
  }, [loginForm.account, loginForm.password, currentView])

  useEffect(() => {
    if (currentView !== 'register') return
    const timer = setTimeout(() => {
      setRegisterErrors(prev => ({
        ...prev,
        email: false,
        password: false,
        confirmPassword: registerForm.password !== registerForm.confirmPassword && !!registerForm.confirmPassword,
      }))
    }, 1000)
    return () => clearTimeout(timer)
  }, [registerForm.email, registerForm.password, registerForm.confirmPassword, currentView])

  useEffect(() => {
    if (currentView !== 'reset-request' && currentView !== 'reset-confirm') return
    const timer = setTimeout(() => {
      setResetErrors(prev => ({
        ...prev,
        email: false,
        newPassword: false,
        confirmPassword: resetForm.newPassword !== resetForm.confirmPassword && !!resetForm.confirmPassword,
      }))
    }, 1000)
    return () => clearTimeout(timer)
  }, [resetForm.email, resetForm.newPassword, resetForm.confirmPassword, currentView])

  const handleLoginSubmit = async () => {
    if (submittingLogin) return
    if (!loginForm.account) {
      setLoginErrors({ account: true, password: false })
      return
    }
    if (!loginForm.password) {
      setLoginErrors({ account: false, password: true })
      return
    }
    if (!agreed) {
      setShowAgreementPrompt(true)
      return
    }

    try {
      setSubmittingLogin(true)
      const data = await api.post<{
        token: string
        user_id: string
        email: string
        preflight_completed_at?: string
      }>('/auth/login', {
        email: loginForm.account,
        password: loginForm.password,
        agreed: true,
      }, {
        suppressConnectionError: true,
        timeout: 15000,
        skipAuth: true,
        retryTransient: true,
      })
      login(
        {
          id: data.user_id,
          email: data.email,
          preflightCompletedAt: data.preflight_completed_at || '',
        },
        data.token
      )
      void primeAppViewport('login-success-prime')
      navigate('/holdings', { replace: true })
    } catch (error) {
      const message = error instanceof ApiError ? error.message : '登录失败，请稍后重试'
      showToast(message)
    } finally {
      setSubmittingLogin(false)
    }
  }

  const handleRegisterSubmit = async () => {
    if (registrationClosed === true) {
      showToast('暂未开放注册，请联系管理员')
      return
    }
    if (!registerForm.email) {
      setRegisterErrors({ email: true, password: false, confirmPassword: false })
      return
    }
    if (registerForm.password.length < 8) {
      setRegisterErrors({ email: false, password: true, confirmPassword: false })
      showToast('密码长度不能少于8位')
      return
    }
    if (!registerForm.confirmPassword || registerForm.password !== registerForm.confirmPassword) {
      setRegisterErrors({ email: false, password: false, confirmPassword: true })
      return
    }
    if (!agreed) {
      setShowAgreementPrompt(true)
      return
    }

    try {
      await api.post('/auth/register', {
        email: registerForm.email,
        password: registerForm.password,
        confirm_password: registerForm.confirmPassword,
        agreed: true,
      }, { skipAuth: true })
      setCurrentView('login')
      setLoginForm({ account: registerForm.email, password: '' })
    } catch (error) {
      const message = error instanceof ApiError ? error.message : '注册失败，请稍后重试'
      showToast(message)
    }
  }

  const handleSendResetEmail = async () => {
    if (submittingReset) return
    if (!resetForm.email) {
      setResetErrors(prev => ({ ...prev, email: true }))
      return
    }
    setSubmittingReset(true)
    try {
      await api.post('/auth/password-reset/request', { email: resetForm.email }, {
        suppressConnectionError: true,
        timeout: 15000,
        skipAuth: true,
      })
      setResetEmailSent(true)
    } catch (error) {
      showToast(error instanceof ApiError ? error.message : '重置邮件发送失败，请稍后重试')
    } finally {
      setSubmittingReset(false)
    }
  }

  const handleReset = async () => {
    if (submittingReset) return
    if (resetForm.newPassword.length < 8) {
      setResetErrors({ email: false, newPassword: true, confirmPassword: false })
      showToast('密码长度不能少于8位')
      return
    }
    if (!resetForm.confirmPassword || resetForm.newPassword !== resetForm.confirmPassword) {
      setResetErrors({ email: false, newPassword: false, confirmPassword: true })
      return
    }
    if (!hasResetLink) {
      showToast('重置链接无效，请重新申请')
      setCurrentView('reset-request')
      return
    }
    setSubmittingReset(true)
    try {
      await api.post('/auth/password-reset/confirm', {
        uid: resetUid,
        token: resetToken,
        new_password: resetForm.newPassword,
        confirm_password: resetForm.confirmPassword,
      }, {
        suppressConnectionError: true,
        timeout: 15000,
        skipAuth: true,
      })
      setSearchParams({}, { replace: true })
      setResetForm({ email: '', newPassword: '', confirmPassword: '' })
      setCurrentView('login')
      showToast('密码已重置，请使用新密码登录')
    } catch (error) {
      showToast(error instanceof ApiError ? error.message : '密码重置失败，请重新申请')
    } finally {
      setSubmittingReset(false)
    }
  }

  const returnToLogin = () => {
    setSearchParams({}, { replace: true })
    setCurrentView('login')
  }

  const inputClass = (hasError: boolean) =>
    `w-full px-4 py-2.5 rounded-xl transition-all outline-none border-2 bg-t-surface-input text-t-text placeholder-t-text-placeholder ${
      hasError ? 'border-[#F6465D]' : 'border-transparent focus:border-[#F0B90B]'
    }`

  const labelClass = 'block mb-2 text-sm text-t-text-secondary'

  return (
    <div
      className="min-h-screen flex items-center justify-center px-4 transition-colors bg-t-page"
      style={{
        paddingTop: 'max(16px, env(safe-area-inset-top, 0px))',
        paddingBottom: 'max(16px, env(safe-area-inset-bottom, 0px))',
      }}
    >
      <div className="w-full max-w-md rounded-3xl p-8 shadow-2xl transition-colors bg-t-surface dark:bg-gradient-to-br dark:from-[#1A1D23] dark:to-[#0B0E11]">
        {/* Logo Icon */}
        <div className="flex justify-center mb-6">
          <div className="w-20 h-20 bg-gradient-to-br from-[#F0B90B] to-[#D9A70A] rounded-3xl flex items-center justify-center shadow-lg shadow-[#F0B90B]/20">
            <TrendingUp size={40} className="text-black" strokeWidth={2.5} />
          </div>
        </div>

        <h1 className="text-3xl font-bold text-center mb-2 text-t-text">RISKON</h1>

        <p className="text-gray-400 text-center mb-8">
          {currentView === 'login' && '欢迎回来'}
          {currentView === 'register' && '创建新账号'}
          {(currentView === 'reset-request' || currentView === 'reset-confirm') && '重置密码'}
        </p>

        {/* Login Form */}
        {currentView === 'login' && (
          <div className="space-y-5">
            <div>
              <label htmlFor="login-account" className={labelClass}>账号</label>
              <input
                id="login-account"
                type="text"
                placeholder="请输入邮箱账号"
                value={loginForm.account}
                onChange={(e) => setLoginForm({ ...loginForm, account: e.target.value })}
                className={inputClass(loginErrors.account)}
              />
            </div>
            <div>
              <label htmlFor="login-password" className={labelClass}>密码</label>
              <input
                id="login-password"
                type="password"
                placeholder="请输入密码"
                value={loginForm.password}
                onChange={(e) => setLoginForm({ ...loginForm, password: e.target.value })}
                className={inputClass(loginErrors.password)}
              />
            </div>

            <div className="flex items-center gap-2">
              <input
                type="checkbox"
                id="agree-login"
                checked={agreed}
                onChange={(e) => setAgreed(e.target.checked)}
                className="w-4 h-4 rounded cursor-pointer appearance-none border-2 border-[#2B2F36] checked:bg-[#F0B90B] checked:border-[#F0B90B] relative checked:after:content-['✓'] checked:after:absolute checked:after:text-black checked:after:text-xs checked:after:left-0.5 checked:after:top-[-2px]"
              />
              <label htmlFor="agree-login" className="text-sm text-gray-400 cursor-pointer">
                我已阅读并同意{' '}
                <Link to="/user-agreement" className="text-[#F0B90B] underline">用户协议</Link>
                {' '}和{' '}
                <Link to="/privacy-policy" className="text-[#F0B90B] underline">隐私政策</Link>
              </label>
            </div>

            <button
              onClick={handleLoginSubmit}
              disabled={submittingLogin}
              className="w-full bg-gradient-to-r from-[#F0B90B] to-[#D9A70A] text-black font-bold py-3.5 rounded-xl hover:shadow-lg hover:shadow-[#F0B90B]/30 transition-all active:scale-[0.98] mt-8"
            >
              {submittingLogin ? '正在进入...' : '登录'}
            </button>

            <div className="flex items-center justify-center gap-4 text-sm">
              <button onClick={() => setCurrentView('reset-request')} className="text-[#F0B90B] hover:underline">
                忘记密码？
              </button>
              <span className="text-gray-600">|</span>
              <button onClick={() => setCurrentView('register')} className="text-[#F0B90B] hover:underline">
                注册账号
              </button>
            </div>
          </div>
        )}

        {/* Register Form */}
        {currentView === 'register' && (
          <div className="space-y-5">
            {registrationClosed === true && (
              <div className="rounded-xl bg-[#F6465D]/10 border border-[#F6465D]/30 px-4 py-3 text-sm text-center font-medium text-[#F6465D]">
                暂未开放注册，请联系管理员
              </div>
            )}
            <div>
              <label htmlFor="register-email" className={labelClass}>邮箱</label>
              <input id="register-email" type="email" placeholder="请输入邮箱" value={registerForm.email}
                onChange={(e) => setRegisterForm({ ...registerForm, email: e.target.value })}
                className={inputClass(registerErrors.email)} />
            </div>
            <div>
              <label htmlFor="register-password" className={labelClass}>密码</label>
              <input id="register-password" type="password" placeholder="请输入密码" value={registerForm.password}
                onChange={(e) => setRegisterForm({ ...registerForm, password: e.target.value })}
                className={inputClass(registerErrors.password)} />
            </div>
            <div>
              <label htmlFor="register-password-confirm" className={labelClass}>确认密码</label>
              <input id="register-password-confirm" type="password" placeholder="请再次输入密码" value={registerForm.confirmPassword}
                onChange={(e) => setRegisterForm({ ...registerForm, confirmPassword: e.target.value })}
                className={inputClass(registerErrors.confirmPassword)} />
            </div>

            <div className="flex items-center gap-2">
              <input type="checkbox" id="agree-register" checked={agreed}
                onChange={(e) => setAgreed(e.target.checked)}
                className="w-4 h-4 rounded cursor-pointer appearance-none border-2 border-[#2B2F36] checked:bg-[#F0B90B] checked:border-[#F0B90B] relative checked:after:content-['✓'] checked:after:absolute checked:after:text-black checked:after:text-xs checked:after:left-0.5 checked:after:top-[-2px]"
              />
              <label htmlFor="agree-register" className="text-sm text-gray-400 cursor-pointer">
                我已阅读并同意{' '}
                <Link to="/user-agreement" className="text-[#F0B90B] underline">用户协议</Link>
                {' '}和{' '}
                <Link to="/privacy-policy" className="text-[#F0B90B] underline">隐私政策</Link>
              </label>
            </div>

            <button onClick={handleRegisterSubmit}
              disabled={registrationClosed === true}
              className={`w-full font-bold py-3.5 rounded-xl transition-all mt-8 ${
                registrationClosed === true
                  ? 'bg-gray-600 text-gray-400 cursor-not-allowed'
                  : 'bg-gradient-to-r from-[#F0B90B] to-[#D9A70A] text-black hover:shadow-lg hover:shadow-[#F0B90B]/30 active:scale-[0.98]'
              }`}>
              注册
            </button>

            <div className="flex items-center justify-center pt-2">
              <button onClick={() => setCurrentView('login')} className="text-[#F0B90B] hover:opacity-80 transition-opacity">
                返回登录
              </button>
            </div>
          </div>
        )}

        {/* Reset Password Form */}
        {currentView === 'reset-request' && (
          <div className="space-y-5">
            {resetEmailSent ? (
              <div className="rounded-xl border border-[#0ECB81]/30 bg-[#0ECB81]/10 px-4 py-4 text-sm leading-6 text-[#0ECB81]">
                如果该邮箱已注册，重置邮件会在几分钟内发送。请在 30 分钟内打开邮件中的链接。
              </div>
            ) : (
              <>
                <div>
                  <label htmlFor="reset-email" className={labelClass}>邮箱账号</label>
                  <input id="reset-email" type="email" placeholder="请输入邮箱" value={resetForm.email}
                    onChange={(e) => setResetForm({ ...resetForm, email: e.target.value })}
                    className={inputClass(resetErrors.email)} />
                </div>
                <button onClick={() => void handleSendResetEmail()}
                  disabled={submittingReset}
                  className="w-full py-3.5 bg-[#F0B90B] text-black font-medium rounded-xl hover:bg-[#D9A70A] transition-colors mt-8 disabled:opacity-50">
                  {submittingReset ? '正在发送...' : '发送重置邮件'}
                </button>
              </>
            )}

            <div className="flex items-center justify-center pt-2">
              <button onClick={returnToLogin} className="text-[#F0B90B] hover:opacity-80 transition-opacity">
                返回登录
              </button>
            </div>
          </div>
        )}

        {currentView === 'reset-confirm' && (
          <div className="space-y-5">
            <div>
              <label htmlFor="reset-password" className={labelClass}>新密码</label>
              <input id="reset-password" type="password" placeholder="请输入新密码" value={resetForm.newPassword}
                onChange={(e) => setResetForm({ ...resetForm, newPassword: e.target.value })}
                className={inputClass(resetErrors.newPassword)} />
            </div>
            <div>
              <label htmlFor="reset-password-confirm" className={labelClass}>确认新密码</label>
              <input id="reset-password-confirm" type="password" placeholder="请再次输入新密码" value={resetForm.confirmPassword}
                onChange={(e) => setResetForm({ ...resetForm, confirmPassword: e.target.value })}
                className={inputClass(resetErrors.confirmPassword)} />
            </div>
            <button onClick={() => void handleReset()}
              disabled={submittingReset}
              className="w-full py-3.5 bg-[#F0B90B] text-black font-medium rounded-xl hover:bg-[#D9A70A] transition-colors mt-8 disabled:opacity-50">
              {submittingReset ? '正在重置...' : '确认重置密码'}
            </button>
            <div className="flex items-center justify-center pt-2">
              <button onClick={returnToLogin} className="text-[#F0B90B] hover:opacity-80 transition-opacity">
                返回登录
              </button>
            </div>
          </div>
        )}
      </div>

      {/* Agreement Prompt Modal */}
      {showAgreementPrompt && (
        <div className="fixed inset-0 z-50 flex items-center justify-center p-4">
          <div className="absolute inset-0 bg-black/60 backdrop-blur-sm" onClick={() => setShowAgreementPrompt(false)} />
          <div className="relative max-w-sm w-full rounded-2xl p-6 shadow-2xl bg-t-modal">
            <p className="text-center mb-6 leading-relaxed text-t-text-secondary">
              您还没有阅读和同意{' '}
              <Link to="/user-agreement" className="text-[#F0B90B] underline" onClick={() => setShowAgreementPrompt(false)}>
                用户协议
              </Link>
              {' '}和{' '}
              <Link to="/privacy-policy" className="text-[#F0B90B] underline" onClick={() => setShowAgreementPrompt(false)}>
                隐私政策
              </Link>
              ，确认已阅读并同意？
            </p>
            <div className="flex gap-3">
              <button onClick={() => setShowAgreementPrompt(false)}
                className="flex-1 py-3 rounded-xl font-medium transition-colors bg-t-btn-secondary text-t-text hover:bg-t-btn-secondary-hover">
                不同意
              </button>
              <button onClick={() => { setAgreed(true); setShowAgreementPrompt(false) }}
                className="flex-1 py-3 rounded-xl font-medium bg-gradient-to-r from-[#F0B90B] to-[#D9A70A] text-black hover:shadow-lg hover:shadow-[#F0B90B]/30 transition-all">
                同意
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}
