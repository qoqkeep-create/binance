package com.oovso.auth;

public class AccountAlreadyExistsException extends RuntimeException {

    public AccountAlreadyExistsException() {
        super("Account already exists");
    }
}
