<?php

// 一次性服务：把到期提醒的邮件通道写进 Wallos 的用户配置表。
// 上游把 SMTP 连接参数存在每用户的 email_notifications 表、提醒天数存在
// notification_settings 表（sendnotifications.php 按这两张表发信），都只能在
// 登录后的网页里填，没有环境变量。装好时还没有用户，先写 user_id=1：
// OIDC 自动建号（OIDC_AUTO_CREATE_USER=1）创建的第一个用户就是 id 1（管理员）。
//
// 幂等：每次创建容器都会重跑。已存在的行只刷新跟着核心走的管道字段
// （SMTP 地址/端口/加密/发件人），用户自己的开关和提醒天数保留。

$dbFile = '/var/www/html/db/wallos.db';

if (!is_file($dbFile)) {
    fwrite(STDERR, "wallos.db 不存在（应用还没初始化）\n");
    exit(42);
}

$db = new SQLite3($dbFile, SQLITE3_OPEN_READWRITE);
if (!$db) {
    fwrite(STDERR, "打不开 $dbFile\n");
    exit(42);
}
$db->busyTimeout(5000);

// 表由迁移建出（000016、000020、000026），主服务健康检查要过 admin 表查询，
// 能过健康检查说明迁移已跑完；表不在属于异常，如实失败。
foreach (['email_notifications', 'notification_settings'] as $table) {
    $exists = $db->querySingle("SELECT name FROM sqlite_master WHERE type = 'table' AND name = '$table'");
    if (!$exists) {
        fwrite(STDERR, "缺表 $table（应用迁移没跑完？）\n");
        exit(1);
    }
}

$smtpHost = getenv('WONTON_SMTP_HOST');
$smtpPort = getenv('WONTON_SMTP_PORT');
$fromEmail = getenv('WONTON_MAIL_FROM');
$oidcIssuer = getenv('WONTON_OIDC_ISSUER');
if ($smtpHost === false || $smtpPort === false || $fromEmail === false || $smtpHost === '') {
    fwrite(STDERR, "缺 WONTON_SMTP_HOST / WONTON_SMTP_PORT / WONTON_MAIL_FROM 注入\n");
    exit(1);
}

// 上游对 OIDC 的 token/userinfo 端点和 SMTP 主机做私网拦截，私网主机要在 admin 表的
// allowlist 里（validate_oidc_endpoint_url / validate_smtp_host）。核心的 IdP 和内部 SMTP
// 都是私网别名；宿主机名从注入值剥出 scheme（插值不支持，见 compose 注释），带端口按
// host:port 匹配。和 SMTP 管道字段一样跟着核心走，每次按注入值刷新。
if ($oidcIssuer === false || $oidcIssuer === '') {
    fwrite(STDERR, "缺 WONTON_OIDC_ISSUER 注入\n");
    exit(1);
}
$allowlist = preg_replace('#^[a-z][a-z0-9+.-]*://#i', '', rtrim(trim($oidcIssuer), '/')) . ',' . $smtpHost;
$stmt = $db->prepare("UPDATE admin SET local_webhook_notifications_allowlist = :list");
$stmt->bindValue(':list', $allowlist, SQLITE3_TEXT);
if (!$stmt->execute()) {
    fwrite(STDERR, "刷新 SSRF allowlist 失败\n");
    exit(1);
}
echo "SSRF allowlist 已按核心注入值刷新：$allowlist\n";

// 核心的内部 SMTP 不加密（不宣告 STARTTLS），不用账号密码。
$stmt = $db->prepare('SELECT user_id FROM email_notifications WHERE user_id = 1');
$row = $stmt->execute()->fetchArray(SQLITE3_ASSOC);
if ($row === false) {
    $stmt = $db->prepare("INSERT INTO email_notifications
        (enabled, smtp_address, smtp_port, encryption, from_email, user_id)
        VALUES (1, :host, :port, 'none', :from, 1)");
    $stmt->bindValue(':host', $smtpHost, SQLITE3_TEXT);
    $stmt->bindValue(':port', (int) $smtpPort, SQLITE3_INTEGER);
    $stmt->bindValue(':from', $fromEmail, SQLITE3_TEXT);
    if (!$stmt->execute()) {
        fwrite(STDERR, "写 email_notifications 失败\n");
        exit(1);
    }
    echo "邮件提醒通道已配置（user_id=1）\n";
} else {
    $stmt = $db->prepare("UPDATE email_notifications
        SET smtp_address = :host, smtp_port = :port, encryption = 'none', from_email = :from
        WHERE user_id = 1");
    $stmt->bindValue(':host', $smtpHost, SQLITE3_TEXT);
    $stmt->bindValue(':port', (int) $smtpPort, SQLITE3_INTEGER);
    $stmt->bindValue(':from', $fromEmail, SQLITE3_TEXT);
    if (!$stmt->execute()) {
        fwrite(STDERR, "更新 email_notifications 失败\n");
        exit(1);
    }
    echo "邮件提醒通道已按核心注入值刷新（用户自己的开关和设置保留）\n";
}

// 到期前 1 天提醒（订阅也可以用自己的 notify_days_before 覆盖这个默认值）。
// querySingle 空结果返回 NULL，不是 false。
$hasSettings = $db->querySingle('SELECT user_id FROM notification_settings WHERE user_id = 1');
if ($hasSettings === null) {
    if (!$db->exec('INSERT INTO notification_settings (days, user_id) VALUES (1, 1)')) {
        fwrite(STDERR, "写 notification_settings 失败\n");
        exit(1);
    }
    echo "默认提醒时间已配置：到期前 1 天\n";
}

$db->close();
