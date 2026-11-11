<?php

// 云吞网页入口（清单 webui.path 指向这里）。直接种下 OIDC state 后跳核心的身份
// 提供方：上游 login.php 在没有用户时会先 302 到注册页，有用户时也要人再点一次
// 「使用 Wonton 登录」按钮；这条入口让打开网页就直接进云吞登录、落进应用。
// 配置解析与会话写法和 login.php 的 OIDC 分支同一条代码路径（includes/oidc_settings.php）。

require_once 'includes/connect.php';
require_once 'includes/oidc_settings.php';

$oidcConfiguration = wallos_get_effective_oidc_configuration($db);
if ($oidcConfiguration['enabled'] !== 1 || !$oidcConfiguration['is_configured']) {
    // 失败即停：OIDC 没配好就如实报错，不回退到本地登录页。
    http_response_code(500);
    header('Content-Type: text/plain; charset=utf-8');
    echo "Wonton SSO is not configured: " . implode(' ', $oidcConfiguration['notes']);
    exit;
}
$oidcSettings = $oidcConfiguration['settings'];

$secondsInMonth = 30 * 24 * 60 * 60;
if (session_status() === PHP_SESSION_NONE) {
    session_set_cookie_params([
        'lifetime' => $secondsInMonth,
        'httponly' => true,
        'samesite' => 'Lax',
    ]);
    session_start();
}

// 已登录的直接进应用，不用再走一遍授权。
if (($_SESSION['loggedin'] ?? false) === true) {
    $db->close();
    header('Location: ./');
    exit;
}

$state = bin2hex(random_bytes(16));
$_SESSION['oidc_state'] = $state;

$params = http_build_query([
    'response_type' => 'code',
    'client_id' => $oidcSettings['client_id'],
    'redirect_uri' => $oidcSettings['redirect_url'],
    'scope' => $oidcSettings['scopes'],
    'state' => $state,
]);

$db->close();
header('Location: ' . rtrim($oidcSettings['authorization_url'], '?') . '?' . $params);
