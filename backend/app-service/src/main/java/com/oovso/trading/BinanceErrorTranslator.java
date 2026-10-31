package com.oovso.trading;

import java.util.Locale;
import org.springframework.http.HttpStatus;

final class BinanceErrorTranslator {

    private BinanceErrorTranslator() {
    }

    static TradingApiException tradingApiException(
            BinancePrivateApiException error
    ) {
        return new TradingApiException(
                status(error.code()),
                message(error),
                error
        );
    }

    static String message(BinancePrivateApiException error) {
        if (error == null) {
            return "连接币安接口失败，请稍后重试";
        }
        String raw = error.getMessage();
        if (error.code() != null) {
            if (containsChinese(raw)) {
                return raw;
            }
            return message(error.code());
        }
        if (containsChinese(raw)) {
            return raw;
        }
        return "连接币安接口失败，请稍后重试";
    }

    private static boolean containsChinese(String value) {
        return value != null && value.codePoints().anyMatch(
                codePoint -> codePoint >= 0x4E00 && codePoint <= 0x9FFF
        );
    }

    static String storedErrorMessage(String storedCode) {
        if (storedCode == null || storedCode.isBlank()) {
            return null;
        }
        String normalized = storedCode.trim().toUpperCase(Locale.ROOT);
        if (normalized.startsWith("BINANCE_AUTH_")) {
            try {
                return message(Integer.parseInt(normalized.substring(13)));
            } catch (NumberFormatException ignored) {
                return "API密钥认证失败，请重新绑定";
            }
        }
        if (normalized.startsWith("BINANCE_")) {
            try {
                return message(Integer.parseInt(normalized.substring(8)));
            } catch (NumberFormatException ignored) {
                return "币安拒绝了本次请求";
            }
        }
        return switch (normalized) {
            case "CREDENTIAL_DECRYPTION_FAILED" ->
                    "服务器无法解密交易凭证，请重新绑定API密钥";
            case "STREAM_CONNECT_FAILED", "STREAM_CLOSED" ->
                    "币安账户监听连接失败，服务器正在自动重试";
            case "CONVERGENCE_EXHAUSTED" ->
                    "账户数据暂未完成对账，服务器正在自动重试";
            case "WORKER_STOPPED" -> "账户监听已停止";
            case "ENTRY_ORDER_NOT_CANCELABLE" ->
                    "该订单不是可取消的建仓限价委托";
            case "ENTRY_ORDER_ALREADY_FILLED" ->
                    "建仓委托已经全部成交，无法取消";
            case "ENTRY_CANCEL_NOT_CONFIRMED" ->
                    "币安仍显示该建仓委托有效，请刷新后重新取消";
            case "ACCOUNT_NOT_READY" ->
                    "账户尚未同步完成，暂时不能平仓";
            case "POSITION_ALREADY_CLOSED" ->
                    "该持仓已经平仓，请刷新后重试";
            case "MANUAL_CLOSE_ALREADY_ACTIVE" ->
                    "该持仓已有平仓订单处理中，请刷新后重试";
            case "MANUAL_CLOSE_REQUEST_INVALID" ->
                    "平仓参数无效，请刷新后重试";
            case "MANUAL_CLOSE_QUANTITY_INVALID" ->
                    "持仓数量不符合交易对下单步进，无法提交平仓单";
            case "MANUAL_CLOSE_RULES_INVALID" ->
                    "交易对当前不可交易或下单规则无效";
            case "MANUAL_CLOSE_PRICE_INVALID" ->
                    "当前盘口价格无效，无法提交 Maker 平仓单";
            case "MANUAL_CLOSE_REJECTED" ->
                    "Maker 平仓委托未能挂入盘口，请刷新价格后重试";
            case "MANUAL_CLOSE_ORDER_NOT_FOUND",
                 "MANUAL_CLOSE_ORDER_NOT_CANCELABLE" ->
                    "Maker 平仓委托不存在或已结束，请刷新持仓";
            case "MANUAL_CLOSE_ORDER_ALREADY_FILLED" ->
                    "Maker 平仓委托已经成交，无需撤销";
            case "MANUAL_CLOSE_CANCEL_NOT_CONFIRMED" ->
                    "币安仍显示 Maker 平仓委托有效，请刷新后重试";
            case "ORDER_OUTCOME_UNKNOWN", "ORDER_OUTCOME_UNRESOLVED" ->
                    "订单结果暂时无法确认，请先到币安核对，勿重复操作";
            default -> "账户同步异常，服务器正在自动重试";
        };
    }

