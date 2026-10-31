package com.oovso.web;

import cn.dev33.satoken.exception.NotLoginException;
import cn.dev33.satoken.exception.NotPermissionException;
import cn.dev33.satoken.exception.NotRoleException;
import cn.dev33.satoken.exception.SaTokenException;
import com.oovso.auth.AccountAlreadyExistsException;
import com.oovso.auth.InvalidCredentialsException;
import com.oovso.auth.RegistrationDisabledException;
import com.oovso.auth.SessionInvalidException;
import com.oovso.external.ExternalMessageApiException;
import com.oovso.reference.ReferenceTradeNotificationApiException;
import com.oovso.strategy.StrategySignalApiException;
import com.oovso.trading.TradingApiException;
import java.util.Optional;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.http.converter.HttpMessageNotReadableException;
import org.springframework.web.HttpRequestMethodNotSupportedException;
import org.springframework.web.bind.MethodArgumentNotValidException;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;
import org.springframework.web.method.annotation.HandlerMethodValidationException;
import org.springframework.web.servlet.resource.NoResourceFoundException;

@RestControllerAdvice
public class GlobalApiExceptionHandler {

    private static final Logger log = LoggerFactory.getLogger(GlobalApiExceptionHandler.class);

    @ExceptionHandler(InvalidCredentialsException.class)
    public ResponseEntity<ApiResponse<Void>> handleInvalidCredentials() {
        return response(HttpStatus.UNAUTHORIZED, "账号或密码错误");
    }

    @ExceptionHandler(AccountAlreadyExistsException.class)
    public ResponseEntity<ApiResponse<Void>> handleAccountAlreadyExists() {
        return response(HttpStatus.CONFLICT, "账号已存在");
    }

    @ExceptionHandler(RegistrationDisabledException.class)
    public ResponseEntity<ApiResponse<Void>> handleRegistrationDisabled() {
        return response(HttpStatus.FORBIDDEN, "注册已关闭");
    }

    @ExceptionHandler(NotLoginException.class)
    public ResponseEntity<ApiResponse<Void>> handleNotLogin() {
        return response(HttpStatus.UNAUTHORIZED, "登录状态已失效，请重新登录");
    }

    @ExceptionHandler(SessionInvalidException.class)
    public ResponseEntity<ApiResponse<Void>> handleInvalidSession() {
        return response(HttpStatus.UNAUTHORIZED, "当前账号已不可用，请重新登录");
    }

    @ExceptionHandler({NotPermissionException.class, NotRoleException.class})
    public ResponseEntity<ApiResponse<Void>> handleForbidden() {
        return response(HttpStatus.FORBIDDEN, "当前账号没有执行此操作的权限");
    }

    @ExceptionHandler(MethodArgumentNotValidException.class)
    public ResponseEntity<ApiResponse<Void>> handleValidation(
            MethodArgumentNotValidException exception
    ) {
        String message = Optional.ofNullable(exception.getBindingResult().getFieldError())
                .map(error -> error.getDefaultMessage())
                .orElse("请求参数不正确");
        return response(HttpStatus.BAD_REQUEST, message);
    }

    @ExceptionHandler(HandlerMethodValidationException.class)
    public ResponseEntity<ApiResponse<Void>> handleMethodValidation() {
        return response(HttpStatus.BAD_REQUEST, "请求参数不正确");
    }

    @ExceptionHandler(HttpMessageNotReadableException.class)
    public ResponseEntity<ApiResponse<Void>> handleUnreadableBody() {
        return response(HttpStatus.BAD_REQUEST, "请求内容无法解析");
    }

    @ExceptionHandler(HttpRequestMethodNotSupportedException.class)
    public ResponseEntity<ApiResponse<Void>> handleMethodNotSupported(
            HttpRequestMethodNotSupportedException exception
    ) {
        return response(HttpStatus.METHOD_NOT_ALLOWED, "请求方法不支持");
    }

    @ExceptionHandler(NoResourceFoundException.class)
    public ResponseEntity<ApiResponse<Void>> handleNoResource(
            NoResourceFoundException exception
    ) {
        return response(HttpStatus.NOT_FOUND, "请求地址不存在");
    }

    @ExceptionHandler(SaTokenException.class)
    public ResponseEntity<ApiResponse<Void>> handleSaToken(SaTokenException exception) {
        log.warn("Sa-Token rejected request: {}", exception.getMessage());
        return response(HttpStatus.UNAUTHORIZED, "身份认证失败，请重新登录");
    }

    @ExceptionHandler(TradingApiException.class)
    public ResponseEntity<ApiResponse<Void>> handleTradingApi(
            TradingApiException exception
    ) {
        return response(exception.status(), exception.getMessage());
    }

    @ExceptionHandler(StrategySignalApiException.class)
    public ResponseEntity<ApiResponse<Void>> handleStrategySignalApi(
            StrategySignalApiException exception
    ) {
        return response(exception.status(), exception.getMessage());
    }

    @ExceptionHandler(ExternalMessageApiException.class)
    public ResponseEntity<ApiResponse<Void>> handleExternalMessageApi(
            ExternalMessageApiException exception
    ) {
        return response(exception.status(), exception.getMessage());
    }

    @ExceptionHandler(ReferenceTradeNotificationApiException.class)
    public ResponseEntity<ApiResponse<Void>> handleReferenceNotificationApi(
            ReferenceTradeNotificationApiException exception
    ) {
        return response(exception.status(), exception.getMessage());
    }

    @ExceptionHandler(Exception.class)
    public ResponseEntity<ApiResponse<Void>> handleUnexpected(Exception exception) {
        log.error("Unhandled API exception", exception);
        return response(HttpStatus.INTERNAL_SERVER_ERROR, "服务器处理失败，请稍后重试");
    }

    private ResponseEntity<ApiResponse<Void>> response(
            HttpStatus status,
            String message
    ) {
        return ResponseEntity.status(status)
                .body(ApiResponse.error(status.value(), message));
    }
}
