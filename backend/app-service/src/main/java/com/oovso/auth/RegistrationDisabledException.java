package com.oovso.auth;

public class RegistrationDisabledException extends RuntimeException {

    public RegistrationDisabledException() {
        super("Registration is disabled");
    }
}
