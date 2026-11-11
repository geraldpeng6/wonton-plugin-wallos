# scripts/smoke.sh 的一项一项探测，跟着插件走。没写的项会 FAIL 并给出写法，不会默认放行。
# shellcheck shell=bash disable=SC2034
#
# 页面：web_assert 从标准输入读页面，命中的确是应用的真实页面时返回 0。
# 身份：identity_check 用应用自己的"当前用户"接口断言认出的是用户管理员。
#       dweb / web_get 是带用户会话的请求助手；SSO 登录跳转用 dweb <路径> --sso
#       （从清单 webui.path 的入口出发，跟完核心登录页的 JS 自动表单和应用回调）。
# 工具：本插件没有 MCP（上游只有 REST API），清单不写 mcp，套件按 N/A 处理。
# 通知：extra_check 由 e2e 冒烟跑：建一条明天到期、提前 1 天提醒的订阅，手动触发上游的
#       提醒 cron，等提醒信投进主人的 Wonton 私聊。
# 数据：data_write/data_check 用应用自己的 REST API（api_key 认证，key 从 profile 页取）。

wallos_origin() { # 入口可能带路径（/wonton-login.php），拼 API 前取 origin
  local u="${SMOKE_WEB_URL%%\?*}" rest="${SMOKE_WEB_URL#*://}"
  printf '%s://%s' "${u%%://*}" "${rest%%/*}"
}

# 应用会话：先补核心会话（vikunja 同款：主流程可能还没登核心），再走入口。
# 入口 wonton-login.php → 核心授权（带核心会话一路 302）→ 应用回调建会话。
# 不用 dweb --sso：套件的表单识别会把 Wallos 页面里的 POST 表单（如加订阅）当成 SSO 表单去提交。
wallos_session() {
  [[ -n "${SMOKE_JAR:-}" && -n "${SMOKE_BASE:-}" && -n "${SMOKE_TOKEN:-}" && -n "${SMOKE_WEB_URL:-}" ]] ||
    { echo "缺冒烟变量：需要 SMOKE_JAR/SMOKE_BASE/SMOKE_TOKEN/SMOKE_WEB_URL" >&2; return 1; }
  curl -sS --noproxy '*' -o /dev/null -b "$SMOKE_JAR" -c "$SMOKE_JAR" \
    --data-urlencode "token=$SMOKE_TOKEN" "$SMOKE_BASE/_wonton/login" ||
    { echo "主人令牌登不进核心" >&2; return 1; }
  curl -sS --noproxy '*' -o /dev/null -L -b "$SMOKE_JAR" -c "$SMOKE_JAR" \
    -H 'Accept: text/html' "$SMOKE_WEB_URL" ||
    { echo "走不通应用的 SSO 登录链（$SMOKE_WEB_URL）" >&2; return 1; }
}

