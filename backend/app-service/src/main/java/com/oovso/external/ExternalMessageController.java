package com.oovso.external;

import com.oovso.web.ApiResponse;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/external/messages")
public class ExternalMessageController {

    static final String API_KEY_HEADER = "X-External-Message-Key";

    private final ExternalMessageService messageService;

    public ExternalMessageController(ExternalMessageService messageService) {
        this.messageService = messageService;
    }

    @PostMapping(consumes = MediaType.APPLICATION_JSON_VALUE)
    public ResponseEntity<ApiResponse<Void>> accept(
            @RequestHeader(value = API_KEY_HEADER, required = false)
            String apiKey,
            @RequestBody(required = false) String payloadJson
    ) {
        messageService.accept(apiKey, payloadJson);
        return ResponseEntity.status(HttpStatus.ACCEPTED)
                .body(new ApiResponse<>(
                        HttpStatus.ACCEPTED.value(),
                        "accepted",
                        null
                ));
    }
}
