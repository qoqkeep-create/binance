package com.oovso.trading;

import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.SecureRandom;
import java.util.Base64;
import javax.crypto.Cipher;
import javax.crypto.Mac;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Component;
import org.springframework.util.StringUtils;

@Component
public class TradingCredentialCipher {

    private static final int NONCE_BYTES = 12;
    private static final int GCM_TAG_BITS = 128;
    private static final int MASTER_KEY_BYTES = 32;

    private final TradingProperties properties;
    private final SecureRandom secureRandom;

    @Autowired
    public TradingCredentialCipher(TradingProperties properties) {
        this(properties, new SecureRandom());
    }

    TradingCredentialCipher(
            TradingProperties properties,
            SecureRandom secureRandom
    ) {
        this.properties = properties;
        this.secureRandom = secureRandom;
    }

    public EncryptedCredential encrypt(
            String userId,
            TradingAccount account,
            BinanceCredentials credentials
    ) {
        SecretKey masterKey = requireMasterKey();
        byte[] nonce = new byte[NONCE_BYTES];
        secureRandom.nextBytes(nonce);

        try {
            Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
            cipher.init(
                    Cipher.ENCRYPT_MODE,
                    masterKey,
                    new GCMParameterSpec(GCM_TAG_BITS, nonce)
            );
            cipher.updateAAD(aad(userId, account));
            byte[] ciphertext = cipher.doFinal(serialize(credentials));

            return new EncryptedCredential(
                    Base64.getEncoder().encodeToString(ciphertext),
                    Base64.getEncoder().encodeToString(nonce),
                    fingerprint(masterKey, credentials.apiKey()),
                    mask(credentials.apiKey()),
                    properties.getCredentialKeyVersion()
            );
        } catch (GeneralSecurityException exception) {
            throw unavailable("交易凭证加密失败", exception);
        }
    }

    public BinanceCredentials decrypt(String userId, TradingAccount account) {
        if (!StringUtils.hasText(account.getCredentialCiphertext())
                || !StringUtils.hasText(account.getCredentialNonce())) {
            throw new TradingApiException(
                    HttpStatus.CONFLICT,
                    "交易账户没有可用凭证，请重新绑定"
            );
        }
        if (!properties.getCredentialKeyVersion().equals(
                account.getCredentialKeyVersion()
        )) {
            throw unavailable("交易凭证密钥版本不匹配，请完成密钥轮换", null);
        }

        try {
            Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
            cipher.init(
                    Cipher.DECRYPT_MODE,
                    requireMasterKey(),
                    new GCMParameterSpec(
                            GCM_TAG_BITS,
                            Base64.getDecoder().decode(
                                    account.getCredentialNonce()
                            )
                    )
            );
            cipher.updateAAD(aad(userId, account));
            return deserialize(cipher.doFinal(
                    Base64.getDecoder().decode(
                            account.getCredentialCiphertext()
                    )
            ));
        } catch (GeneralSecurityException | IllegalArgumentException exception) {
            throw unavailable("交易凭证解密失败，请检查服务器密钥配置", exception);
        }
    }

    private SecretKey requireMasterKey() {
        String encoded = properties.getCredentialMasterKey();
        if (!StringUtils.hasText(encoded)) {
            throw unavailable("服务器交易凭证主密钥尚未配置", null);
        }

        try {
            byte[] bytes = Base64.getDecoder().decode(encoded.trim());
            if (bytes.length != MASTER_KEY_BYTES) {
                throw new IllegalArgumentException("master key must be 32 bytes");
            }
            return new SecretKeySpec(bytes, "AES");
        } catch (IllegalArgumentException exception) {
            throw unavailable("服务器交易凭证主密钥格式错误", exception);
        }
    }

    private byte[] aad(String userId, TradingAccount account) {
        return String.join(
                ":",
                "trade-tool-credential",
                properties.getCredentialKeyVersion(),
                userId,
                account.getId(),
                account.getExchange(),
                account.getMarketType(),
                account.getEnvironment()
        ).getBytes(StandardCharsets.UTF_8);
    }

    private byte[] serialize(BinanceCredentials credentials) {
        byte[] apiKey = credentials.apiKey().getBytes(StandardCharsets.UTF_8);
        byte[] secretKey = credentials.secretKey().getBytes(StandardCharsets.UTF_8);
        return ByteBuffer.allocate(Integer.BYTES * 2 + apiKey.length + secretKey.length)
                .putInt(apiKey.length)
                .put(apiKey)
                .putInt(secretKey.length)
                .put(secretKey)
                .array();
    }

    private BinanceCredentials deserialize(byte[] plaintext) {
        try {
            ByteBuffer buffer = ByteBuffer.wrap(plaintext);
            int apiKeyLength = buffer.getInt();
            if (apiKeyLength <= 0 || apiKeyLength > buffer.remaining()) {
                throw new IllegalArgumentException("invalid api key length");
            }
            byte[] apiKey = new byte[apiKeyLength];
            buffer.get(apiKey);
            int secretKeyLength = buffer.getInt();
            if (secretKeyLength <= 0 || secretKeyLength != buffer.remaining()) {
                throw new IllegalArgumentException("invalid secret key length");
            }
            byte[] secretKey = new byte[secretKeyLength];
            buffer.get(secretKey);
            return new BinanceCredentials(
                    new String(apiKey, StandardCharsets.UTF_8),
                    new String(secretKey, StandardCharsets.UTF_8)
            );
        } catch (RuntimeException exception) {
            throw unavailable("交易凭证内容已损坏，请重新绑定", exception);
        }
    }

    private String fingerprint(SecretKey masterKey, String apiKey) {
        try {
            Mac mac = Mac.getInstance("HmacSHA256");
            mac.init(new SecretKeySpec(masterKey.getEncoded(), "HmacSHA256"));
            return hex(mac.doFinal(
                    ("api-key:" + apiKey).getBytes(StandardCharsets.UTF_8)
            ));
        } catch (GeneralSecurityException exception) {
            throw unavailable("交易凭证指纹生成失败", exception);
        }
    }

    static String mask(String apiKey) {
        if (apiKey.length() <= 10) {
            return "*".repeat(Math.max(apiKey.length(), 4));
        }
        return apiKey.substring(0, 5) + "****"
                + apiKey.substring(apiKey.length() - 5);
    }

    private String hex(byte[] bytes) {
        StringBuilder result = new StringBuilder(bytes.length * 2);
        for (byte value : bytes) {
            result.append(String.format("%02x", value));
        }
        return result.toString();
    }

    private TradingApiException unavailable(String message, Throwable cause) {
        return new TradingApiException(
                HttpStatus.SERVICE_UNAVAILABLE,
                message,
                cause
        );
    }

    public record EncryptedCredential(
            String ciphertext,
            String nonce,
            String fingerprint,
            String apiKeyMasked,
            String keyVersion
    ) {
    }
}
