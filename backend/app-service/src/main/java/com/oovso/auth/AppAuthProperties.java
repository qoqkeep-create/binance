package com.oovso.auth;

import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.stereotype.Component;

@Component
@ConfigurationProperties(prefix = "app.auth")
public class AppAuthProperties {

    private String bootstrapAccount;

    private String bootstrapPassword;

    private String bootstrapEmail;

    private String bootstrapDisplayName = "Administrator";

    private boolean registrationEnabled = true;

    public String getBootstrapAccount() {
        return bootstrapAccount;
    }

    public void setBootstrapAccount(String bootstrapAccount) {
        this.bootstrapAccount = bootstrapAccount;
    }

    public String getBootstrapPassword() {
        return bootstrapPassword;
    }

    public void setBootstrapPassword(String bootstrapPassword) {
        this.bootstrapPassword = bootstrapPassword;
    }

    public String getBootstrapEmail() {
        return bootstrapEmail;
    }

    public void setBootstrapEmail(String bootstrapEmail) {
        this.bootstrapEmail = bootstrapEmail;
    }

    public String getBootstrapDisplayName() {
        return bootstrapDisplayName;
    }

    public void setBootstrapDisplayName(String bootstrapDisplayName) {
        this.bootstrapDisplayName = bootstrapDisplayName;
    }

    public boolean isRegistrationEnabled() {
        return registrationEnabled;
    }

    public void setRegistrationEnabled(boolean registrationEnabled) {
        this.registrationEnabled = registrationEnabled;
    }
}
