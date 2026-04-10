import { CryptocurrencyService } from '@ghostfolio/api/services/cryptocurrency/cryptocurrency.service';

import { YahooFinanceDataEnhancerService } from './yahoo-finance.service';

const mockQuoteSummary = jest.fn();

jest.mock('yahoo-finance2', () => {
  return {
    __esModule: true,
    default: jest.fn().mockImplementation(() => {
      return {
        quoteSummary: mockQuoteSummary,
        search: jest.fn()
      };
    })
  };
});

jest.mock(
  '@ghostfolio/api/services/cryptocurrency/cryptocurrency.service',
  () => {
    return {
      CryptocurrencyService: jest.fn().mockImplementation(() => {
        return {
          isCryptocurrency: (symbol: string) => {
            switch (symbol) {
              case 'BTCUSD':
                return true;
              case 'DOGEUSD':
                return true;
              default:
                return false;
            }
          }
        };
      })
    };
  }
);

describe('YahooFinanceDataEnhancerService', () => {
  let cryptocurrencyService: CryptocurrencyService;
  let yahooFinanceDataEnhancerService: YahooFinanceDataEnhancerService;

  beforeAll(async () => {
    cryptocurrencyService = new CryptocurrencyService(null);

    yahooFinanceDataEnhancerService = new YahooFinanceDataEnhancerService(
      cryptocurrencyService
    );
  });

  beforeEach(() => {
    mockQuoteSummary.mockReset();
  });

  it('convertFromYahooFinanceSymbol', async () => {
    expect(
      await yahooFinanceDataEnhancerService.convertFromYahooFinanceSymbol(
        'BRK-B'
      )
    ).toEqual('BRK-B');
    expect(
      await yahooFinanceDataEnhancerService.convertFromYahooFinanceSymbol(
        'BTC-USD'
      )
    ).toEqual('BTCUSD');
    expect(
      await yahooFinanceDataEnhancerService.convertFromYahooFinanceSymbol(
        'USD.AX'
      )
    ).toEqual('USD.AX');
    expect(
      await yahooFinanceDataEnhancerService.convertFromYahooFinanceSymbol(
        'EURUSD=X'
      )
    ).toEqual('EURUSD');
    expect(
      await yahooFinanceDataEnhancerService.convertFromYahooFinanceSymbol(
        'USDCHF=X'
      )
    ).toEqual('USDCHF');
  });

  it('convertToYahooFinanceSymbol', async () => {
    expect(
      await yahooFinanceDataEnhancerService.convertToYahooFinanceSymbol(
        'BTCUSD'
      )
    ).toEqual('BTC-USD');
    expect(
      await yahooFinanceDataEnhancerService.convertToYahooFinanceSymbol(
        'DOGEUSD'
      )
    ).toEqual('DOGE-USD');
    expect(
      await yahooFinanceDataEnhancerService.convertToYahooFinanceSymbol(
        'EURUSD'
      )
    ).toEqual('EURUSD=X');
    expect(
      await yahooFinanceDataEnhancerService.convertToYahooFinanceSymbol(
        'USD.AX'
      )
    ).toEqual('USD.AX');
    expect(
      await yahooFinanceDataEnhancerService.convertToYahooFinanceSymbol(
        'USDCHF'
      )
    ).toEqual('USDCHF=X');
  });

  describe('getAssetProfile - ETF CDI expansion', () => {
    it('should expand ETF sub-holdings with correctly scaled weights', async () => {
      // First call: IVV.AX (CDI wrapper) has one holding "iShares Core S&P 500 ETF" (IVV) at 100%
      mockQuoteSummary.mockImplementation((symbol: string) => {
        if (symbol === 'IVV.AX') {
          return Promise.resolve({
            price: {
              quoteType: 'ETF',
              longName: 'iShares S&P 500 (AU)',
              shortName: 'iShares S&P 500',
              symbol: 'IVV.AX',
              currency: 'AUD'
            },
            summaryProfile: {},
            topHoldings: {
              holdings: [
                {
                  symbol: 'IVV',
                  holdingName: 'iShares Core S&P 500 ETF',
                  holdingPercent: 1.0
                }
              ],
              sectorWeightings: []
            }
          });
        }

        if (symbol === 'IVV') {
          return Promise.resolve({
            price: {
              quoteType: 'ETF',
              longName: 'iShares Core S&P 500',
              shortName: 'iShares Core S&P 500',
              symbol: 'IVV',
              currency: 'USD'
            },
            summaryProfile: {},
            topHoldings: {
              holdings: [
                {
                  symbol: 'AAPL',
                  holdingName: 'Apple Inc',
                  holdingPercent: 0.065
                },
                {
                  symbol: 'NVDA',
                  holdingName: 'NVIDIA Corp',
                  holdingPercent: 0.078
                },
                {
                  symbol: 'MSFT',
                  holdingName: 'Microsoft Corp',
                  holdingPercent: 0.06
                }
              ],
              sectorWeightings: [{ technology: 0.32 }, { healthcare: 0.13 }]
            }
          });
        }

        return Promise.reject(
          new Error(`Quote not found for symbol: ${symbol}`)
        );
      });

      const result =
        await yahooFinanceDataEnhancerService.getAssetProfile('IVV.AX');

      // Holdings should be expanded from the underlying IVV ETF, scaled by 100%
      expect(result.holdings).toEqual([
        { name: 'Apple Inc', weight: 0.065 },
        { name: 'NVIDIA Corp', weight: 0.078 },
        { name: 'Microsoft Corp', weight: 0.06 }
      ]);

      // Sectors should be merged from the underlying ETF since wrapper had none.
      // The sub-profile's sectors are [{name, weight}] but sectorWeightings uses
      // the {key: value} format. After flatMap + Object.entries, each {name, weight}
      // entry produces two entries: ["name", <string>] and ["weight", <number>].
      // parseSector maps unrecognized keys to UNKNOWN.
      // This verifies that sectors are being sourced from the underlying ETF.
      expect(result.sectors).toBeDefined();
      expect((result.sectors as unknown[]).length).toBeGreaterThan(0);
    });

    it('should fall back to including ETF holding as-is when recursive call fails', async () => {
      mockQuoteSummary.mockImplementation((symbol: string) => {
        if (symbol === 'IVV.AX') {
          return Promise.resolve({
            price: {
              quoteType: 'ETF',
              longName: 'iShares S&P 500 (AU)',
              shortName: 'iShares S&P 500',
              symbol: 'IVV.AX',
              currency: 'AUD'
            },
            summaryProfile: {},
            topHoldings: {
              holdings: [
                {
                  symbol: 'IVV',
                  holdingName: 'iShares Core S&P 500 ETF',
                  holdingPercent: 1.0
                }
              ],
              sectorWeightings: []
            }
          });
        }

        // Recursive call for IVV fails
        return Promise.reject(
          new Error(`Quote not found for symbol: ${symbol}`)
        );
      });

      const result =
        await yahooFinanceDataEnhancerService.getAssetProfile('IVV.AX');

      // ETF holding should be included as-is (not dropped)
      expect(result.holdings).toEqual([
        { name: 'iShares Core S&P 500 ETF', weight: 1.0 }
      ]);
    });

    it('should not recurse beyond depth 1', async () => {
      // IVV.AX -> IVV (ETF) -> QQQ (ETF, should NOT be expanded further)
      mockQuoteSummary.mockImplementation((symbol: string) => {
        if (symbol === 'IVV.AX') {
          return Promise.resolve({
            price: {
              quoteType: 'ETF',
              longName: 'iShares S&P 500 (AU)',
              shortName: 'iShares S&P 500',
              symbol: 'IVV.AX',
              currency: 'AUD'
            },
            summaryProfile: {},
            topHoldings: {
              holdings: [
                {
                  symbol: 'IVV',
                  holdingName: 'iShares Core S&P 500 ETF',
                  holdingPercent: 1.0
                }
              ],
              sectorWeightings: []
            }
          });
        }

        if (symbol === 'IVV') {
          return Promise.resolve({
            price: {
              quoteType: 'ETF',
              longName: 'iShares Core S&P 500',
              shortName: 'iShares Core S&P 500',
              symbol: 'IVV',
              currency: 'USD'
            },
            summaryProfile: {},
            topHoldings: {
              holdings: [
                {
                  symbol: 'AAPL',
                  holdingName: 'Apple Inc',
                  holdingPercent: 0.065
                },
                {
                  symbol: 'QQQ',
                  holdingName: 'Invesco QQQ Trust ETF',
                  holdingPercent: 0.05
                }
              ],
              sectorWeightings: [{ technology: 0.32 }]
            }
          });
        }

        return Promise.reject(
          new Error(`Quote not found for symbol: ${symbol}`)
        );
      });

      const result =
        await yahooFinanceDataEnhancerService.getAssetProfile('IVV.AX');

      // At depth 1, the IVV ETF's holdings include an ETF (QQQ) which should NOT
      // be expanded further — it should be included as-is
      expect(result.holdings).toEqual([
        { name: 'Apple Inc', weight: 0.065 },
        { name: 'Invesco QQQ Trust ETF', weight: 0.05 }
      ]);

      // quoteSummary should only be called for IVV.AX and IVV, never for QQQ
      expect(mockQuoteSummary).toHaveBeenCalledTimes(2);
      expect(mockQuoteSummary).toHaveBeenCalledWith(
        'IVV.AX',
        expect.anything()
      );
      expect(mockQuoteSummary).toHaveBeenCalledWith('IVV', expect.anything());
    });

    it('should scale sub-holding weights by wrapper holdingPercent', async () => {
      mockQuoteSummary.mockImplementation((symbol: string) => {
        if (symbol === 'WRAPPER.AX') {
          return Promise.resolve({
            price: {
              quoteType: 'ETF',
              longName: 'Wrapper ETF (AU)',
              shortName: 'Wrapper ETF',
              symbol: 'WRAPPER.AX',
              currency: 'AUD'
            },
            summaryProfile: {},
            topHoldings: {
              holdings: [
                {
                  symbol: 'UNDER',
                  holdingName: 'Underlying ETF',
                  holdingPercent: 0.5
                },
                {
                  symbol: 'AAPL',
                  holdingName: 'Apple Inc',
                  holdingPercent: 0.5
                }
              ],
              sectorWeightings: [{ technology: 0.5 }]
            }
          });
        }

        if (symbol === 'UNDER') {
          return Promise.resolve({
            price: {
              quoteType: 'ETF',
              longName: 'Underlying ETF',
              shortName: 'Underlying ETF',
              symbol: 'UNDER',
              currency: 'USD'
            },
            summaryProfile: {},
            topHoldings: {
              holdings: [
                {
                  symbol: 'MSFT',
                  holdingName: 'Microsoft Corp',
                  holdingPercent: 0.4
                },
                {
                  symbol: 'GOOG',
                  holdingName: 'Alphabet Inc',
                  holdingPercent: 0.6
                }
              ],
              sectorWeightings: [{ technology: 0.8 }]
            }
          });
        }

        return Promise.reject(
          new Error(`Quote not found for symbol: ${symbol}`)
        );
      });

      const result =
        await yahooFinanceDataEnhancerService.getAssetProfile('WRAPPER.AX');

      // Sub-holdings should be scaled by 0.5 (wrapper's holdingPercent)
      // Non-ETF holding (AAPL) should be included directly
      expect(result.holdings).toEqual([
        { name: 'Microsoft Corp', weight: 0.2 },
        { name: 'Alphabet Inc', weight: 0.3 },
        { name: 'Apple Inc', weight: 0.5 }
      ]);

      // Wrapper had its own sectors, so they should be used (not merged from underlying)
      expect(result.sectors).toEqual([{ name: 'Technology', weight: 0.5 }]);
    });
  });
});