# api_key 在 profile 页明文展示（input#apikey）。没有应用会话时会被重定向到登录页。
wallos_api_key() {
  local page key
  page="$(dweb /profile.php -L)" || { echo "读不到 profile 页：$page" >&2; return 1; }
  key="$(grep -oP 'id="apikey"[^>]*value="\K[^"]+' <<<"$page" | head -1)"
  [[ -n "$key" ]] || { echo "profile 页里没有 api_key（没登录？）" >&2; return 1; }
  printf '%s' "$key"
}

web_assert() { grep -qi 'wallos'; }   # 应用真实页面（登录页和登录后的页面都带）

identity_check() {
  local key me
  wallos_session || return 1
  key="$(wallos_api_key)" || return 1
  # 应用自己的"当前用户"接口：按 api_key 认出调用者。
  me="$(curl -sS --noproxy '*' --fail-with-body -b "$SMOKE_JAR" \
    "$(wallos_origin)/api/users/get_user.php?api_key=$key")" ||
    { echo "get_user 接口失败：$me"; return 1; }
  jq -e --arg u "$SMOKE_OWNER" '.success == true and .user.username == $u' <<<"$me" >/dev/null ||
    { echo "当前用户不是 $SMOKE_OWNER：$(head -c 200 <<<"$me")"; return 1; }
}

# 数据：一条真实用户数据——用 REST API 建订阅，名字带随机标记，升级/重装后按 id 读回。
# SMOKE_STATE 在套件里是状态目录（e2e 传的是标记文件本身），标记放对应路径。
wallos_marker_file() {
  if [[ -d "${SMOKE_STATE:-}" ]]; then printf '%s' "$SMOKE_STATE/wallos-marker"; else printf '%s' "${SMOKE_STATE:-}"; fi
}

wallos_add_subscription() { # <名字> <next_payment YYYY-MM-DD>：输出订阅 id
  local key out id
  key="$(wallos_api_key)" || return 1
  out="$(curl -sS --noproxy '*' --fail-with-body -b "$SMOKE_JAR" -X POST \
    "$(wallos_origin)/api/subscriptions/set_subscriptions.php" \
    --data-urlencode "api_key=$key" \
    --data-urlencode "action=add" \
    --data-urlencode "name=$1" \
    --data-urlencode "price=9.9" \
    --data-urlencode "currency_id=1" \
    --data-urlencode "cycle=3" \
    --data-urlencode "frequency=1" \
    --data-urlencode "next_payment=$2" \
    --data-urlencode "notify=1" \
    --data-urlencode "notify_days_before=1")" ||
    { echo "建订阅失败：$out"; return 1; }
  id="$(jq -r '.subscriptionId // empty' <<<"$out")"
  [[ -n "$id" ]] || { echo "建订阅没回 id：$(head -c 200 <<<"$out")"; return 1; }
  printf '%s' "$id"
}

wallos_date() { # <+N days>：日期按应用的时区算（开发栈和宿主时区可能不同，到期判断是精确天数差）
  local container
  container="$(wallos_container)"
  [[ -n "$container" ]] || { echo "找不到 wallos 服务容器" >&2; return 1; }
  docker exec "$container" php -r "echo date('Y-m-d', strtotime('$1'));"
}

data_write() {
  local marker id marker_file
  wallos_session || return 1
  marker="保数据-$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"
  id="$(wallos_add_subscription "$marker" "$(wallos_date '+7 days')")" || return 1
  marker_file="$(wallos_marker_file)"
  jq -nc --arg m "$marker" --arg i "$id" '{marker:$m,id:$i}' >"$marker_file" ||
    { echo "标记写不进 $marker_file" >&2; return 1; }
}

data_check() {
  local marker_file marker id seen
  wallos_session || return 1
  marker_file="$(wallos_marker_file)"
  marker="$(jq -r .marker "$marker_file" 2>/dev/null)" ||
    { echo "读不到标记（data_write 没跑过？）" >&2; return 1; }
  id="$(jq -r .id "$marker_file")"
  seen="$(curl -sS --noproxy '*' -b "$SMOKE_JAR" \
    "$(wallos_origin)/api/subscriptions/get_subscriptions.php?api_key=$(wallos_api_key)")" ||
    { echo "订阅列表读不到：$seen"; return 1; }
  jq -e --arg i "$id" --arg m "$marker" \
    '.success == true and ([.subscriptions[] | select(.id == ($i | tonumber) and .name == $m)] | length == 1)' \
    <<<"$seen" >/dev/null ||
    { echo "重装后读不回标记订阅（期待 id=$id 名字=$marker）：$(echo "$seen" | jq -c '[.subscriptions[] | {id, name}]' 2>/dev/null | head -c 300)"; return 1; }
}

# ---------- 通知（notify）：真触发一次提醒，核对核心投进私聊（extra_check 由 e2e 冒烟跑） ----------

wallos_container() { # 按核心打的标签找本实例的 wallos 服务容器，插件 smoke 和 e2e 都成立
  local inst="${SMOKE_INSTANCE:-}" args=(--filter "label=wonton.plugin=${SMOKE_PLUGIN_ID:-app.wallos.wallos}" --filter "label=wonton.service=wallos")
  if [[ -z "$inst" && -n "${SMOKE_BASE:-}" ]]; then
    inst="${SMOKE_BASE#http://}"; inst="${inst%%.*}"
  fi
  [[ -z "$inst" ]] || args+=(--filter "label=wonton.instance=${inst//-/}")
  docker ps --format '{{.Names}}' "${args[@]}" | head -1
}

extra_check() { # 提醒专项：建一条明天到期、提前 1 天提醒的订阅，手动跑提醒 cron，
                # 等核心把提醒信投进主人的 Wonton 私聊
  local marker id wait_pid container
  [[ -n "${SMOKE_OWNER:-}" ]] || { echo "缺冒烟变量：SMOKE_OWNER" >&2; return 1; }
  wallos_session || return 1
  container="$(wallos_container)"
  [[ -n "$container" ]] || { echo "找不到 wallos 服务容器" >&2; return 1; }
  marker="提醒-$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"
  # 先挂等待再触发：cron 亚秒内发出、核心亚秒取走，等晚了就错过。
  probes_owner_room_wait 150 "$marker" & wait_pid=$!
  id="$(wallos_add_subscription "$marker" "$(wallos_date '+1 day')")" || { kill "$wait_pid" 2>/dev/null; return 1; }
  echo "建了订阅 $id（$marker，明天到期，提前 1 天提醒），手动触发提醒 cron"
  if ! docker exec "$container" php /var/www/html/endpoints/cronjobs/sendnotifications.php >>"$PROBES_LOG" 2>&1; then
    kill "$wait_pid" 2>/dev/null
    echo "提醒 cron 跑失败，见 $PROBES_LOG"
    return 1
  fi
  if wait "$wait_pid"; then
    echo "提醒信已投进主人的 Wonton 私聊"
  else
    echo "150 秒内没看到提醒信投进主人的私聊（cron 没发或邮件通道没配好，见 $PROBES_LOG）"
    return 1
  fi
}
