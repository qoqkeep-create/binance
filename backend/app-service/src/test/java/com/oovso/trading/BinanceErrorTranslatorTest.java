package com.oovso.trading;

import static org.junit.jupiter.api.Assertions.assertEquals;

import org.junit.jupiter.api.Test;

class BinanceErrorTranslatorTest {

    @Test
    void translatesKnownOrderAndAccountSetupErrors() {
        assertEquals(
                "订单持仓方向与账户持仓模式不一致，请在币安将账户"
                        + "切换为双向持仓模式后重试",
                BinanceErrorTranslator.storedErrorMessage("BINANCE_-4061")
        );
        assertEquals(
                "账户存在未成交订单，无法切换为双向持仓，请先撤单",
                BinanceErrorTranslator.message(-4067)
        );
        assertEquals(
                "API密钥无效、IP不在白名单或缺少合约交易权限",
                BinanceErrorTranslator.storedErrorMessage(
                        "BINANCE_AUTH_-2015"
                )
        );
        assertEquals(
                "当前杠杆下订单会超过币安允许的最大持仓，请减小仓位或降低杠杆",
                BinanceErrorTranslator.storedErrorMessage("BINANCE_-2027")
        );
    }

    @Test
    void unknownExchangeCodeDoesNotExposeEnglishText() {
        assertEquals(
                "币安拒绝了本次请求（错误码 -4999）",
                BinanceErrorTranslator.message(-4999)
        );
    }

    @Test
    void preservesExplicitChineseSafetyMessageForKnownCode() {
        String safetyMessage = "账户存在持仓或未成交订单，服务器不会自动切换持仓模式";
        assertEquals(
                safetyMessage,
                BinanceErrorTranslator.message(
                        new BinancePrivateApiException(-4061, safetyMessage)
                )
        );
        assertEquals(
                "订单持仓方向与账户持仓模式不一致，请在币安将账户"
                        + "切换为双向持仓模式后重试",
                BinanceErrorTranslator.message(
                        new BinancePrivateApiException(
                                -4061,
                                "Order's position side does not match"
                        )
                )
        );
    }
}