    static String message(Integer code) {
        if (code == null) {
            return "连接币安接口失败，请稍后重试";
        }
        return switch (code) {
            case -1000 -> "币安服务器发生未知错误，请稍后重试";
            case -1001 -> "币安服务器连接中断，请稍后重试";
            case -1003 -> "请求过于频繁，已触发币安限流，请稍后重试";
            case -1006 -> "币安服务器返回异常，请先核对订单状态";
            case -1007 -> "币安服务器响应超时，请先核对订单状态，勿重复下单";
            case -1015 -> "下单过于频繁，请稍后重试";
            case -1021 -> "服务器时间与币安不同步，请稍后重试";
            case -1022 -> "API签名无效，请重新绑定API密钥";
            case -1100 -> "请求参数包含不允许的字符";
            case -1101 -> "请求参数数量不正确";
            case -1102 -> "缺少币安要求的下单参数";
            case -1111 -> "价格或数量精度超过交易对限制";
            case -1112 -> "当前盘口没有可成交订单";
            case -1115 -> "订单有效期类型无效";
            case -1116 -> "订单类型无效";
            case -1117 -> "买卖方向无效";
            case -1118, -1119 -> "客户端订单编号无效";
            case -1121 -> "交易对不存在或已停止交易";
            case -1125 -> "币安账户监听凭证已失效，服务器将重新连接";
            case -2010 -> "币安拒绝了新订单，请检查价格、数量和账户状态";
            case -2011 -> "币安拒绝撤单，订单可能已成交或已撤销";
            case -2013 -> "币安未找到该订单";
            case -2014 -> "API密钥格式无效，请重新绑定";
            case -2015 -> "API密钥无效、IP不在白名单或缺少合约交易权限";
            case -2018 -> "账户余额不足，无法完成本次操作";
            case -2019 -> "合约保证金不足，无法提交订单";
            case -2020 -> "订单当前无法成交，请检查价格和盘口流动性";
            case -2021 -> "条件单会被当前价格立即触发，请调整触发价格";
            case -2022 -> "只减仓订单被拒绝，请检查当前仓位和未成交减仓单";
            case -2023 -> "账户正在强制平仓，暂时不能提交新订单";
            case -2024 -> "当前持仓数量不足，无法执行本次减仓";
            case -2025 -> "当前交易对的未成交订单数量已达上限";
            case -2026 -> "该订单类型不支持只减仓参数";
            case -2027 -> "当前杠杆下订单会超过币安允许的最大持仓，请减小仓位或降低杠杆";
            case -2028 -> "当前保证金不足以使用所选低杠杆，请提高杠杆或补充保证金";
            case -4003 -> "下单数量必须大于0";
            case -4004 -> "下单数量低于交易对最小数量";
            case -4005 -> "下单数量超过交易对最大数量";
            case -4008, -4014 -> "价格不符合交易对最小变动单位";
            case -4013 -> "下单价格低于交易对最低价格";
            case -4015 -> "客户端订单编号过长或格式无效";
            case -4016 -> "下单价格高于币安允许范围";
            case -4023 -> "下单数量不符合交易对步进单位";
            case -4024 -> "下单价格低于币安允许范围";
            case -4045 -> "当前交易对的条件单数量已达上限";
            case -4050 -> "全仓账户可用余额不足";
            case -4051 -> "逐仓账户可用余额不足";
            case -4059 -> "账户已经是双向持仓模式，无需重复设置";
            case -4060 -> "持仓方向参数无效";
            case -4061 -> "订单持仓方向与账户持仓模式不一致，请在币安将账户"
                    + "切换为双向持仓模式后重试";
            case -4062 -> "只减仓参数与当前订单冲突";
            case -4067 -> "账户存在未成交订单，无法切换为双向持仓，请先撤单";
            case -4068 -> "账户存在持仓，无法切换为双向持仓，请先平仓";
            case -4088 -> "API密钥没有合约下单权限";
            case -4116 -> "客户端订单编号重复，请先核对原订单";
            case -4164 -> "订单名义价值低于交易对最低要求";
            case -5022 -> "只做Maker订单会立即成交，币安已拒绝该订单";
            default -> "币安拒绝了本次请求（错误码 " + code + "）";
        };
    }

    private static HttpStatus status(Integer code) {
        if (Integer.valueOf(-2014).equals(code)
                || Integer.valueOf(-2015).equals(code)) {
            return HttpStatus.UNPROCESSABLE_ENTITY;
        }
        if (Integer.valueOf(-1003).equals(code)
                || Integer.valueOf(-1015).equals(code)) {
            return HttpStatus.TOO_MANY_REQUESTS;
        }
        if (Integer.valueOf(-4067).equals(code)
                || Integer.valueOf(-4068).equals(code)
                || Integer.valueOf(-2027).equals(code)
                || Integer.valueOf(-2028).equals(code)) {
            return HttpStatus.CONFLICT;
        }
        return HttpStatus.BAD_GATEWAY;
    }
}
