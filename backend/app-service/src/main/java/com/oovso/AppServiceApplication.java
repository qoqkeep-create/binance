package com.oovso;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

@SpringBootApplication
public class AppServiceApplication {

    static {
        setDefaultSystemProperty("io.netty.noUnsafe", "true");
    }

    static void main(String[] args) {
        SpringApplication.run(AppServiceApplication.class, args);
    }

    private static void setDefaultSystemProperty(String key, String value) {
        if (System.getProperty(key) == null) {
            System.setProperty(key, value);
        }
    }
}
