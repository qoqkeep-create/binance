import { useState } from 'react'

import { showToast } from '@/shared/store'

interface PreflightQuestion {
  id: string
  prompt: string
  correct: string
  distractors: string[]
}

const QUESTION_BANK: PreflightQuestion[] = [
  {
    id: 'position-first',
    prompt: '1、进入一笔交易时，最优先考虑的应该是什么？',
    correct: '价格所处的位置是最优先考虑的点，优先找关键位置，而不是反转 K 线或者其他指标',
    distractors: [
      '只要出现 Pin Bar / 吞没形态，就可以优先考虑进场',
      'RSI 超卖超买比价格位置更重要',
      'MACD 背离出现时，可以忽略位置直接尝试',
      '指标共振越多，位置的重要性越低',
    ],
  },
  {
    id: 'ema144',
    prompt: '2、系统内理想的入场点，应该尽量靠近哪里？',
    correct: '入场点尽可能靠近 EMA144',
    distractors: [
      '只要方向正确，距离 EMA 多远都可以追',
      '行情启动后第一时间追进去最重要',
      '怕错过行情时可以放宽 EMA 距离',
      '趋势行情不需要等回踩',
    ],
  },
  {
    id: 'reversal-confirm',
    prompt: '3、关于入场确认，哪一项更符合你的交易原则？',
    correct: '等待形成反转 K 线以后入场，按照反转 K 线定点止损，其盈亏比比盲入更稳，盈亏比更优',
    distractors: [
      '预判永远比确认更赚钱',
      '提前进场可以拿到最低点',
      '不需要等 K 线确认，感觉到了就可以先进',
      '真正的高手都是提前埋伏',
    ],
  },
  {
    id: 'higher-timeframe',
    prompt: '4、周期之间的观察顺序，正确的是哪一项？',
    correct: '优先看大周期，根据大周期再依次缩小周期去找入场点',
    distractors: [
      '小周期信号最灵敏，优先级最高',
      '1 分钟周期能最快发现机会',
      '只做超短线时，大周期可以忽略',
      '先找进场点，再看大周期方向',
    ],
  },
  {
    id: 'loss-discipline',
    prompt: '5、连续亏损后的正确处理方式是什么？',
    correct: '连续亏损后应降低频率，而不是急于翻本',
    distractors: [
      '连亏后下一单应该加仓翻回来',
      '状态不好时更应该频繁交易找感觉',
      '亏损后立即重仓是恢复信心最快的方法',
      '连亏说明快轮到自己赚钱了',
    ],
  },
  {
    id: 'no-setup',
    prompt: '6、没有符合系统的机会时，正确选择是什么？',
    correct: '没有机会时候，应该空仓等待，去复盘过往记录，去完善过程控制系统',
    distractors: [
      '没机会时可以轻仓试错找感觉',
      '长时间空仓容易错过突然启动的行情',
      '没有标准机会时，可以降低条件做单',
      '盘感好的时候不一定非要等系统信号',
      '做交易最重要的是保持市场参与感',
      '行情少的时候应该增加观察周期去寻找机会',
      '只要控制仓位，随便做一点问题不大',
      '没机会时可以做自己“感觉最强”的品种',
      '等机会太被动，主动试单更容易抓节奏',
      '市场每天都有机会，只是有没有发现',
      '复盘不如实战，真正的经验来自做单',
      '空仓太久会导致执行力下降',
      '横盘行情更适合高频试单',
      '小止损多尝试，总能抓到一次趋势',
      '交易员应该持续保持出手状态',
      '看得越久，机会自然会出现',
      '没有明显机会时，可以通过加杠杆提高收益效率',
      '与其空仓，不如小仓位保持市场温度',
      '没有机会时应该多开图、多找形态',
      '真正的高手会在别人看不懂的时候提前布局',
    ],
  },
  {
    id: 'fomo',
    prompt: '7、关于错过与追单，哪一项更符合你的系统？',
    correct: '错过行情比做错行情更容易接受',
    distractors: [
      '错过比亏损更难受，所以应该追',
      '行情已经启动更说明方向正确',
      '强势行情不能等回踩',
      '不敢追说明执行力差',
    ],
  },
  {
    id: 'wait-for-certainty',
    prompt: '8、面对不够确定的入场机会时，正确态度是什么？',
    correct: '宁可不做，等待确定时机，而不是着急入场亏掉本金，等待并不会让你损失，越急越亏',
    distractors: [
      '先上车再观察，机会往往稍纵即逝',
      '犹豫太久会错过最佳利润',
      '提前试仓比完全错过更重要',
      '行情启动后确认就已经太晚了',
      '做交易最怕没有参与感',
      '等待会降低交易节奏和盘感',
      '越早入场，利润空间越大',
      '真正的大行情往往不给确认机会',
      '小仓位提前埋伏风险并不大',
      '慢一步就意味着盈亏比变差',
      '市场不会等人，必须主动出击',
      '先试错，再根据走势调整',
      '机会是抢出来的，不是等出来的',
      '趋势初期应该大胆预判',
      '害怕入场本质上是不够自信',
      '确认太多会错过最肥的一段行情',
    ],
  },
  {
    id: 'quality-over-probing',
    prompt: '9、机会质量和仓位之间，哪种理解更符合你的系统？',
    correct: '确定的机会搭配合理的仓位，比模糊的机会试图用小仓位赚取利润更重要',
    distractors: [
      '只要仓位小，任何位置都可以尝试',
      '小仓位试错没有成本',
      '高频小仓位更容易抓住行情',
      '模糊机会也可能变成大行情',
      '做得多总会遇到正确行情',
      '小仓位可以忽略系统要求',
      '机会不明确时更应该提前布局',
      '用轻仓不断试单才容易抓启动点',
      '仓位比机会质量更重要',
      '盈利主要靠次数堆积',
      '小亏多次无所谓，抓一次就够',
      '看不懂的时候轻仓试最合理',
      '不敢试错会错过很多行情',
      '模糊机会可以通过加仓弥补',
      '轻仓交易不需要太严格',
      '高手都是不断试单试出来的',
      '小止损高频试错是最高效的方法',
      '仓位小的时候可以适当放宽标准',
    ],
  },
  {
    id: 'obvious-or-trap',
    prompt: '10、对于需要你反复分析、越看越纠结的机会，哪种判断更符合你的系统？',
    correct: '如果不是一眼就能看出来的机会，需要反复分析的，不是机会而是陷阱',
    distractors: [
      '深度分析越久，胜率越高',
      '真正的大机会往往隐藏很深',
      '复杂行情更适合高手发挥',
      '需要推演的机会利润空间更大',
      '越难看懂的走势越值得研究',
      '只要逻辑能自洽，就可以做',
      '多找几个理由支持就能提高胜率',
      '看不懂的时候应该继续盯盘等待感觉',
      '复杂结构往往意味着大行情',
      '反复分析说明自己足够认真',
      '好机会通常需要耐心挖掘',
      '越多人看不懂，越可能是机会',
      '交易需要不断推演各种可能性',
      '机会本来就需要花时间确认',
      '一眼看懂的行情通常已经晚了',
      '越复杂的走势越容易产生超额利润',
      '怀疑自己时更应该加强分析',
      '只要盈亏比合适，模糊机会也值得做',
    ],
  },
]

