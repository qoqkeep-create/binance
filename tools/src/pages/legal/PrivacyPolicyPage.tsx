import { ChevronLeft } from 'lucide-react'
import { useNavigate } from 'react-router-dom'
import { useTheme } from '@/app/contexts/ThemeContext'

export function PrivacyPolicyPage() {
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
          <h1 className="text-lg font-bold">隐私政策</h1>
        </div>
      </div>

      {/* Content */}
      <div className="max-w-md mx-auto p-4 pb-8">
        <div className={`rounded-xl p-6 space-y-6 ${
          theme === 'dark' ? 'bg-[#1A1D23]' : 'bg-white'
        }`}>
          <div>
            <h2 className="text-lg font-bold mb-3">RISKON隐私政策</h2>
            <p className={`text-sm leading-relaxed ${
              theme === 'dark' ? 'text-gray-400' : 'text-gray-600'
            }`}>
              本隐私政策说明了RISKON如何收集、使用、存储和保护您的个人信息。我们深知个人信息对您的重要性，会尽全力保护您的个人信息安全。
            </p>
          </div>

          <div>
            <h3 className="font-bold mb-2">1. 信息收集</h3>
            <p className={`text-sm leading-relaxed mb-2 ${
              theme === 'dark' ? 'text-gray-400' : 'text-gray-600'
            }`}>
              我们可能收集以下信息：
            </p>
            <ul className={`text-sm space-y-1 list-disc list-inside ${
              theme === 'dark' ? 'text-gray-400' : 'text-gray-600'
            }`}>
              <li>账户信息：邮箱地址、用户名、密码（加密存储）</li>
              <li>交易数据：持仓记录、交易历史、资产余额</li>
              <li>API信息：交易所API密钥（加密存储）、API别名</li>
              <li>设备信息：设备型号、操作系统版本、应用版本</li>
              <li>使用数据：功能使用频率、页面访问记录</li>
            </ul>
          </div>

          <div>
            <h3 className="font-bold mb-2">2. 信息使用</h3>
            <p className={`text-sm leading-relaxed mb-2 ${
              theme === 'dark' ? 'text-gray-400' : 'text-gray-600'
            }`}>
              我们收集的信息将用于：
            </p>
            <ul className={`text-sm space-y-1 list-disc list-inside ${
              theme === 'dark' ? 'text-gray-400' : 'text-gray-600'
            }`}>
              <li>提供交易辅助服务和持仓管理功能</li>
              <li>执行您的交易指令和风险控制策略</li>
              <li>优化应用性能和用户体验</li>
              <li>发送重要通知和服务更新</li>
              <li>进行数据分析以改进服务质量</li>
            </ul>
          </div>

          <div>
            <h3 className="font-bold mb-2">3. 信息存储</h3>
            <p className={`text-sm leading-relaxed ${
              theme === 'dark' ? 'text-gray-400' : 'text-gray-600'
            }`}>
              您的个人信息将存储在安全的服务器中，采用行业标准的加密技术。敏感信息（如API密钥、密码）采用不可逆加密算法存储。我们会定期进行安全审计，确保数据安全。
            </p>
          </div>

          <div>
            <h3 className="font-bold mb-2">4. 信息共享</h3>
            <p className={`text-sm leading-relaxed ${
              theme === 'dark' ? 'text-gray-400' : 'text-gray-600'
            }`}>
              我们承诺不会出售、出租或以其他方式向第三方共享您的个人信息，除非：
            </p>
            <ul className={`text-sm space-y-1 list-disc list-inside mt-2 ${
              theme === 'dark' ? 'text-gray-400' : 'text-gray-600'
            }`}>
              <li>获得您的明确授权</li>
              <li>法律法规要求或政府部门要求</li>
              <li>为维护您的重大合法权益</li>
              <li>与交易所API进行必要的数据交互（仅限交易执行）</li>
            </ul>
          </div>

          <div>
            <h3 className="font-bold mb-2">5. Cookie使用</h3>
            <p className={`text-sm leading-relaxed ${
              theme === 'dark' ? 'text-gray-400' : 'text-gray-600'
            }`}>
              我们使用Cookie和类似技术来改善用户体验，包括记住您的登录状态、主题偏好等。您可以在浏览器设置中管理Cookie，但这可能影响部分功能的正常使用。
            </p>
          </div>

          <div>
            <h3 className="font-bold mb-2">6. 您的权利</h3>
            <p className={`text-sm leading-relaxed mb-2 ${
              theme === 'dark' ? 'text-gray-400' : 'text-gray-600'
            }`}>
              您对个人信息享有以下权利：
            </p>
            <ul className={`text-sm space-y-1 list-disc list-inside ${
              theme === 'dark' ? 'text-gray-400' : 'text-gray-600'
            }`}>
              <li>访问权：查看您的个人信息</li>
              <li>更正权：修改不准确的个人信息</li>
              <li>删除权：要求删除您的个人信息</li>
              <li>撤回权：撤回已授予的信息处理同意</li>
              <li>导出权：获取您的个人信息副本</li>
            </ul>
          </div>

          <div>
            <h3 className="font-bold mb-2">7. 未成年人保护</h3>
            <p className={`text-sm leading-relaxed ${
              theme === 'dark' ? 'text-gray-400' : 'text-gray-600'
            }`}>
              本应用不向18岁以下的未成年人提供服务。如果我们发现收集了未成年人的信息，将立即删除相关数据。
            </p>
          </div>

          <div>
            <h3 className="font-bold mb-2">8. 政策更新</h3>
            <p className={`text-sm leading-relaxed ${
              theme === 'dark' ? 'text-gray-400' : 'text-gray-600'
            }`}>
              我们可能会不时更新本隐私政策。更新后的政策将在应用内公布，重大变更将通过显著方式通知您。继续使用本应用即表示您同意更新后的政策。
            </p>
          </div>

          <div>
            <h3 className="font-bold mb-2">9. 联系我们</h3>
            <p className={`text-sm leading-relaxed ${
              theme === 'dark' ? 'text-gray-400' : 'text-gray-600'
            }`}>
              如果您对本隐私政策有任何疑问、意见或建议，或需要行使您的权利，请通过应用内反馈功能或邮件联系我们。
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