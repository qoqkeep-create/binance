package com.oovso.auth;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import org.junit.jupiter.api.Test;

class PasswordHasherTest {

    private final PasswordHasher passwordHasher = new PasswordHasher();

    @Test
    void hashesAndVerifiesPassword() {
        PasswordHasher.PasswordHash passwordHash =
                passwordHasher.hash("correct horse battery staple");

        assertTrue(passwordHasher.matches(
                "correct horse battery staple",
                passwordHash.hash(),
                passwordHash.salt()
        ));
        assertFalse(passwordHasher.matches(
                "wrong password",
                passwordHash.hash(),
                passwordHash.salt()
        ));
    }

    @Test
    void usesIndependentRandomSalt() {
        PasswordHasher.PasswordHash first =
                passwordHasher.hash("same password");
        PasswordHasher.PasswordHash second =
                passwordHasher.hash("same password");

        assertNotEquals(first.salt(), second.salt());
        assertNotEquals(first.hash(), second.hash());
    }
}