function shuffle<T>(items: T[]): T[] {
  const next = [...items]
  for (let i = next.length - 1; i > 0; i -= 1) {
    const j = Math.floor(Math.random() * (i + 1))
    ;[next[i], next[j]] = [next[j], next[i]]
  }
  return next
}

function buildQuestionSet() {
  const questionCount = Math.min(10, QUESTION_BANK.length)
  return shuffle(QUESTION_BANK).slice(0, questionCount).map(question => ({
    ...question,
    options: shuffle([question.correct, ...shuffle(question.distractors).slice(0, 4)]),
  }))
}

interface PreflightModalProps {
  onComplete: () => Promise<void> | void
}

export function PreflightModal({ onComplete }: PreflightModalProps) {
  const [questions, setQuestions] = useState(buildQuestionSet)
  const [answers, setAnswers] = useState<Record<string, string>>({})
  const [currentIndex, setCurrentIndex] = useState(0)
  const [submitting, setSubmitting] = useState(false)

  const currentQuestion = questions[currentIndex]
  const selectedAnswer = currentQuestion ? answers[currentQuestion.id] : ''
  const canProceed = currentQuestion ? selectedAnswer === currentQuestion.correct : false
  const isLastQuestion = currentIndex === questions.length - 1

  const restart = () => {
    setAnswers({})
    setCurrentIndex(0)
    setQuestions(buildQuestionSet())
  }

  const handleContinue = async () => {
    if (!currentQuestion) return
    if (!canProceed) {
      showToast('请先选择正确答案')
      return
    }
    if (isLastQuestion) {
      try {
        setSubmitting(true)
        await onComplete()
        showToast('校准完成，进入系统')
      } finally {
        setSubmitting(false)
      }
      return
    }
    setCurrentIndex(index => index + 1)
  }

  return (
    <div className="fixed inset-0 z-[120] flex items-center justify-center p-4">
      <div className="absolute inset-0 bg-black/65 backdrop-blur-sm" />
      <div className="relative w-full max-w-3xl rounded-3xl border border-t-border bg-t-surface shadow-2xl overflow-hidden">
        <div className="border-b border-t-border px-6 py-5">
          <div className="flex items-center justify-between gap-4">
            <div>
              <div className="text-2xl font-bold">交易前校准</div>
              <div className="mt-2 text-sm leading-6 text-t-text-secondary">
                在进入系统前，先把注意力拉回到交易原则。当前题答对后，才能继续下一题。
              </div>
            </div>
            <div className="shrink-0 rounded-xl bg-[#F0B90B]/10 px-4 py-2 text-sm font-bold text-[#F0B90B]">
              第{currentIndex + 1}/{questions.length}题
            </div>
          </div>
        </div>

        {currentQuestion ? (
          <div className="px-6 py-6">
            <div className="rounded-2xl border border-t-border bg-t-page p-5">
              <div className="text-lg font-semibold leading-8">{currentQuestion.prompt.replace(/^\d+、/, '')}</div>
              <div className="mt-5 space-y-3">
                {currentQuestion.options.map(option => {
                  const isSelected = selectedAnswer === option
                  const isWrongSelected = isSelected && option !== currentQuestion.correct
                  const isCorrectSelected = isSelected && option === currentQuestion.correct
                  return (
                    <button
                      key={option}
                      type="button"
                      onClick={() => setAnswers(prev => ({ ...prev, [currentQuestion.id]: option }))}
                      className={`w-full rounded-2xl border px-4 py-3 text-left text-sm leading-6 transition-colors ${
                        isCorrectSelected
                          ? 'border-[#0ECB81] bg-[#0ECB81]/10 text-t-text'
                          : isWrongSelected
                            ? 'border-[#F6465D] bg-[#F6465D]/10 text-t-text'
                            : 'border-t-border bg-t-surface hover:bg-t-surface-hover'
                      }`}
                    >
                      {option}
                    </button>
                  )
                })}
              </div>
              {selectedAnswer && !canProceed ? (
                <div className="mt-4 text-sm font-medium text-[#F6465D]">这不是系统答案，请重新选择。</div>
              ) : null}
            </div>
          </div>
        ) : null}

        <div className="border-t border-t-border px-6 py-5 flex items-center justify-between gap-4">
          <button
            type="button"
            onClick={restart}
            className="rounded-xl border border-t-border px-4 py-2 font-medium hover:bg-t-surface-hover"
          >
            重新出题
          </button>
          <button
            type="button"
            onClick={handleContinue}
            disabled={!canProceed || submitting}
            className="rounded-xl bg-[#F0B90B] px-5 py-2.5 font-bold text-black hover:bg-[#D9A70A] disabled:cursor-not-allowed disabled:opacity-50"
          >
            {isLastQuestion ? (submitting ? '提交中...' : '完成') : '下一题'}
          </button>
        </div>
      </div>
    </div>
  )
}
