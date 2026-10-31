package com.oovso.external;

import com.fasterxml.jackson.databind.JsonNode;

public interface ExternalMessageHandler {

    boolean supports(JsonNode payload);

    void handle(ExternalMessage message, JsonNode payload);
}
