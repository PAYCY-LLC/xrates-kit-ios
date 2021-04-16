import Foundation
import HsToolKit
import RxSwift
import Alamofire
import CoinKit

class CoinGeckoProvider {
    private let disposeBag = DisposeBag()
    private let provider = InfoProvider.CoinGecko

    private let providerCoinsManager: ProviderCoinsManager
    private let networkManager: ProviderNetworkManager
    private let expirationInterval: TimeInterval
    private let coinsPerPage = 250

    init(providerCoinsManager: ProviderCoinsManager, expirationInterval: TimeInterval, logger: Logger) {
        self.providerCoinsManager = providerCoinsManager
        self.expirationInterval = expirationInterval

        networkManager = ProviderNetworkManager(requestInterval: provider.requestInterval, logger: logger)
    }

    private func marketsRequest(currencyCode: String, fetchDiffPeriod: TimePeriod, pageParams: String = "", coinIdsParams: String = "") -> DataRequest {
        let priceChangePercentage: String
        switch fetchDiffPeriod {
        case .hour24, .dayStart: priceChangePercentage = ""
        default: priceChangePercentage = "&price_change_percentage=\(fetchDiffPeriod.title)"
        }

        let url = "\(provider.baseUrl)/coins/markets?\(coinIdsParams)&vs_currency=\(currencyCode)\(priceChangePercentage)&order=market_cap_desc\(pageParams)"
        return networkManager.session.request(url, method: .get, encoding: JSONEncoding())
    }

}

extension CoinGeckoProvider {

    func globalDefiMarketCap(currencyCode: String) -> Single<Decimal> {
        let url = "\(provider.baseUrl)/global/decentralized_finance_defi"
        let request = networkManager.session.request(url, method: .get, encoding: JSONEncoding())

        let mapper = CoinGeckoDefiMarketCapMapper()
        return networkManager.single(request: request, mapper: mapper)
    }

    func coinMarketInfoSingle(coinType: CoinType, currencyCode: String, rateDiffTimePeriods: [TimePeriod], rateDiffCoinCodes: [String]) -> Single<CoinGeckoCoinMarketInfoMapper.CoinGeckoCoinInfoResponse> {
        guard let externalId = providerCoinsManager.providerId(coinType: coinType, provider: .CoinGecko) else {
            return Single.error(ProviderCoinsManager.ExternalIdError.noMatchingCoinId)
        }

        let url = "\(provider.baseUrl)/coins/\(externalId)?localization=false&tickers=true&developer_data=false&sparkline=false"
        let request = networkManager.session.request(url, method: .get, encoding: JSONEncoding())

        let mapper = CoinGeckoCoinMarketInfoMapper(coinType: coinType, currencyCode: currencyCode.lowercased(), timePeriods: rateDiffTimePeriods, rateDiffCoinCodes: rateDiffCoinCodes.map { $0.lowercased() })
        return networkManager.single(request: request, mapper: mapper)
    }

    func topCoinMarketsSingle(currencyCode: String, fetchDiffPeriod: TimePeriod, itemCount: Int, page: Int = 1) -> Single<[CoinMarket]> {
        let expectedItemsCount = min(coinsPerPage, itemCount)
        let perPage = page > 1 ? coinsPerPage : min(coinsPerPage, itemCount)
        let pageParams = "&per_page=\(perPage)&page=\(page)"

        let request = marketsRequest(currencyCode: currencyCode, fetchDiffPeriod: fetchDiffPeriod, pageParams: pageParams)
        let mapper = CoinGeckoTopMarketMapper(providerCoinManager: providerCoinsManager, currencyCode: currencyCode, fetchDiffPeriod: fetchDiffPeriod, expirationInterval: expirationInterval)

        return networkManager.single(request: request, mapper: mapper)
                .flatMap { [weak self] coinMarkets -> Single<[CoinMarket]> in
                    guard let provider = self, coinMarkets.count > 0 else {
                        return Single.just(coinMarkets)
                    }

                    if itemCount <= provider.coinsPerPage, itemCount <= coinMarkets.count {
                        return Single.just(Array(coinMarkets[0..<itemCount]))
                    }

                    var nextItemCount = itemCount
                    if coinMarkets.count < expectedItemsCount {
                        nextItemCount += expectedItemsCount - coinMarkets.count
                    }
                    nextItemCount = nextItemCount - provider.coinsPerPage

                    return provider
                            .topCoinMarketsSingle(currencyCode: currencyCode, fetchDiffPeriod: fetchDiffPeriod, itemCount: nextItemCount, page: page + 1)
                            .map { nextCoinMarkets -> [CoinMarket] in coinMarkets + nextCoinMarkets }
                }
    }

