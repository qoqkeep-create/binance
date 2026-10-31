package com.oovso.external;

import com.fasterxml.jackson.databind.JsonNode;
import java.util.List;
import org.springframework.stereotype.Component;

@Component
public class ExternalMessageDispatcher {

    private final List<ExternalMessageHandler> handlers;

    public ExternalMessageDispatcher(List<ExternalMessageHandler> handlers) {
        this.handlers = List.copyOf(handlers);
    }

    public void dispatch(ExternalMessage message, JsonNode payload) {
        for (ExternalMessageHandler handler : handlers) {
            if (handler.supports(payload)) {
                handler.handle(message, payload);
            }
        }
    }
}
