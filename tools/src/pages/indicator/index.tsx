import { ChevronLeft, Plus, Trash2, Edit2, Circle, CheckCircle2 } from 'lucide-react'
import { useState, useEffect } from 'react'
import { useNavigate } from 'react-router-dom'
import { useTheme } from '@/app/contexts/ThemeContext'

interface Indicator {
  id: string;
  name: string;
  conditions: string[];
  createdAt: Date;
}

function parseStoredIndicator(value: unknown): Indicator | null {
  if (typeof value !== 'object' || value === null) return null;
  const stored = value as Record<string, unknown>;
  if (typeof stored.name !== 'string' || !stored.name.trim()) return null;

  const createdAtValue =
    typeof stored.createdAt === 'string' || typeof stored.createdAt === 'number'
      ? stored.createdAt
      : Date.now();
  const createdAt = new Date(createdAtValue);

  return {
    id: typeof stored.id === 'string' ? stored.id : String(stored.id ?? Date.now()),
    name: stored.name,
    conditions: Array.isArray(stored.conditions)
      ? stored.conditions.filter((condition): condition is string => typeof condition === 'string')
      : [],
    createdAt: Number.isNaN(createdAt.getTime()) ? new Date() : createdAt,
  };
}

interface IndicatorVerificationPageProps {
  onSelectIndicator?: (indicatorName: string) => void;
}

const STORAGE_KEY = 'crypto_trading_indicators';

export function IndicatorVerificationPage({ onSelectIndicator }: IndicatorVerificationPageProps) {
  const { theme } = useTheme();
  const navigate = useNavigate();
  const [view, setView] = useState<'list' | 'create' | 'edit' | 'verify'>('list');
  const [indicators, setIndicators] = useState<Indicator[]>([]);
  const [editingIndicator, setEditingIndicator] = useState<Indicator | null>(null);
  const [verifyingIndicator, setVerifyingIndicator] = useState<Indicator | null>(null);

  // Load indicators from localStorage on mount
  useEffect(() => {
    const stored = localStorage.getItem(STORAGE_KEY);
    if (stored) {
      try {
        const parsed: unknown = JSON.parse(stored);
        if (!Array.isArray(parsed)) return;
        // Convert createdAt strings back to Date objects
        const indicators = parsed
          .map((indicator: unknown) => parseStoredIndicator(indicator))
          .filter((indicator): indicator is Indicator => indicator !== null);
        setIndicators(indicators);
      } catch (error) {
        console.error('Failed to load indicators:', error);
      }
    }
  }, []);

  // Save indicators to localStorage whenever they change
  useEffect(() => {
    if (indicators.length >= 0) {
      localStorage.setItem(STORAGE_KEY, JSON.stringify(indicators));
    }
  }, [indicators]);

  const handleCreateIndicator = (indicator: Omit<Indicator, 'id' | 'createdAt'>) => {
    const newIndicator: Indicator = {
      ...indicator,
      id: Date.now().toString(),
      createdAt: new Date(),
    };
    setIndicators([...indicators, newIndicator]);
    setView('list');
  };

  const handleEditIndicator = (indicator: Indicator) => {
    setEditingIndicator(indicator);
    setView('edit');
  };

  const handleUpdateIndicator = (updated: Omit<Indicator, 'id' | 'createdAt'>) => {
    if (!editingIndicator) return;
    setIndicators(indicators.map(ind =>
      ind.id === editingIndicator.id
        ? { ...ind, ...updated }
        : ind
    ));
    setEditingIndicator(null);
    setView('list');
  };

  const handleDeleteIndicator = (id: string) => {
    setIndicators(indicators.filter(ind => ind.id !== id));
  };

  const handleVerifyIndicator = (indicator: Indicator) => {
    setVerifyingIndicator(indicator);
    setView('verify');
  };

  const handleVerifyComplete = (indicatorName: string) => {
    // 返回到开仓界面并显示指标名称
    if (onSelectIndicator) {
      onSelectIndicator(indicatorName);
    }
    navigate('/trading');
  };

  if (view === 'create') {
    return (
      <IndicatorCreatePage
        onBack={() => setView('list')}
        onSave={handleCreateIndicator}
        theme={theme}
      />
    );
  }

  if (view === 'edit' && editingIndicator) {
    return (
      <IndicatorCreatePage
        onBack={() => {
          setView('list');
          setEditingIndicator(null);
        }}
        onSave={handleUpdateIndicator}
        initialData={editingIndicator}
        theme={theme}
      />
    );
  }

  if (view === 'verify' && verifyingIndicator) {
    return (
      <IndicatorVerifyPage
        indicator={verifyingIndicator}
        onBack={() => {
          setView('list');
          setVerifyingIndicator(null);
        }}
        onComplete={handleVerifyComplete}
        theme={theme}
      />
    );
  }

  return (
    <div className={`min-h-screen transition-colors ${
      theme === 'dark' ? 'bg-[#0B0E11]' : 'bg-[#F5F5F5]'
    }`}>
      <div className="p-4 max-w-md mx-auto">
        {/* Header */}
        <div className="flex items-center gap-3 mb-6">
          <button onClick={() => navigate('/trading')} className="text-gray-400 hover:text-[#F0B90B]">
            <ChevronLeft size={24} />
          </button>
          <h1 className={`text-xl ${theme === 'dark' ? 'text-white' : 'text-gray-900'}`}>
            开仓理由/指标校验
          </h1>
        </div>

        {/* Indicator List */}
        {indicators.length > 0 && (
          <div className="space-y-3 mb-4">
            {indicators.map((indicator) => (
              <IndicatorCard
                key={indicator.id}
                indicator={indicator}
                onEdit={() => handleEditIndicator(indicator)}
                onDelete={() => handleDeleteIndicator(indicator.id)}
                onVerify={() => handleVerifyIndicator(indicator)}
                theme={theme}
              />
            ))}
          </div>
        )}

        {/* Description & Create Button Card */}
        <div className={`rounded-lg p-6 ${
          theme === 'dark' ? 'bg-[#1A1D23]' : 'bg-white shadow-sm'
        }`}>
          <div className={`text-gray-400 text-sm leading-relaxed mb-4`}>
            请创建你擅长做的指标，在每一次开仓前，手动检查是否符合指标，避免情绪开仓。在平仓后，作为复盘的依据。
          </div>
          <button
            onClick={() => setView('create')}
            className="w-full bg-[#F0B90B] hover:bg-[#D9A70A] text-black py-3 rounded-lg transition-colors flex items-center justify-center gap-2 font-medium"
          >
            <Plus size={20} />
            <span>创建指标</span>
          </button>
        </div>
      </div>
    </div>
  );
}

