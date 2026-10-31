package com.oovso.external;

import lombok.Data;

@Data
public class ExternalMessageRow {

    private String id;

    private String payloadJson;

    private Long receivedTimeMs;
}
