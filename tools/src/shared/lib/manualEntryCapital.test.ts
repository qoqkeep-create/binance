import { describe, expect, it } from 'vitest'
import { getCapitalControlAvailability } from './manualEntryCapital'

describe('capital controls', () => {
  it('does not count separately untransferable wallet dust toward the opening line', () => {
    expect(getCapitalControlAvailability({
      thresholdLoaded: true,
      futuresBalance: 299,
      fundingBalance: 0.5,
      spotBalance: 0.5,
      openingMinimum: 300,
      retentionMaximum: 1000,
    })).toEqual({ collectionEnabled: false, reminderEnabled: true })
  })

  it('does not enable outward collection for an internal refill below the cap', () => {
    expect(getCapitalControlAvailability({
      thresholdLoaded: true,
      futuresBalance: 200,
      fundingBalance: 50,
      spotBalance: 0,
      openingMinimum: 300,
      retentionMaximum: 1000,
    })).toEqual({ collectionEnabled: false, reminderEnabled: true })
  })

  it('only allows collection when usable funds exceed the retention cap', () => {
    const common = {
      thresholdLoaded: true,
      openingMinimum: 300,
      retentionMaximum: 1000,
    }
    expect(getCapitalControlAvailability({
      ...common,
      futuresBalance: 1001,
      fundingBalance: 0,
      spotBalance: 0,
    }).collectionEnabled).toBe(true)
    expect(getCapitalControlAvailability({
      ...common,
      futuresBalance: 500,
      fundingBalance: 0,
      spotBalance: 1,
    }).collectionEnabled).toBe(false)
  })

  it.each([1000, 1000.004, 1000.009, 1000.01, 1000.019])('compares the cent boundary exactly at %s', futuresBalance => {
    expect(getCapitalControlAvailability({
      thresholdLoaded: true, futuresBalance, fundingBalance: 0, spotBalance: 0,
      openingMinimum: 300, retentionMaximum: 1000,
    }).collectionEnabled).toBe(futuresBalance >= 1000.01)
  })

  it('counts transferable wallets toward the cap but ignores wallet dust', () => {
    const common = { thresholdLoaded: true, futuresBalance: 999.5, openingMinimum: 300, retentionMaximum: 1000 }
    expect(getCapitalControlAvailability({ ...common, fundingBalance: 0.5, spotBalance: 0.5 }).collectionEnabled).toBe(false)
    expect(getCapitalControlAvailability({ ...common, fundingBalance: 1, spotBalance: 0 }).collectionEnabled).toBe(true)
  })

  it('does not enable collection for an untransferable sub-cent futures excess', () => {
    const common = {
      thresholdLoaded: true,
      fundingBalance: 0,
      spotBalance: 0,
      openingMinimum: 300,
      retentionMaximum: 1000,
    }
    expect(getCapitalControlAvailability({
      ...common,
      futuresBalance: 1000.004,
    }).collectionEnabled).toBe(false)
    expect(getCapitalControlAvailability({
      ...common,
      futuresBalance: 1000.019,
    }).collectionEnabled).toBe(true)
  })
})