interface IndicatorCardProps {
  indicator: Indicator;
  onEdit: () => void;
  onDelete: () => void;
  onVerify: () => void;
  theme: 'dark' | 'light';
}

function IndicatorCard({ indicator, onEdit, onDelete, onVerify, theme }: IndicatorCardProps) {
  const conditionCount = indicator.conditions.length;

  return (
    <div
      onClick={onVerify}
      className={`rounded-lg p-4 transition-colors cursor-pointer ${
        theme === 'dark' ? 'bg-[#1A1D23] hover:bg-[#1F2329]' : 'bg-white shadow-sm hover:bg-gray-50'
      }`}
    >
      <div className="flex items-start justify-between mb-3">
        <h3 className={`text-lg ${theme === 'dark' ? 'text-white' : 'text-gray-900'}`}>
          {indicator.name}
        </h3>
        <div className="flex gap-2" onClick={(e) => e.stopPropagation()}>
          <button
            onClick={onEdit}
            className="text-gray-400 hover:text-[#F0B90B] transition-colors"
          >
            <Edit2 size={18} />
          </button>
          <button
            onClick={onDelete}
            className="text-gray-400 hover:text-[#F6465D] transition-colors"
          >
            <Trash2 size={18} />
          </button>
        </div>
      </div>

      <div className="flex gap-4 text-sm text-gray-400">
        <span>条件: {conditionCount}</span>
      </div>
    </div>
  );
}

interface IndicatorCreatePageProps {
  onBack: () => void;
  onSave: (indicator: Omit<Indicator, 'id' | 'createdAt'>) => void;
  initialData?: Indicator;
  theme: 'dark' | 'light';
}

