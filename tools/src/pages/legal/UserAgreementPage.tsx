import { ChevronLeft } from 'lucide-react'
import { useNavigate } from 'react-router-dom'
import { useTheme } from '@/app/contexts/ThemeContext'

export function UserAgreementPage() {
  const { theme } = useTheme();
  const navigate = useNavigate();

  return (
    <div className={`min-h-screen transition-colors ${
      theme === 'dark' ? 'bg-[#0B0E11] text-white' : 'bg-[#F5F5F5] text-gray-900'
    }`}>
      {/* Header */}
      <div className={`sticky top-0 z-10 px-4 py-4 border-b transition-colors ${
        theme === 'dark'
          ? 'bg-[#1A1D23] border-[#2B2F36]'
          : 'bg-white border-gray-200'
      }`}>
        <div className="flex items-center gap-3 max-w-md mx-auto">
          <button
            onClick={() => navigate(-1)}
            className={`p-2 rounded-lg transition-colors ${
              theme === 'dark' ? 'hover:bg-[#2B2F36]' : 'hover:bg-gray-100'
            }`}
          >
            <ChevronLeft size={20} />
          </button>
          <h1 className="text-lg font-bold">用户协议</h1>
        </div>
      </div>

      {/* Content */}
      <div className="max-w-md mx-auto p-4 pb-8">
        <div className={`rounded-xl p-6 space-y-6 ${
          theme === 'dark' ? 'bg-[#1A1D23]' : 'bg-white'
        }`}>
          <div>
            <h2 className="text-lg font-bold mb-3">欢迎使用RISKON</h2>
            <p className={`text-sm leading-relaxed ${
              theme === 'dark' ? 'text-gray-400' : 'text-gray-600'
            }`}>
              在使用本应用前，请您仔细阅读并充分理解本协议各条款。一旦您使用本应用，即表示您已阅读、理解并同意接受本协议的所有内容。
            </p>
          </div>

          <div>
            <h3 className="font-bold mb-2">1. 服务说明</h3>
            <p className={`text-sm leading-relaxed ${
              theme === 'dark' ? 'text-gray-400' : 'text-gray-600'
            }`}>
              RISKON是一款虚拟货币交易辅助工具，提供持仓管理、交易执行、风险控制等功能。本应用仅作为工具使用，不提供投资建议。
            </p>
          </div>

          <div>
            <h3 className="font-bold mb-2">2. 风险提示</h3>
            <p className={`text-sm leading-relaxed ${
              theme === 'dark' ? 'text-gray-400' : 'text-gray-600'
            }`}>
              虚拟货币交易存在极高风险，可能导致全部本金损失。请您根据自身风险承受能力谨慎决策，本应用不对任何交易损失承担责任。
            </p>
          </div>

          <div>
            <h3 className="font-bold mb-2">3. 账户安全</h3>
            <p className={`text-sm leading-relaxed ${
              theme === 'dark' ? 'text-gray-400' : 'text-gray-600'
            }`}>
              您应妥善保管账户密码、API密钥等重要信息。因您自身原因导致的账户安全问题，本应用不承担责任。建议您定期更换密码，不要在多个平台使用相同密码。
            </p>
          </div>

          <div>
            <h3 className="font-bold mb-2">4. API使用规范</h3>
            <p className={`text-sm leading-relaxed ${
              theme === 'dark' ? 'text-gray-400' : 'text-gray-600'
            }`}>
              在绑定交易所API时，请确保仅授予必要的权限。建议不要授予提币权限，以降低资金风险。本应用承诺不会将您的API信息用于任何未经授权的操作。
            </p>
          </div>

          <div>
            <h3 className="font-bold mb-2">5. 数据隐私</h3>
            <p className={`text-sm leading-relaxed ${
              theme === 'dark' ? 'text-gray-400' : 'text-gray-600'
            }`}>
              我们重视您的隐私保护，您的交易数据、持仓信息等将被加密存储。我们不会向第三方出售、出租或以其他方式共享您的个人信息。
            </p>
          </div>

          <div>
            <h3 className="font-bold mb-2">6. 服务变更与终止</h3>
            <p className={`text-sm leading-relaxed ${
              theme === 'dark' ? 'text-gray-400' : 'text-gray-600'
            }`}>
              我们保留随时修改、暂停或终止部分或全部服务的权利。如有重大变更，我们将通过应用内通知或其他适当方式提前告知用户。
            </p>
          </div>

          <div>
            <h3 className="font-bold mb-2">7. 免责声明</h3>
            <p className={`text-sm leading-relaxed ${
              theme === 'dark' ? 'text-gray-400' : 'text-gray-600'
            }`}>
              本应用提供的所有数据、指标、信号仅供参考，不构成任何投资建议。用户应根据自身情况独立判断，自行承担交易风险。
            </p>
          </div>

          <div>
            <h3 className="font-bold mb-2">8. 协议更新</h3>
            <p className={`text-sm leading-relaxed ${
              theme === 'dark' ? 'text-gray-400' : 'text-gray-600'
            }`}>
              我们可能会不定期更新本协议。更新后的协议将在应用内公布，您继续使用本应用即表示同意更新后的协议内容。
            </p>
          </div>

          <div className="pt-4 border-t border-[#2B2F36]">
            <p className={`text-xs ${
              theme === 'dark' ? 'text-gray-500' : 'text-gray-500'
            }`}>
              最后更新日期：2024年1月
            </p>
          </div>
        </div>
      </div>
    </div>
  );
}