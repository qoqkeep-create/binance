package com.oovso.market;

import com.oovso.market.MarketTickerQueryService.MarketTickerCollection;
import com.oovso.market.MarketTickerQueryService.MarketTickerPage;
import com.oovso.web.ApiResponse;
import jakarta.validation.constraints.Max;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.Size;
import java.io.IOException;
import java.util.List;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/market/tickers")
public class MarketTickerController {

    private final MarketTickerQueryService queryService;

    public MarketTickerController(MarketTickerQueryService queryService) {
        this.queryService = queryService;
    }

    @GetMapping
    public ApiResponse<MarketTickersResponse> tickers()
            throws IOException, InterruptedException {
        MarketTickerCollection snapshot = queryService.all();
        return ApiResponse.success(new MarketTickersResponse(
                snapshot.quoteAsset(),
                snapshot.tickers()
        ));
    }

    @GetMapping("/popular")
    public ApiResponse<MarketTickerPage> popular(
            @RequestParam(defaultValue = "0")
            @Min(value = 0, message = "页码不能小于 0")
            @Max(value = 1_000, message = "页码不能超过 1000")
            int page,

            @RequestParam(defaultValue = "10")
            @Min(value = 1, message = "每页数量不能小于 1")
            @Max(value = 50, message = "每页数量不能超过 50")
            int size
    ) throws IOException, InterruptedException {
        return ApiResponse.success(queryService.query("", page, size));
    }

    @GetMapping("/search")
    public ApiResponse<MarketTickerPage> search(
            @RequestParam(defaultValue = "")
            @Size(max = 64, message = "搜索内容不能超过 64 位")
            String query,

            @RequestParam(defaultValue = "0")
            @Min(value = 0, message = "页码不能小于 0")
            @Max(value = 1_000, message = "页码不能超过 1000")
            int page,

            @RequestParam(defaultValue = "20")
            @Min(value = 1, message = "每页数量不能小于 1")
            @Max(value = 50, message = "每页数量不能超过 50")
            int size
    ) throws IOException, InterruptedException {
        return ApiResponse.success(
                queryService.query(query, page, size)
        );
    }

    public record MarketTickersResponse(
            String quoteAsset,
            List<MarketTickerSnapshot> tickers
    ) {
    }
}
