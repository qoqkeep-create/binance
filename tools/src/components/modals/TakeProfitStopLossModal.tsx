import { X } from 'lucide-react'
import { useState, useEffect } from 'react'
import { useTheme } from '@/app/contexts/ThemeContext'
import { Strategy } from '@/pages/strategy'
import { formatStrategyLevelText } from '@/shared/lib/strategyText'

interface TakeProfitStopLossModalProps {
  isOpen: boolean;
  onClose: () => void;
  onSelect?: (strategyName: string) => void;
  onConfirm?: (strategyType: 'manual' | 'auto', selectedStrategyId?: string) => void;
  onManageStrategies?: () => void;
  strategies?: Strategy[];
  currentStrategyType?: 'manual' | 'auto';
  currentStrategyId?: string;
  // 新增：是否已选择过自动止盈策略（用于持仓页面的限制）
  hasSelectedAutoStrategy?: boolean;
  autoOnly?: boolean;
  getTriggeredLevelIndexes?: (strategyId?: string) => number[];
}

export function TakeProfitStopLossModal({
  isOpen,
  onClose,
  onSelect,
  onConfirm,
  onManageStrategies,
  strategies = [],
  currentStrategyType = 'manual',
  currentStrategyId,
  hasSelectedAutoStrategy = false,
  autoOnly = false,
  getTriggeredLevelIndexes,
}: TakeProfitStopLossModalProps) {
  const { theme } = useTheme();
  const [strategyType, setStrategyType] = useState<'manual' | 'auto'>(currentStrategyType);
  const [selectedStrategyId, setSelectedStrategyId] = useState<string | undefined>(currentStrategyId);
  const [showSwitchConfirm, setShowSwitchConfirm] = useState(false);

  // 当弹窗打开时，重置状态
  useEffect(() => {
    if (isOpen) {
      setStrategyType(autoOnly ? 'auto' : currentStrategyType);
      setSelectedStrategyId(currentStrategyId);
      setShowSwitchConfirm(false);
    }
  }, [isOpen, currentStrategyType, currentStrategyId, autoOnly]);

  if (!isOpen) return null;

  const handleStrategyTypeChange = (type: 'manual' | 'auto') => {
    // 直接切换，不再在这里弹出确认
    setStrategyType(type);
    if (type === 'manual') {
      setSelectedStrategyId(undefined);
    }
  };

  const handleSwitchConfirm = () => {
    // 确认切换到手动
    setShowSwitchConfirm(false);
    if (onConfirm) {
      onConfirm('manual', undefined);
    }
    if (onSelect) {
      onSelect('手动止盈');
    }
    onClose();
  };

  const handleCancelSwitch = () => {
    // 取消切换，恢复到原来的自动策略状态
    setShowSwitchConfirm(false);
    setStrategyType(currentStrategyType);
    setSelectedStrategyId(currentStrategyId);
  };

  const handleConfirm = () => {
    // 检查是否需要二次确认：从自动切换到手动
    if (hasSelectedAutoStrategy && currentStrategyType === 'auto' && strategyType === 'manual') {
      setShowSwitchConfirm(true);
      return;
    }

    // 简化模式：只传递策略名称
    if (onSelect) {
      const strategyName = strategyType === 'manual' ? '手动止盈' : '自动止盈';
      onSelect(strategyName);
      onClose();
      return;
    }

    // 完整模式：传递策略类型和ID
    if (onConfirm) {
      onConfirm(strategyType, selectedStrategyId);
      onClose();
    }
  };

  // 判断确定按钮是否应该禁用
  const isConfirmDisabled = strategyType === 'auto' && !selectedStrategyId;

  return (
    <>
      {/* 层级须高于底部导航栏：低层级弹窗在部分环境下会被 tabbar 遮住 */}
      <div className="fixed inset-0 z-[70] flex items-end justify-center bg-black/60 backdrop-blur-sm">
        <div className="w-full max-w-md rounded-t-[28px] overflow-hidden shadow-2xl">
          {/* Header */}
          <div
            className={`flex items-center justify-between px-4 py-4 border-b ${
              theme === 'dark' ? 'bg-[#1A1D23] border-[#2B2F36]' : 'bg-white border-gray-200'
            }`}
          >
            <h2 className={`text-lg font-bold ${
              theme === 'dark' ? 'text-white' : 'text-gray-900'
            }`}>
              止盈止损策略
            </h2>
            <button
              onClick={onClose}
              className={`p-1 rounded-lg transition-colors ${
                theme === 'dark' ? 'hover:bg-[#2B2F36]' : 'hover:bg-gray-100'
              }`}
            >
              <X size={20} className={theme === 'dark' ? 'text-gray-400' : 'text-gray-600'} />
            </button>
          </div>

          {/* Content */}
          <div className={`${theme === 'dark' ? 'bg-[#0B0E11]' : 'bg-[#F8FAFC]'} py-4 space-y-4`}>
            {!autoOnly && (
              <>
                {/* Manual Option */}
                <div className="px-4">
                  <div className="flex items-center justify-between mb-3">
                    <span className={`font-medium ${
                      theme === 'dark' ? 'text-white' : 'text-gray-900'
                    }`}>
                      手动止盈
                    </span>
                    <input
                      type="radio"
                      checked={strategyType === 'manual'}
                      onChange={() => handleStrategyTypeChange('manual')}
                      className="w-5 h-5 accent-[var(--t-brand)] cursor-pointer"
                      style={{ accentColor: 'var(--t-brand)' }}
                    />
                  </div>
                </div>

                {/* Divider */}
                <div className={`mx-4 border-t ${theme === 'dark' ? 'border-[#2B2F36]' : 'border-gray-200'}`} />
              </>
            )}

            <div className="space-y-3">
              {!autoOnly && (
                <div className="px-4 flex items-center justify-between">
                  <span className={`font-medium ${theme === 'dark' ? 'text-white' : 'text-gray-900'}`}>
                    自动止盈
                  </span>
                  <input
                    type="radio"
                    checked={strategyType === 'auto'}
                    onChange={() => handleStrategyTypeChange('auto')}
                    className="w-5 h-5 accent-[var(--t-brand)] cursor-pointer"
                    style={{ accentColor: 'var(--t-brand)' }}
                  />
                </div>
              )}

              <div className="px-4 space-y-4">
                {strategies.length === 0 ? (
                  <div className={`text-sm py-3 px-4 rounded-2xl ${
                    theme === 'dark' ? 'bg-[#1A1D23] text-gray-500 border border-[#2B2F36]' : 'bg-white text-gray-400 border border-gray-200'
                  }`}>
                    暂无策略
                  </div>
                ) : (
                  strategies.map((strategy) => {
                    const isCurrentStrategy = selectedStrategyId === strategy.id && currentStrategyType === 'auto';
                    const isDisabled = hasSelectedAutoStrategy && currentStrategyType === 'auto' && !isCurrentStrategy;
                    const isSelected = strategyType === 'auto' && selectedStrategyId === strategy.id;
                    const triggeredLevelIndexes = isSelected
                      ? (getTriggeredLevelIndexes?.(strategy.id) || [])
                      : [];

                    return (
                      <button
                        key={strategy.id}
                        type="button"
                        disabled={isDisabled}
                        onClick={() => {
                          if (!isDisabled) {
                            setStrategyType('auto');
                            setSelectedStrategyId(strategy.id);
                          }
                        }}
                        className={`w-full text-left rounded-2xl p-4 border transition-all ${
                          isDisabled
                            ? theme === 'dark'
                              ? 'bg-[#1A1D23] border-[#2B2F36] opacity-50 cursor-not-allowed'
                              : 'bg-white border-gray-200 opacity-50 cursor-not-allowed'
                            : isSelected
                              ? theme === 'dark'
                                ? 'bg-[#1A1D23] border-[var(--t-brand)]'
                                : 'bg-white border-[var(--t-brand)]'
                              : theme === 'dark'
                                ? 'bg-[#1A1D23] border-[#2B2F36] hover:border-[#3A414D]'
                                : 'bg-white border-gray-200 hover:border-gray-300'
                        }`}
                      >
                        <div className="flex items-start justify-between gap-3 mb-3">
                          <h3 className={`font-medium ${theme === 'dark' ? 'text-white' : 'text-gray-900'}`}>
                            {strategy.name}
                          </h3>
                        </div>
                        <div className={`space-y-1.5 text-sm ${theme === 'dark' ? 'text-t-text-secondary' : 'text-gray-600'}`}>
                          {strategy.levels.map((level, index) => (
                            <div key={index} className="flex items-start gap-2">
                              <span className="flex-1 inline-flex flex-wrap items-center gap-2">
                                <span>{formatStrategyLevelText(level, index)}</span>
                                {triggeredLevelIndexes.includes(index) && (
                                  <span
                                    className={`shrink-0 rounded-md border border-[var(--t-brand)] px-1.5 py-0.5 text-[10px] font-medium leading-none ${
                                      theme === 'dark'
                                        ? 'bg-[var(--t-brand)]/10 text-[#F5C84C]'
                                        : 'bg-[var(--t-brand)]/12 text-[#A86600]'
                                    }`}
                                  >
                                    立即触发
                                  </span>
                                )}
                              </span>
                            </div>
                          ))}
                        </div>
                      </button>
                    );
                  })
                )}
              </div>
            </div>

            {/* Manage Strategies Link */}
            <button
              onClick={() => {
                onManageStrategies?.();
                onClose();
              }}
              className="w-full text-center py-1 text-[#4A9EFF] hover:text-[#3B8EEF] transition-colors"
            >
              添加/编辑策略
            </button>
          </div>

          {/* Confirm Button */}
          <div className={`${theme === 'dark' ? 'bg-[#0B0E11]' : 'bg-[#F8FAFC]'} px-4 pb-6`}>
            <button
              onClick={handleConfirm}
              disabled={isConfirmDisabled}
              className={`w-full py-3.5 rounded-xl font-medium transition-all ${
                isConfirmDisabled
                  ? 'bg-gray-400 text-gray-200 cursor-not-allowed opacity-50'
                  : 'bg-[var(--t-brand)] hover:bg-[var(--t-brand-hover)] text-black hover:shadow-lg hover:shadow-[var(--t-brand)]/30 active:scale-[0.98]'
              }`}
            >
              确定
            </button>
          </div>
        </div>
      </div>

      {/* Switch Confirmation Dialog */}
      {showSwitchConfirm && (
        <div className="fixed inset-0 z-[80] flex items-center justify-center bg-black/70 backdrop-blur-sm">
          <div className={`w-[90%] max-w-sm rounded-2xl p-6 ${
            theme === 'dark' ? 'bg-[#1A1D23]' : 'bg-white'
          }`}>
            <h3 className={`text-lg font-bold mb-4 ${
              theme === 'dark' ? 'text-white' : 'text-gray-900'
            }`}>
              确认切换
            </h3>
            <p className={`text-sm mb-6 ${
              theme === 'dark' ? 'text-gray-400' : 'text-gray-600'
            }`}>
              切换到手动止盈后，该单将不可再次使用自动止盈策略，是否确认？
            </p>
            <div className="flex gap-3">
              <button
                onClick={handleCancelSwitch}
                className={`flex-1 py-2.5 rounded-lg font-medium transition-colors ${
                  theme === 'dark'
                    ? 'bg-[#2B2F36] hover:bg-[#353A42] text-white'
                    : 'bg-gray-100 hover:bg-gray-200 text-gray-900'
                }`}
              >
                取消
              </button>
              <button
                onClick={handleSwitchConfirm}
                className="flex-1 bg-[var(--t-brand)] hover:bg-[var(--t-brand-hover)] text-black py-2.5 rounded-lg font-medium hover:shadow-lg hover:shadow-[var(--t-brand)]/30 active:scale-[0.98] transition-all"
              >
                确认
              </button>
            </div>
          </div>
        </div>
      )}
    </>
  );
}
