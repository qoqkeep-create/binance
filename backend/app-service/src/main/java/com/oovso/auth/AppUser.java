package com.oovso.auth;

import com.baomidou.mybatisplus.annotation.IdType;
import com.baomidou.mybatisplus.annotation.TableId;
import com.baomidou.mybatisplus.annotation.TableName;
import java.time.LocalDateTime;
import lombok.Data;

@Data
@TableName("app_user")
public class AppUser {

    @TableId(type = IdType.INPUT)
    private String id;

    private LocalDateTime createTime;

    private LocalDateTime updateTime;

    private Integer deleteState;

    private String account;

    private String email;

    private String displayName;

    private String passwordHash;

    private String passwordSalt;

    private Integer enabledState;
}
