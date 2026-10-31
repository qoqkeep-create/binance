package com.oovso.auth;

public class SessionInvalidException extends RuntimeException {

    public SessionInvalidException() {
        super("Authenticated user is unavailable");
    }
}
