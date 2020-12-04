import RxSwift

class BaseMarketInfoProvider {
    private let mainProvider: IMarketInfoProvider
    private let uniswapGraphProvider: IMarketInfoProvider

    init(mainProvider: IMarketInfoProvider, uniswapGraphProvider: IMarketInfoProvider) {
        self.mainProvider = mainProvider
        self.uniswapGraphProvider = uniswapGraphProvider
    }
}

extension BaseMarketInfoProvider: IMarketInfoProvider {

    func getMarketInfoRecords(coins: [XRatesKit.Coin], currencyCode: String) -> Single<[MarketInfoRecord]> {
        var ethereumCoins = [XRatesKit.Coin]()
        var otherCoins = [XRatesKit.Coin]()

        for coin in coins {
            switch coin.type {
            case .erc20, .ethereum: ethereumCoins.append(coin)
            default: otherCoins.append(coin)
            }
        }

        return Single.zip(
                mainProvider.getMarketInfoRecords(coins: otherCoins, currencyCode: currencyCode),
                uniswapGraphProvider.getMarketInfoRecords(coins: ethereumCoins, currencyCode: currencyCode)
        ).map { $0 + $1 }
    }

}