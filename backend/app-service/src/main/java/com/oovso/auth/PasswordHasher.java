package com.oovso.auth;

import java.security.GeneralSecurityException;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.Base64;
import javax.crypto.SecretKeyFactory;
import javax.crypto.spec.PBEKeySpec;
import org.springframework.stereotype.Component;

@Component
public class PasswordHasher {

    static final int ITERATIONS = 210_000;
    private static final int SALT_BYTES = 16;
    private static final int KEY_BITS = 256;
    private static final String ALGORITHM = "PBKDF2WithHmacSHA256";

    private final SecureRandom secureRandom = new SecureRandom();

    public PasswordHash hash(String password) {
        byte[] salt = new byte[SALT_BYTES];
        secureRandom.nextBytes(salt);
        byte[] hash = derive(password, salt);
        return new PasswordHash(
                Base64.getEncoder().encodeToString(hash),
                Base64.getEncoder().encodeToString(salt)
        );
    }

    public boolean matches(
            String password,
            String encodedHash,
            String encodedSalt
    ) {
        try {
            byte[] expected = Base64.getDecoder().decode(encodedHash);
            byte[] salt = Base64.getDecoder().decode(encodedSalt);
            byte[] actual = derive(password, salt);
            return MessageDigest.isEqual(expected, actual);
        } catch (IllegalArgumentException exception) {
            return false;
        }
    }

    private byte[] derive(String password, byte[] salt) {
        char[] characters = password.toCharArray();
        PBEKeySpec specification = new PBEKeySpec(
                characters,
                salt,
                ITERATIONS,
                KEY_BITS
        );

        try {
            return SecretKeyFactory.getInstance(ALGORITHM)
                    .generateSecret(specification)
                    .getEncoded();
        } catch (GeneralSecurityException exception) {
            throw new IllegalStateException(
                    "PBKDF2-SHA256 is unavailable",
                    exception
            );
        } finally {
            specification.clearPassword();
            java.util.Arrays.fill(characters, '\0');
        }
    }

    public record PasswordHash(String hash, String salt) {
    }
}