function IndicatorCreatePage({ onBack, onSave, initialData, theme }: IndicatorCreatePageProps) {
  const [name, setName] = useState(initialData?.name || '');
  const [conditions, setConditions] = useState<string[]>(
    initialData?.conditions || []
  );
  const [conditionInput, setConditionInput] = useState('');

  const addCondition = () => {
    if (!conditionInput.trim()) return;
    setConditions([
      ...conditions,
      conditionInput
    ]);
    setConditionInput('');
  };

  const removeCondition = (index: number) => {
    setConditions(conditions.filter((_, i) => i !== index));
  };

  const handleSave = () => {
    if (!name.trim()) {
      alert('请输入指标名称');
      return;
    }

    // 如果条件输入框有内容但未点击添加，自动添加
    const finalConditions = [...conditions];
    if (conditionInput.trim()) {
      finalConditions.push(conditionInput);
    }

    if (finalConditions.length === 0) {
      alert('请至少添加一个条件');
      return;
    }

    onSave({
      name,
      conditions: finalConditions
    });
  };

  return (
    <div className={`min-h-screen transition-colors ${
      theme === 'dark' ? 'bg-[#0B0E11]' : 'bg-[#F5F5F5]'
    }`}>
      <div className="p-4 max-w-md mx-auto pb-24">
        {/* Header */}
        <div className="flex items-center justify-center mb-6 relative">
          <button onClick={onBack} className="text-gray-400 hover:text-[#F0B90B] absolute left-0">
            <ChevronLeft size={24} />
          </button>
          <h1 className={`text-xl ${theme === 'dark' ? 'text-white' : 'text-gray-900'}`}>
            开仓理由/指标校验
          </h1>
        </div>

        {/* Indicator Name */}
        <div className="mb-6">
          <label className="text-gray-400 text-sm mb-2 block">指标名称</label>
          <input
            type="text"
            value={name}
            onChange={(e) => setName(e.target.value)}
            placeholder="例如：趋势突破策略"
            className={`w-full rounded-lg px-4 py-3 placeholder:text-gray-600 focus:outline-none focus:ring-2 focus:ring-[#F0B90B] transition-colors ${
              theme === 'dark'
                ? 'bg-[#1A1D23] text-white'
                : 'bg-white shadow-sm text-gray-900'
            }`}
          />
        </div>

        {/* Conditions Card */}
        <div className={`rounded-lg p-4 mb-4 ${
          theme === 'dark' ? 'bg-[#1A1D23]' : 'bg-white shadow-sm'
        }`}>
          <div className="flex items-center justify-between mb-3">
            <h3 className={`${theme === 'dark' ? 'text-white' : 'text-gray-900'}`}>
              条件
            </h3>
            <span className="text-[#F6465D] text-xs">*必须全部满足</span>
          </div>

          <div className="space-y-2 mb-3">
            {conditions.map((condition, index) => (
              <div
                key={index}
                className={`flex items-start gap-3 p-3 rounded-lg ${
                  theme === 'dark' ? 'bg-[#0B0E11]' : 'bg-gray-50'
                }`}
              >
                <Circle size={16} className="text-[#F6465D] flex-shrink-0 mt-0.5" />
                <span className={`flex-1 text-sm ${theme === 'dark' ? 'text-white' : 'text-gray-900'}`}>
                  {condition}
                </span>
                <button
                  onClick={() => removeCondition(index)}
                  className="text-gray-400 hover:text-[#F6465D] transition-colors"
                >
                  <Trash2 size={16} />
                </button>
              </div>
            ))}
          </div>

          <div className="space-y-2">
            <textarea
              value={conditionInput}
              onChange={(e) => setConditionInput(e.target.value)}
              placeholder="输入条件（可换行）"
              rows={2}
              className={`w-full rounded-lg px-4 py-3 placeholder:text-gray-600 focus:outline-none focus:ring-2 focus:ring-[#F0B90B] transition-colors resize-none ${
                theme === 'dark'
                  ? 'bg-[#0B0E11] text-white border border-[#F0B90B]/30'
                  : 'bg-gray-50 text-gray-900 border border-yellow-200'
              }`}
              style={{ minHeight: '60px' }}
              onInput={(e) => {
                e.currentTarget.style.height = 'auto';
                e.currentTarget.style.height = e.currentTarget.scrollHeight + 'px';
              }}
            />
            <button
              onClick={addCondition}
              className="w-full bg-[#F0B90B] hover:bg-[#D9A70A] text-black px-4 py-2 rounded-lg transition-colors flex items-center justify-center gap-2"
            >
              <Plus size={18} />
              <span className="text-sm">添加条件</span>
            </button>
          </div>
        </div>

        {/* Save Button - Fixed at bottom */}
        <div className="fixed bottom-0 left-0 right-0 p-4 bg-gradient-to-t from-[#0B0E11] to-transparent">
          <div className="max-w-md mx-auto">
            <button
              onClick={handleSave}
              className="w-full bg-[#F0B90B] hover:bg-[#D9A70A] text-black py-4 rounded-lg transition-colors font-medium"
            >
              保存指标
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}

interface IndicatorVerifyPageProps {
  indicator: Indicator;
  onBack: () => void;
  onComplete: (indicatorName: string) => void;
  theme: 'dark' | 'light';
}

function IndicatorVerifyPage({ indicator, onBack, onComplete, theme }: IndicatorVerifyPageProps) {
  const [checkedConditions, setCheckedConditions] = useState<Set<number>>(new Set());

  const toggleCondition = (index: number) => {
    const newSet = new Set(checkedConditions);
    if (newSet.has(index)) {
      newSet.delete(index);
    } else {
      newSet.add(index);
    }
    setCheckedConditions(newSet);
  };

  const allConditionsChecked = indicator.conditions.length > 0 &&
    indicator.conditions.every((_, index) => checkedConditions.has(index));

  const handleConfirm = () => {
    if (!allConditionsChecked) {
      alert('请确认所有条件已满足');
      return;
    }
    onComplete(indicator.name);
  };

  return (
    <div className={`min-h-screen transition-colors ${
      theme === 'dark' ? 'bg-[#0B0E11]' : 'bg-[#F5F5F5]'
    }`}>
      <div className="p-4 max-w-md mx-auto pb-24">
        {/* Header */}
        <div className="flex items-center gap-3 mb-6">
          <button onClick={onBack} className="text-gray-400 hover:text-[#F0B90B]">
            <ChevronLeft size={24} />
          </button>
          <h1 className={`text-xl ${theme === 'dark' ? 'text-white' : 'text-gray-900'}`}>
            {indicator.name}
          </h1>
        </div>

        {/* Conditions */}
        {indicator.conditions.length > 0 && (
          <div className={`rounded-lg p-4 mb-4 ${
            theme === 'dark' ? 'bg-[#1A1D23]' : 'bg-white shadow-sm'
          }`}>
            <div className="flex items-center justify-between mb-3">
              <h3 className={`${theme === 'dark' ? 'text-white' : 'text-gray-900'}`}>
                条件
              </h3>
              <span className="text-[#F6465D] text-xs">*必须全部满足</span>
            </div>

            <div className="space-y-2">
              {indicator.conditions.map((condition, index) => {
                const isChecked = checkedConditions.has(index);
                return (
                  <button
                    key={index}
                    onClick={() => toggleCondition(index)}
                    className={`w-full flex items-start gap-3 p-3 rounded-lg transition-colors ${
                      theme === 'dark'
                        ? isChecked ? 'bg-[#F6465D]/10' : 'bg-[#0B0E11] hover:bg-[#12151A]'
                        : isChecked ? 'bg-red-50' : 'bg-gray-50 hover:bg-gray-100'
                    }`}
                  >
                    {isChecked ? (
                      <CheckCircle2 size={20} className="text-[#F6465D] flex-shrink-0 mt-0.5" />
                    ) : (
                      <Circle size={20} className="text-gray-400 flex-shrink-0 mt-0.5" />
                    )}
                    <span className={`flex-1 text-left text-sm ${
                      theme === 'dark' ? 'text-white' : 'text-gray-900'
                    } ${isChecked ? 'opacity-60' : ''}`}>
                      {condition}
                    </span>
                  </button>
                );
              })}
            </div>
          </div>
        )}

        {/* Confirm Button - Fixed at bottom */}
        <div className="fixed bottom-0 left-0 right-0 p-4 bg-gradient-to-t from-[#0B0E11] to-transparent">
          <div className="max-w-md mx-auto">
            <button
              onClick={handleConfirm}
              disabled={!allConditionsChecked}
              className={`w-full py-4 rounded-lg transition-colors font-medium ${
                allConditionsChecked
                  ? 'bg-gradient-to-r from-[#F0B90B] to-[#D9A70A] text-black hover:shadow-lg hover:shadow-[#F0B90B]/30'
                  : theme === 'dark'
                  ? 'bg-[#2B2F36] text-gray-500 cursor-not-allowed'
                  : 'bg-gray-300 text-gray-500 cursor-not-allowed'
              }`}
            >
              确定
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}
