package com.oovso.web;

import static org.junit.jupiter.api.Assertions.assertEquals;

import org.junit.jupiter.api.Test;
import org.springframework.http.HttpMethod;
import org.springframework.web.HttpRequestMethodNotSupportedException;
import org.springframework.web.servlet.resource.NoResourceFoundException;

class GlobalApiExceptionHandlerTest {

    private final GlobalApiExceptionHandler handler =
            new GlobalApiExceptionHandler();

    @Test
    void mapsUnsupportedMethodToMethodNotAllowed() {
        var response = handler.handleMethodNotSupported(
                new HttpRequestMethodNotSupportedException("GET")
        );

        assertEquals(405, response.getStatusCode().value());
        assertEquals(405, response.getBody().code());
        assertEquals("请求方法不支持", response.getBody().message());
    }

    @Test
    void mapsMissingResourceToNotFound() {
        var response = handler.handleNoResource(
                new NoResourceFoundException(
                        HttpMethod.GET,
                        "api/reference/trade-signals"
                )
        );

        assertEquals(404, response.getStatusCode().value());
        assertEquals(404, response.getBody().code());
        assertEquals("请求地址不存在", response.getBody().message());
    }
}