    func coinMarketsSingle(currencyCode: String, fetchDiffPeriod: TimePeriod, coinTypes: [CoinType]) -> Single<[CoinMarket]> {
        let externalIds = coinTypes.compactMap { providerCoinsManager.providerId(coinType: $0, provider: .CoinGecko) }
        let coinIdParams = externalIds.isEmpty ? "" : "&ids=\(externalIds.joined(separator: ","))"

        let request = marketsRequest(currencyCode: currencyCode, fetchDiffPeriod: fetchDiffPeriod, coinIdsParams: coinIdParams)
        let mapper = CoinGeckoTopMarketMapper(providerCoinManager: providerCoinsManager, currencyCode: currencyCode, fetchDiffPeriod: fetchDiffPeriod, expirationInterval: expirationInterval)

        return networkManager.single(request: request, mapper: mapper)
    }

}

extension CoinGeckoProvider: IChartPointProvider {

    func chartPointsSingle(key: ChartInfoKey) -> Single<[ChartPoint]> {
        guard let externalId = providerCoinsManager.providerId(coinType: key.coinType, provider: .CoinGecko) else {
            return Single.error(ProviderCoinsManager.ExternalIdError.noMatchingCoinId)
        }

        let url = "\(provider.baseUrl)/coins/\(externalId)/market_chart?vs_currency=\(key.currencyCode)&days=\(key.chartType.coinGeckoDaysParameter)"
        let request = networkManager.session.request(url, method: .get, encoding: JSONEncoding())

        return networkManager.single(request: request, mapper: CoinGeckoMarketChartsMapper())
                .map { points in
                    guard key.chartType.coinGeckoPointCount <= points.count else {
                        return points
                    }

                    var result = [ChartPoint]()
                    var nextPointTime: TimeInterval = 0
                    var aggregatedVolume: Decimal?

                    for point in points {
                        point.volume.flatMap { aggregatedVolume = (aggregatedVolume ?? 0) + $0 }

                        if point.timestamp >= nextPointTime {
                            let volume = key.chartType.resource == "histoday" ? aggregatedVolume : nil
                            result.append(ChartPoint(timestamp: point.timestamp, value: point.value, volume: volume))

                            nextPointTime = point.timestamp + key.chartType.intervalInSeconds - 180
                            aggregatedVolume = nil
                        }
                    }

                    return result
                }
    }

}

extension CoinGeckoProvider: ILatestRatesProvider {

    func latestRateRecords(coinTypes: [CoinType], currencyCode: String) -> Single<[LatestRateRecord]> {
        var coinTypesMap = [String: [CoinType]]()
        for coinType in coinTypes {
            if let providerCoinId = providerCoinsManager.providerId(coinType: coinType, provider: .CoinGecko) {
                if coinTypesMap[providerCoinId] == nil {
                    coinTypesMap[providerCoinId] = [coinType]
                } else {
                    coinTypesMap[providerCoinId]?.append(coinType)
                }
            }
        }

        let coinIdsParams = "&ids=\(coinTypesMap.keys.joined(separator: ","))"

        let url = "\(provider.baseUrl)/simple/price?\(coinIdsParams)" +
                        "&vs_currencies=\(currencyCode)&include_market_cap=false" +
                        "&include_24hr_vol=false&include_24hr_change=true&include_last_updated_at=false"

        let request = networkManager.session.request(url, method: .get, encoding: JSONEncoding())

        return networkManager.single(request: request, mapper: CoinGeckoCoinPriceMapper(coinTypesMap: coinTypesMap, currencyCode: currencyCode))
    }

}

extension CoinGeckoProvider: IHistoricalRateProvider {

    func getHistoricalRate(coinType: CoinType, currencyCode: String, timestamp: TimeInterval) -> Single<Decimal> {
        guard let externalId = providerCoinsManager.providerId(coinType: coinType, provider: .CoinGecko) else {
            return Single.error(ProviderCoinsManager.ExternalIdError.noMatchingCoinId)
        }

        let currentTime = Date().timeIntervalSince1970
        let startTime, endTime: TimeInterval

        if currentTime - timestamp <= 24 - 10 * 60 {
            startTime = timestamp - 10 * 60
            endTime = timestamp + 10 * 60
        } else {
            startTime = timestamp - 2 * 60 * 60
            endTime = timestamp + 2 * 60 * 60
        }

        let url = "\(provider.baseUrl)/coins/\(externalId)/market_chart/range?vs_currency=\(currencyCode)&from=\(startTime)&to=\(endTime)"
        let request = networkManager.session.request(url, method: .get, encoding: JSONEncoding())

        return networkManager.single(request: request, mapper: CoinGeckoMarketChartsMapper())
                .map { rates in
                    var nearestTime: TimeInterval?
                    var nearestRate: Decimal = 0

                    for rate in rates {
                        let timeDiff = abs(rate.timestamp - timestamp)

                        if let time = nearestTime {
                            if timeDiff < time {
                                nearestTime = timeDiff
                                nearestRate = rate.value
                            }
                        } else {
                            nearestTime = timeDiff
                            nearestRate = rate.value
                        }
                    }

                    return nearestRate
                }
    }

}

extension CoinGeckoProvider {

    enum RequestError: Error {
        case rateLimitExceeded
        case noDataForSymbol
    }

}
