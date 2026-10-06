#!/system/bin/sh
# ============================================================
# 小米14 移动网络优化模块 - v3.2 (硬件能力对齐版)
# 硬件基线: SM8650 (骁龙8 Gen3) / MPSS.DE.5.0-CN / SDR753 + WCN7851
#
# v3.2 变更（全部基于本机实测，详见 capabilities.txt）:
#   1) 删除 7 个「无消费方」的基带属性写入。
#      实测: persist.vendor.radio.{ril_slice_size,5g_nr_rrc_idle_timer,
#      data_con_rtd,foreground_nt_selector,enable_temp_thermal,enable_volte}
#      + ro.vendor.radio.fastdormancy 在本机所有 build.prop、property_contexts、
#      129 个 RIL/QMI 厂商二进制、40 个框架 jar 里均零命中 -> 判定空转。
#      保留 RIL_PROPS=force 供想强行写入的用户。
#   2) 温控不再写 RIL 分片（去掉共用 LAST_SLICE 变量及其覆盖漏洞），
#      只做「观测 + 迟滞判定 + 记录」，可选 THERM_ACTION=defer_recover。
#   3) 队列深度: 动态发现全部 rmnet_data*（v3.1 只覆盖 data0-2，漏掉实际承载
#      的 data3），并保存原值, 卸载时可精确还原。
#   4) MTU: 默认不再强制（MTU_MODE=off）。
#      实测系统按 PDN 协商给 data1/2=1432、data3=1500，v3.1 一律压到 1400
#      既丢吞吐又会被框架复位；MTU_NOMINAL 还与 netfix 的 MSS clamp 重复。
#   5) 新增 NAPI/GRO 批量（gro_flush_timeout / napi_defer_hard_irqs，实测可写，
#      netfix 不碰），默认关闭，供吞吐取向的用户开启。
#   6) 承载识别改为三级回退（实测 InterfaceName 字段已不再输出）。
#   7) 每轮只 dump 一次 dumpsys，缓存复用（v3.1 每轮 ~5MB 文本）。
#   8) SoC 采样新增 PEAK(cpu-*-*-*) 观测字段，温控阈值语义保持不变。
#   9) 与 netfix_allinone 分权: 不碰 TCP/DNS/iptables/RPS/XPS。
# ============================================================

MODDIR=${0%/*}
[ -d "$MODDIR" ] || MODDIR=/data/adb/modules/mi14_net_booster
LOGFILE="$MODDIR/debug.log"
CFGDIR=/data/adb/mi14_net_booster
CFG="$CFGDIR/config"
CAPFILE="$CFGDIR/capabilities.txt"
ORIGDIR="$CFGDIR/orig"
REGCACHE="$CFGDIR/.reg.tmp"
NETFIX="/data/adb/modules/netfix_allinone"
VERSION="v3.2"

# resetprop: ksud 拉起脚本时 PATH 一般已包含它, 这里做兜底
# (本模块的沙箱外验证环境里 PATH 里就没有, 全靠全路径)
RP=$(command -v resetprop 2>/dev/null)
[ -n "$RP" ] || RP=/data/adb/ksu/bin/resetprop
[ -x "$RP" ] || RP=""
rp(){ [ -n "$RP" ] && "$RP" "$@" 2>/dev/null; }

# ---------- 默认值 ----------
AUTO_RECOVER=1
RECOVER_CONFIRM=3
RECOVER_COOLDOWN=900
BOOT_GRACE=180
ALLOW_RESTART=0
LOG_MAX_KB=512
TXQ_ENABLE=1
TXQ_TARGET=500
MTU_MODE=off
MTU_NOMINAL=1400
MTU_CAP=1500
SINR_WEAK=10
NAPI_ENABLE=0
GRO_FLUSH_TIMEOUT=20000
NAPI_DEFER=1
MODEM_WARN=58
MODEM_HOT=65
SOC_WARN=75
SOC_HOT=85
BATTERY_WARN=42
BATTERY_HOT=48
PA_WARN=60
THERM_HYST=8
THERM_ACTION=log
RIL_PROPS=auto

# ---------- 温区分组（本机实际 topology，* 为通配） ----------
THERM_MODEM="mdmss-*"
THERM_RF="sdr* mmw_ific*"
THERM_SOC="cpu_therm cpuss-*"
THERM_PEAK="cpu-*-*-*"
THERM_GPU="gpuss-*"
THERM_BAT="battery"
THERM_PA="pa_therm* pa-therm* mmw_pa*"

# ---------- 日志 ----------
log() {
    if [ -f "$LOGFILE" ]; then
        SZ=$(stat -c%s "$LOGFILE" 2>/dev/null || echo 0)
        [ "$SZ" -gt $((LOG_MAX_KB * 1024)) ] && : > "$LOGFILE"
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOGFILE"
}

# ---------- 配置 ----------
read_cfg() {
    _key=$1; _def=$2; _val=""
    [ -f "$CFG" ] && _val=$(grep -E "^[[:space:]]*$_key[[:space:]]*=" "$CFG" 2>/dev/null | head -1 | cut -d= -f2- | tr -d ' \r')
    case "$_val" in
        ''|*[!0-9]*) echo "$_def" ;;
        *) echo "$_val" ;;
    esac
}
read_cfg_s() {
    _key=$1; _def=$2; _val=""
    [ -f "$CFG" ] && _val=$(grep -E "^[[:space:]]*$_key[[:space:]]*=" "$CFG" 2>/dev/null | head -1 | cut -d= -f2- | tr -d ' \r')
    case "$_val" in ''|*[!a-zA-Z_]*) echo "$_def" ;; *) echo "$_val" ;; esac
}

mkdir -p "$CFGDIR" "$ORIGDIR" 2>/dev/null

write_default_cfg() {
    cat > "$CFG" <<'CFGEOF'
# ============================================================
# 小米14 网络优化模块 配置 v3.2  (改完重启生效)
# 每一项都对应本机实测可写的硬件节点, 详见 capabilities.txt
# ============================================================
# ---- 数据连接恢复 ----
AUTO_RECOVER=1
RECOVER_CONFIRM=3
RECOVER_COOLDOWN=900
BOOT_GRACE=180
ALLOW_RESTART=0
LOG_MAX_KB=512
# ---- 承载层: 发送队列深度 (实测可写; 每接口 31 个 tx 队列) ----
TXQ_ENABLE=1
TXQ_TARGET=500
# ---- 承载层: MTU ----
# off   = 不碰(默认)。尊重系统按 PDN 协商的值(实测 1432/1500)
# clamp = 只把 > MTU_CAP 的聚合默认值(如 9216)夹到 MTU_CAP
# weak  = clamp 之外, 弱信号时把当前承载压到 MTU_NOMINAL
MTU_MODE=off
MTU_NOMINAL=1400
MTU_CAP=1500
# 弱信号判定门限(SINR), 仅 MTU_MODE=weak 时使用
SINR_WEAK=10
# ---- 承载层: NAPI/GRO 批量 (实测可写, netfix 不碰; 吞吐取向, 默认关) ----
NAPI_ENABLE=0
GRO_FLUSH_TIMEOUT=20000
NAPI_DEFER=1
# ---- 温度阈值 (C) ----
MODEM_WARN=58
MODEM_HOT=65
SOC_WARN=75
SOC_HOT=85
BATTERY_WARN=42
BATTERY_HOT=48
PA_WARN=60
# ---- 温控抗抖动 ----
THERM_HYST=8
# log           = 只记录(默认)
# defer_recover = 过热时暂停数据重连动作
THERM_ACTION=log
# ---- 基带/RIL 属性 ----
# auto  = 只写本机验证过有消费方的属性(当前: 无, 即全部跳过)
# force = 强行写入(含未验证项)
# off   = 完全不写
RIL_PROPS=auto
CFGEOF
}

[ -f "$CFG" ] || write_default_cfg
ensure_cfg_keys() {
    _need=0
    # 加固: 旧配置可能没有结尾换行, 直接追加会把两行粘在一起(本机实测踩过)
    if [ -s "$CFG" ] && [ "$(tail -c1 "$CFG" 2>/dev/null | wc -l)" = "0" ]; then
        echo "" >> "$CFG"
    fi
    for kv in "TXQ_ENABLE=1" "TXQ_TARGET=500" "MTU_MODE=off" "MTU_NOMINAL=1400" "MTU_CAP=1500" \
              "SINR_WEAK=10" "NAPI_ENABLE=0" "GRO_FLUSH_TIMEOUT=20000" "NAPI_DEFER=1" \
              "THERM_ACTION=log" "RIL_PROPS=auto"; do
        k=${kv%%=*}
        grep -qE "^[[:space:]]*$k[[:space:]]*=" "$CFG" 2>/dev/null || { echo "$kv" >> "$CFG"; _need=1; }
    done
    [ "$_need" = "1" ] && log "配置已升级到 v3.2（补充新键，原有调参保持不变）"
}
ensure_cfg_keys

AUTO_RECOVER=$(read_cfg AUTO_RECOVER $AUTO_RECOVER)
RECOVER_CONFIRM=$(read_cfg RECOVER_CONFIRM $RECOVER_CONFIRM)
RECOVER_COOLDOWN=$(read_cfg RECOVER_COOLDOWN $RECOVER_COOLDOWN)
BOOT_GRACE=$(read_cfg BOOT_GRACE $BOOT_GRACE)
ALLOW_RESTART=$(read_cfg ALLOW_RESTART $ALLOW_RESTART)
LOG_MAX_KB=$(read_cfg LOG_MAX_KB $LOG_MAX_KB)
TXQ_ENABLE=$(read_cfg TXQ_ENABLE $TXQ_ENABLE)
TXQ_TARGET=$(read_cfg TXQ_TARGET $TXQ_TARGET)
MTU_NOMINAL=$(read_cfg MTU_NOMINAL $MTU_NOMINAL)
MTU_CAP=$(read_cfg MTU_CAP $MTU_CAP)
SINR_WEAK=$(read_cfg SINR_WEAK $SINR_WEAK)
NAPI_ENABLE=$(read_cfg NAPI_ENABLE $NAPI_ENABLE)
GRO_FLUSH_TIMEOUT=$(read_cfg GRO_FLUSH_TIMEOUT $GRO_FLUSH_TIMEOUT)
NAPI_DEFER=$(read_cfg NAPI_DEFER $NAPI_DEFER)
MODEM_WARN=$(read_cfg MODEM_WARN $MODEM_WARN)
MODEM_HOT=$(read_cfg MODEM_HOT $MODEM_HOT)
SOC_WARN=$(read_cfg SOC_WARN $SOC_WARN)
SOC_HOT=$(read_cfg SOC_HOT $SOC_HOT)
BATTERY_WARN=$(read_cfg BATTERY_WARN $BATTERY_WARN)
BATTERY_HOT=$(read_cfg BATTERY_HOT $BATTERY_HOT)
PA_WARN=$(read_cfg PA_WARN $PA_WARN)
THERM_HYST=$(read_cfg THERM_HYST $THERM_HYST)
MTU_MODE=$(read_cfg_s MTU_MODE $MTU_MODE)
THERM_ACTION=$(read_cfg_s THERM_ACTION $THERM_ACTION)
RIL_PROPS=$(read_cfg_s RIL_PROPS $RIL_PROPS)

# ============================================================
# 温度采样引擎（支持通配, 全部走内存索引, 不再每名称 fork grep）
# ============================================================
THERM_INDEX=""
build_therm_index() {
    _idx=""
    for z in /sys/class/thermal/thermal_zone*; do
        [ -r "$z/temp" ] || continue
        _t=$(cat "$z/type" 2>/dev/null)
        [ -z "$_t" ] && continue
        _idx="$_idx$_t|$z
"
    done
    THERM_INDEX="$_idx"
}

# 组内最大值(C)。过滤空/非数字(未接入温区的负值自动排除)
therm_group_max() {
    _pats="$1"
    _max=0
    _found=0
    OLDIFS=$IFS
    IFS='
'
    for _line in $THERM_INDEX; do
        IFS=$OLDIFS
        _t=${_line%%|*}
        _p=${_line##*|}
        _v=$(cat "$_p/temp" 2>/dev/null)
        case "$_v" in ''|*[!0-9]*) continue ;; esac
        for _pat in $_pats; do
            case "$_t" in
                $_pat)
                    if [ "$_v" -gt "$_max" ]; then _max=$_v; _found=1; fi
                    break
                    ;;
            esac
        done
    done
    IFS=$OLDIFS
    [ "$_found" = "1" ] && echo $((_max / 1000))
}

therm_group_count() {
    _pats="$1"; _cnt=0
    OLDIFS=$IFS
    IFS='
'
    for _line in $THERM_INDEX; do
        IFS=$OLDIFS
        _t=${_line%%|*}
        for _pat in $_pats; do
            case "$_t" in $_pat) _cnt=$((_cnt + 1)); break ;; esac
        done
    done
    IFS=$OLDIFS
    echo "$_cnt"
}

sample_temps() {
    echo "MODEM=$(therm_group_max "$THERM_MODEM") RF=$(therm_group_max "$THERM_RF") SOC=$(therm_group_max "$THERM_SOC") PEAK=$(therm_group_max "$THERM_PEAK") GPU=$(therm_group_max "$THERM_GPU") BAT=$(therm_group_max "$THERM_BAT") PA=$(therm_group_max "$THERM_PA")"
}

tfield() { echo "$1" | sed -n "s/.*$2=\([0-9]*\).*/\1/p"; }

# ============================================================
# 承载接口 / 原值存档
# ============================================================
iface_list() {
    for i in /sys/class/net/rmnet_data*; do
        [ -e "$i" ] || continue
        echo "${i##*/}"
    done
}

# 首次触碰前保存原值（已存在则不覆盖 -> 跨重启可精确还原）
orig_save() {
    _f="$ORIGDIR/$1.$2"
    [ -f "$_f" ] && return 0
    _v=$(cat "/sys/class/net/$1/$2" 2>/dev/null)
    case "$_v" in ''|*[!0-9]*) return 1 ;; esac
    echo "$_v" > "$_f" 2>/dev/null
}
orig_get() { cat "$ORIGDIR/$1.$2" 2>/dev/null; }

# 三级回退承载识别（实测 InterfaceName 字段在 Android16 已不再输出）
bearer_detect() {
    _b=$(ip route get 1.1.1.1 2>/dev/null | grep -oE 'dev rmnet_data[0-9]+' | head -1 | sed 's/dev //')
    [ -n "$_b" ] && { echo "$_b"; return; }
    _b=$(grep -oE 'InterfaceName: *rmnet_data[0-9]+' "$REGCACHE" 2>/dev/null | head -1 | sed 's/.*InterfaceName: *//')
    [ -n "$_b" ] && { echo "$_b"; return; }
    for _i in $(iface_list); do
        [ "$(cat /sys/class/net/$_i/operstate 2>/dev/null)" = "up" ] && { echo "$_i"; return; }
    done
}

# ============================================================
# 硬件能力自检 -> $CAPFILE
# ============================================================
CAP_TXQ=0; CAP_MTU=0; CAP_NAPI=0; CAP_DATA=0
probe_caps() {
    {
        echo "============================================================"
        echo " mi14_net_booster $VERSION  硬件能力自检"
        echo " 时间: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "============================================================"
        echo "机型   : $(getprop ro.product.model) / $(getprop ro.product.device) (sku=$(getprop ro.boot.product.vendor.sku))"
        echo "基带   : $(getprop gsm.version.baseband)"
        echo "内核   : $(uname -r)"
        echo "温区索引: $(printf '%s' "$THERM_INDEX" | grep -c .) 个有效温区"
        echo "温区分组: MODEM=$(therm_group_count "$THERM_MODEM") RF=$(therm_group_count "$THERM_RF") SOC=$(therm_group_count "$THERM_SOC") PEAK=$(therm_group_count "$THERM_PEAK") GPU=$(therm_group_count "$THERM_GPU") BAT=$(therm_group_count "$THERM_BAT") PA=$(therm_group_count "$THERM_PA")"
        echo "初始温度: $(sample_temps)"
        echo
        echo "--- 承载层（本模块管辖）---"
        _ifc=0
        for i in $(iface_list); do
            _ifc=$((_ifc + 1))
            echo "  $i: mtu=$(cat /sys/class/net/$i/mtu 2>/dev/null) tx_queue_len=$(cat /sys/class/net/$i/tx_queue_len 2>/dev/null) operstate=$(cat /sys/class/net/$i/operstate 2>/dev/null) 队列数=$(ls /sys/class/net/$i/queues 2>/dev/null | wc -l)"
        done
        echo "  承载接口数量: $_ifc"
        if [ -w /sys/class/net/rmnet_data0/tx_queue_len ]; then CAP_TXQ=1; echo "  tx_queue_len 可写: 是"; else echo "  tx_queue_len 可写: 否"; fi
        if [ -w /sys/class/net/rmnet_data0/mtu ]; then CAP_MTU=1; echo "  mtu 可写: 是"; else echo "  mtu 可写: 否"; fi
        if [ -w /sys/class/net/rmnet_data0/gro_flush_timeout ] && [ -w /sys/class/net/rmnet_data0/napi_defer_hard_irqs ]; then
            CAP_NAPI=1
            echo "  gro_flush_timeout / napi_defer_hard_irqs 可写: 是 (当前 $(cat /sys/class/net/rmnet_data0/gro_flush_timeout)/$(cat /sys/class/net/rmnet_data0/napi_defer_hard_irqs))"
        else
            echo "  gro_flush_timeout / napi_defer_hard_irqs: 不可用"
        fi
        echo "  rps_cpus: 存在(本机 $(cat /sys/class/net/rmnet_data3/queues/rx-0/rps_cpus 2>/dev/null)) -> 归 netfix_allinone 管辖, 本模块不碰"
        echo
        echo "--- 数据面 ---"
        echo "  dumpsys telephony.registry: $(dumpsys telephony.registry >/dev/null 2>&1 && echo 可用 || echo 不可用)"
        if grep -q 'mDataConnectionState=' "$REGCACHE" 2>/dev/null; then
            CAP_DATA=1
            echo "  数据状态字段 mDataConnectionState: 可解析"
        else
            echo "  数据状态字段 mDataConnectionState: 未取到"
        fi
        grep -q 'InterfaceName' "$REGCACHE" 2>/dev/null && echo "  InterfaceName 字段: 有" || echo "  InterfaceName 字段: 无(已启用三级回退识别承载)"
        command -v svc >/dev/null 2>&1 && echo "  svc data: 可用" || echo "  svc data: 不可用"
        echo "  当前承载识别: $(bearer_detect)"
        echo
        echo "--- 基带/RIL 属性（v3.2 起默认不再写）---"
        echo "  结论: 下列属性在本机未找到任何消费方"
        echo "  证据: 所有 build.prop / property_contexts / 129 个 RIL-QMI 厂商二进制"
        echo "        (qcrilNrd, android.hardware.radio*.so, libqcril*, lib*ril*) /"
        echo "        40 个框架 jar 内均零命中（2026-10-06 于本机离线扫描）"
        for p in persist.vendor.radio.ril_slice_size persist.vendor.radio.5g_nr_rrc_idle_timer \
                 persist.vendor.radio.data_con_rtd persist.vendor.radio.foreground_nt_selector \
                 persist.vendor.radio.enable_temp_thermal persist.vendor.radio.enable_volte \
                 ro.vendor.radio.fastdormancy; do
            echo "    $p = $(getprop $p)   [未验证消费方]"
        done
        echo "  当前策略: RIL_PROPS=$RIL_PROPS"
        echo
        echo "--- 不归本模块（分权）---"
        if [ -d "$NETFIX" ] && [ ! -f "$NETFIX/disable" ]; then
            echo "  TCP/DNS/iptables/RPS/XPS -> netfix_allinone（已安装, 已让权）"
        else
            echo "  TCP/DNS/iptables/RPS/XPS -> netfix_allinone（未安装）"
        fi
        echo
        echo "--- 本机可优化项（仅以上述实测为准）---"
        echo "  [x] 发送队列深度 tx_queue_len（$([ "$CAP_TXQ" = 1 ] && echo 可写 || echo 不可用)）"
        echo "  [$([ "$CAP_MTU" = 1 ] && echo x || echo ' ')] MTU（可写; 默认不干预 MTU_MODE=$MTU_MODE）"
        echo "  [$([ "$CAP_NAPI" = 1 ] && echo x || echo ' ')] NAPI/GRO 批量（可写; 默认关 NAPI_ENABLE=$NAPI_ENABLE）"
        echo "  [$([ "$CAP_DATA" = 1 ] && echo x || echo ' ')] 数据面守护（状态判定 + 温和恢复）"
        echo "  [x] 温度观测与迟滞判定（只读; 本机相关温区 $(( $(therm_group_count "$THERM_SOC") + $(therm_group_count "$THERM_MODEM") + $(therm_group_count "$THERM_PEAK") )) 个）"
        echo "  [ ] 基带属性调参 —— 未验证消费方, 默认跳过"
        echo "============================================================"
    } > "$CAPFILE" 2>/dev/null
    log "硬件能力自检已写入 $CAPFILE"
    log "自检结论: 队列=$CAP_TXQ MTU=$CAP_MTU NAPI/GRO=$CAP_NAPI 数据面=$CAP_DATA 基带属性=未验证(默认跳过)"
}

# ============================================================
# 承载层动作
# ============================================================
# 队列深度: 动态覆盖全部 rmnet_data*（含后来才出现的承载接口）
apply_txq() {
    [ "$TXQ_ENABLE" = "1" ] || { log "队列深度调整已关闭(TXQ_ENABLE=0)"; return; }
    _n=0
    for IF in $(iface_list); do
        _p="/sys/class/net/$IF/tx_queue_len"
        [ -w "$_p" ] || continue
        CUR=$(cat "$_p" 2>/dev/null)
        case "$CUR" in ''|*[!0-9]*) continue ;; esac
        [ "$CUR" = "$TXQ_TARGET" ] && continue
        orig_save "$IF" tx_queue_len
        if echo "$TXQ_TARGET" > "$_p" 2>/dev/null; then
            log "$IF 发送队列: ${CUR}->${TXQ_TARGET} (原值 $(orig_get "$IF" tx_queue_len) 已存档)"
            _n=$((_n + 1))
        fi
    done
    [ "$_n" = "0" ] && log "发送队列已是目标值 ${TXQ_TARGET}，无需调整"
}

# MTU: 默认不干预; clamp 只夹聚合默认值; weak 额外在弱信号下调（只降不升）
bearer_mtu_adjust() {
    _if="$1"; _sinr="$2"
    [ -n "$_if" ] || return
    _p="/sys/class/net/$_if/mtu"
    [ -w "$_p" ] || return
    CUR=$(cat "$_p" 2>/dev/null)
    case "$CUR" in ''|*[!0-9]*) return ;; esac
    case "$MTU_MODE" in
        off) return ;;
        clamp|weak)
            _want=""; _reason=""
            if [ "$CUR" -gt "$MTU_CAP" ]; then
                _want="$MTU_CAP"; _reason="聚合默认值 ${CUR} > cap ${MTU_CAP}"
            elif [ "$MTU_MODE" = "weak" ]; then
                case "$_sinr" in
                    ''|*[!0-9-]*) ;;
                    *)
                        if [ "$_sinr" -lt "$SINR_WEAK" ] && [ "$CUR" -gt "$MTU_NOMINAL" ]; then
                            _want="$MTU_NOMINAL"; _reason="弱信号 SINR=${_sinr} < ${SINR_WEAK}"
                        fi ;;
                esac
            fi
            if [ -n "$_want" ]; then
                orig_save "$_if" mtu
                if echo "$_want" > "$_p" 2>/dev/null; then
                    log "[MTU] $_if: ${CUR}->${_want} ($_reason)"
                fi
            fi ;;
    esac
}

# NAPI/GRO 批量: 实测可写, netfix 不碰; 默认关
apply_napi() {
    _if="$1"
    [ -n "$_if" ] || return
    [ -w "/sys/class/net/$_if/gro_flush_timeout" ] || return
    if [ "$NAPI_ENABLE" = "1" ]; then
        orig_save "$_if" gro_flush_timeout
        orig_save "$_if" napi_defer_hard_irqs
        echo "$GRO_FLUSH_TIMEOUT" > "/sys/class/net/$_if/gro_flush_timeout" 2>/dev/null
        echo "$NAPI_DEFER" > "/sys/class/net/$_if/napi_defer_hard_irqs" 2>/dev/null
    fi
}

# v3.1 遗留清理: 旧版写过这 7 个未验证属性, 它们会持久化在属性存储里。
# 本模块不再写它们, 这里做一次性删除(仅在 RIL_PROPS 非 force 时执行)。
legacy_cleanup(){
    _m="$CFGDIR/.legacy_v31_cleaned"
    [ -f "$_m" ] && return 0
    [ "$RIL_PROPS" = "force" ] && { echo "force" > "$_m"; return 0; }
    _n=0
    for P in persist.vendor.radio.ril_slice_size persist.vendor.radio.5g_nr_rrc_idle_timer \
             persist.vendor.radio.data_con_rtd persist.vendor.radio.foreground_nt_selector \
             persist.vendor.radio.enable_temp_thermal persist.vendor.radio.enable_volte \
             ro.vendor.radio.fastdormancy; do
        if [ -n "$(getprop $P)" ]; then
            rp --delete "$P" && _n=$((_n + 1))
        fi
    done
    echo "$(date '+%Y-%m-%d %H:%M:%S') cleaned=$_n" > "$_m" 2>/dev/null
    log "v3.1 遗留基带属性已清理 $_n 项（本版不再写入）"
}

# 只写本机验证过有消费方的 RIL 属性（当前清单为空 -> 全部跳过）
apply_ril_props() {
    case "$RIL_PROPS" in
        off) log "RIL 属性: 已按配置关闭(RIL_PROPS=off)" ;;
        force)
            log "RIL 属性: RIL_PROPS=force，写入未验证项（后果自负）"
            rp persist.vendor.radio.ril_slice_size 131072 2>/dev/null
            rp persist.vendor.radio.enable_temp_thermal 1 2>/dev/null
            rp persist.vendor.radio.enable_volte 1 2>/dev/null
            rp persist.vendor.radio.foreground_nt_selector 1 2>/dev/null
            rp persist.vendor.radio.5g_nr_rrc_idle_timer 10 2>/dev/null
            rp persist.vendor.radio.data_con_rtd 1500 2>/dev/null
            rp ril.deprioritize.sa.slot0 false 2>/dev/null
            log "RIL 属性: force 写入完成" ;;
        *)  log "RIL 属性: auto —— 本机无验证过消费方的属性，全部跳过（详见 capabilities.txt）" ;;
    esac
}

# ============================================================
# 手动能力自检: sh service.sh probe   (只读, 不写入, 不启动守护)
# ============================================================
if [ "$1" = "probe" ]; then
    build_therm_index
    mkdir -p "$CFGDIR" 2>/dev/null
    dumpsys telephony.registry > "$REGCACHE" 2>/dev/null
    probe_caps
    cat "$CAPFILE"
    exit 0
fi

# ============================================================
# 启动
# ============================================================
log ""
log "==================================================="
log "MI14 Net Booster $VERSION 启动 (SM8650/SDR753 硬件适配)"
log "==================================================="
build_therm_index
log "温区索引: $(printf '%s' "$THERM_INDEX" | grep -c .) 个有效温区"

until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 2; done
log "系统启动完成，等待网络栈就绪..."
sleep 30

# ---------- 分权 ----------
TCP_MANAGED_BY_NETFIX=0
if [ -d "$NETFIX" ] && [ ! -f "$NETFIX/disable" ]; then
    log "检测到 netfix_allinone 运行中 -> 交出 TCP/DNS/iptables/RPS/XPS 控制权"
    TCP_MANAGED_BY_NETFIX=1
else
    log "未检测到 netfix -> 按分权约定仍不接管 TCP 层"
fi

# ---------- 能力自检 ----------
dumpsys telephony.registry > "$REGCACHE" 2>/dev/null
probe_caps

# ---------- 承载层 ----------
log "========== 承载层优化（按实测能力）=========="
log "承载接口: $(iface_list | tr '\n' ' ')"
apply_txq
if [ "$MTU_MODE" = "off" ]; then
    log "MTU: 不干预(MTU_MODE=off) —— 尊重系统按 PDN 协商的值"
else
    for IF in $(iface_list); do bearer_mtu_adjust "$IF" ""; done
    log "MTU: 模式=$MTU_MODE (只降不升, 原值存于 $ORIGDIR)"
fi
if [ "$NAPI_ENABLE" = "1" ]; then
    _bd=$(bearer_detect)
    [ -n "$_bd" ] && apply_napi "$_bd"
    log "NAPI/GRO 批量: 已开启 gro_flush_timeout=$GRO_FLUSH_TIMEOUT napi_defer_hard_irqs=$NAPI_DEFER"
else
    log "NAPI/GRO 批量: 关闭(NAPI_ENABLE=0)"
fi
legacy_cleanup
apply_ril_props

log "温控阈值: Modem ${MODEM_WARN}/${MODEM_HOT}C  SoC ${SOC_WARN}/${SOC_HOT}C  电池 ${BATTERY_WARN}/${BATTERY_HOT}C  迟滞 ${THERM_HYST}C"
log "温控动作: $THERM_ACTION    温度自检: $(sample_temps)"

# ---------- 数据状态判定 ----------
get_data_status() {
    _out=$(cat "$REGCACHE" 2>/dev/null)
    [ -z "$_out" ] && _out=$(dumpsys telephony.registry 2>/dev/null)
    if echo "$_out" | grep -qE 'mDataConnectionState=2|mPreciseDataConnectionState=CONNECTED'; then
        echo UP; return
    fi
    if echo "$_out" | grep -qE 'mDataConnectionState=0|mPreciseDataConnectionState=DISCONNECTED'; then
        echo DOWN; return
    fi
    echo UNKNOWN
}

data_switch_allows() {
    [ "$(settings get global mobile_data 2>/dev/null)" = "1" ] && return 0
    [ "$(settings get global mobile_data1 2>/dev/null)" = "1" ] && return 0
    [ "$(settings get global mobile_data2 2>/dev/null)" = "1" ] && return 0
    return 1
}

wifi_enabled() {
    dumpsys wifi 2>/dev/null | grep -qiE 'Wi-Fi is enabled|Current Wi-Fi state: .*ENABLED' && return 0
    return 1
}
wifi_connected() {
    wifi_enabled || return 1
    _out=$(dumpsys wifi 2>/dev/null)
    echo "$_out" | grep -qi 'Wi-Fi is connected' && return 0
    echo "$_out" | grep -q 'Supplicant state: COMPLETED' && return 0
    return 1
}
on_wifi_and_data_off() {
    wifi_connected || return 1
    data_switch_allows && return 1
    return 0
}

try_recover() {
    _bat=$(therm_group_max "$THERM_BAT")
    if [ -n "$_bat" ] && [ "$_bat" -ge "$BATTERY_HOT" ]; then
        log "[恢复] 电池温度 ${_bat}C >= ${BATTERY_HOT}C -> 放弃本次重连(保护电池)"
        return
    fi
    if [ "$THERM_ACTION" = "defer_recover" ] && [ "$THERM_HOT" = "1" ]; then
        log "[恢复] 当前处于过热状态且 THERM_ACTION=defer_recover -> 本次不重连"
        return
    fi
    if [ "$ALLOW_RESTART" = "1" ]; then
        log "[恢复] 执行 svc data restart (用户已允许强制重连)"
        svc data restart 2>/dev/null
    else
        log "[恢复] 执行 svc data enable (温和恢复，不重连 PDN)"
        svc data enable 2>/dev/null
    fi
}

# ============================================================
# 监控循环
# ============================================================
(
    CYCLE=0
    BAD_COUNT=0
    LAST_RECOVER=0
    NOW_S=$(date +%s)
    GRACE_END=$((NOW_S + BOOT_GRACE))
    MOD_STATE="NORMAL"; SOC_STATE="NORMAL"; RF_STATE="NORMAL"; BAT_STATE="NORMAL"
    LAST_WIFI_STATE=""; LAST_DATAOFF=""; LAST_MTU_IF=""
    THERM_HOT=0
    log "监控循环启动: 宽限期 ${BOOT_GRACE}s，之后每 60s 检测"
    log "温控迟滞: ${THERM_HYST}C  MTU: ${MTU_MODE}  NAPI/GRO: ${NAPI_ENABLE}  队列目标: ${TXQ_TARGET}"

    while true; do
        CYCLE=$((CYCLE + 1))
        sleep 60
        NOW_S=$(date +%s)

        # 每轮只取一次 dumpsys 并缓存复用
        dumpsys telephony.registry > "$REGCACHE" 2>/dev/null

        # ---- 温度（只观测 + 迟滞判定）----
        TS=$(sample_temps)
        MODEM_C=$(tfield "$TS" MODEM)
        RF_C=$(tfield "$TS" RF)
        SOC_C=$(tfield "$TS" SOC)
        BAT_C=$(tfield "$TS" BAT)
        PA_C=$(tfield "$TS" PA)
        THERM_HOT=0

        if [ -n "$MODEM_C" ]; then
            _act=""
            case "$MOD_STATE" in
                NORMAL)
                    if [ "$MODEM_C" -ge "$MODEM_HOT" ]; then MOD_STATE="HOT"; _act=1
                    elif [ "$MODEM_C" -ge "$MODEM_WARN" ]; then MOD_STATE="WARN"; _act=1; fi ;;
                WARN)
                    if [ "$MODEM_C" -ge "$MODEM_HOT" ]; then MOD_STATE="HOT"; _act=1
                    elif [ "$MODEM_C" -lt $((MODEM_WARN - THERM_HYST)) ]; then MOD_STATE="NORMAL"; _act=1; fi ;;
                *)
                    if [ "$MODEM_C" -lt $((MODEM_HOT - THERM_HYST)) ]; then
                        if [ "$MODEM_C" -ge "$MODEM_WARN" ]; then MOD_STATE="WARN"; else MOD_STATE="NORMAL"; fi
                        _act=1
                    fi ;;
            esac
            [ -n "$_act" ] && log "[温控] Modem ${MODEM_C}C -> ${MOD_STATE} (阈值 ${MODEM_WARN}/${MODEM_HOT}C)"
        fi

        if [ -n "$SOC_C" ]; then
            _act=""
            case "$SOC_STATE" in
                NORMAL)
                    if [ "$SOC_C" -ge "$SOC_HOT" ]; then SOC_STATE="HOT"; _act=1
                    elif [ "$SOC_C" -ge "$SOC_WARN" ]; then SOC_STATE="WARN"; _act=1; fi ;;
                WARN)
                    if [ "$SOC_C" -ge "$SOC_HOT" ]; then SOC_STATE="HOT"; _act=1
                    elif [ "$SOC_C" -lt $((SOC_WARN - THERM_HYST)) ]; then SOC_STATE="NORMAL"; _act=1; fi ;;
                *)
                    if [ "$SOC_C" -lt $((SOC_HOT - THERM_HYST)) ]; then
                        if [ "$SOC_C" -ge "$SOC_WARN" ]; then SOC_STATE="WARN"; else SOC_STATE="NORMAL"; fi
                        _act=1
                    fi ;;
            esac
            [ -n "$_act" ] && log "[温控] SoC ${SOC_C}C -> ${SOC_STATE} (阈值 ${SOC_WARN}/${SOC_HOT}C)"
        fi

        _rf_max=""
        [ -n "$RF_C" ] && _rf_max="$RF_C"
        if [ -n "$PA_C" ]; then
            if [ -z "$_rf_max" ] || [ "$PA_C" -gt "$_rf_max" ]; then _rf_max="$PA_C"; fi
        fi
        if [ -n "$_rf_max" ]; then
            _act=""
            case "$RF_STATE" in
                NORMAL) [ "$_rf_max" -ge "$PA_WARN" ] && { RF_STATE="HOT"; _act=1; } ;;
                *) [ "$_rf_max" -lt $((PA_WARN - THERM_HYST)) ] && { RF_STATE="NORMAL"; _act=1; } ;;
            esac
            [ -n "$_act" ] && log "[温控] 射频区 RF=${RF_C}C/PA=${PA_C}C -> ${RF_STATE} (阈值${PA_WARN}C)"
        fi

        if [ -n "$BAT_C" ]; then
            _act=""
            case "$BAT_STATE" in
                NORMAL)
                    if [ "$BAT_C" -ge "$BATTERY_HOT" ]; then BAT_STATE="HOT"; _act=1
                    elif [ "$BAT_C" -ge "$BATTERY_WARN" ]; then BAT_STATE="WARN"; _act=1; fi ;;
                WARN)
                    if [ "$BAT_C" -ge "$BATTERY_HOT" ]; then BAT_STATE="HOT"; _act=1
                    elif [ "$BAT_C" -lt $((BATTERY_WARN - THERM_HYST)) ]; then BAT_STATE="NORMAL"; _act=1; fi ;;
                *)
                    if [ "$BAT_C" -lt $((BATTERY_HOT - THERM_HYST)) ]; then
                        if [ "$BAT_C" -ge "$BATTERY_WARN" ]; then BAT_STATE="WARN"; else BAT_STATE="NORMAL"; fi
                        _act=1
                    fi ;;
            esac
            [ -n "$_act" ] && log "[温控] 电池 ${BAT_C}C -> ${BAT_STATE} (阈值 ${BATTERY_WARN}/${BATTERY_HOT}C)"
        fi

        case "$MOD_STATE$SOC_STATE$BAT_STATE" in
            *HOT*) THERM_HOT=1 ;;
        esac

        # ---- 信号 ----
        RSRP=$(grep -oE 'ssRsrp = -?[0-9]+' "$REGCACHE" 2>/dev/null | head -1 | awk '{print $3}')
        SINR=$(grep -oE 'ssSinr = -?[0-9]+' "$REGCACHE" 2>/dev/null | head -1 | awk '{print $3}')

        # ---- 承载识别 + 队列/MTU/NAPI ----
        _bearer=$(bearer_detect)
        if [ -n "$_bearer" ]; then
            _cur=$(cat "/sys/class/net/$_bearer/tx_queue_len" 2>/dev/null)
            if [ "$TXQ_ENABLE" = "1" ] && [ -n "$_cur" ] && [ "$_cur" != "$TXQ_TARGET" ]; then
                orig_save "$_bearer" tx_queue_len
                if echo "$TXQ_TARGET" > "/sys/class/net/$_bearer/tx_queue_len" 2>/dev/null; then
                    log "[队列] 承载 $_bearer: ${_cur}->${TXQ_TARGET} (新出现的承载, 原值 $(orig_get "$_bearer" tx_queue_len) 已存档)"
                fi
            fi
            [ "$MTU_MODE" != "off" ] && bearer_mtu_adjust "$_bearer" "$SINR"
            [ "$NAPI_ENABLE" = "1" ] && apply_napi "$_bearer"
        fi

        # ---- 数据连接恢复 ----
        if [ "$NOW_S" -lt "$GRACE_END" ]; then
            BAD_COUNT=0
        else
            ST=$(get_data_status)
            if [ "$ST" = "UP" ]; then
                [ "$BAD_COUNT" -gt 0 ] && log "[数据] 恢复正常 (累计异常 ${BAD_COUNT} 次 -> 已连接)"
                BAD_COUNT=0
                LAST_DATAOFF=""
            elif [ "$ST" = "UNKNOWN" ]; then
                BAD_COUNT=0
            else
                if on_wifi_and_data_off; then
                    if [ "$LAST_WIFI_STATE" != "SAVING" ]; then
                        log "[数据] Wi-Fi 已连接 + 移动数据关闭 -> 正常省流状态，不计异常"
                        LAST_WIFI_STATE="SAVING"
                    fi
                    BAD_COUNT=0
                elif ! data_switch_allows; then
                    # 顺序修正: 先判定「用户主动关的数据」, 不再先记异常再撤销
                    if [ "$LAST_WIFI_STATE" != "" ]; then
                        log "[数据] Wi-Fi 省流状态结束 -> 恢复正常监控"
                        LAST_WIFI_STATE=""
                    fi
                    if [ "$LAST_DATAOFF" != "1" ]; then
                        log "[数据] 系统数据开关为关闭(手动关闭/流量超限) -> 保持关闭，不干预"
                        LAST_DATAOFF="1"
                    fi
                    BAD_COUNT=0
                else
                    LAST_DATAOFF=""
                    if [ "$LAST_WIFI_STATE" != "" ]; then
                        log "[数据] Wi-Fi 省流状态结束 -> 恢复正常监控"
                        LAST_WIFI_STATE=""
                    fi
                    BAD_COUNT=$((BAD_COUNT + 1))
                    log "[数据] 状态=DOWN 连续第 ${BAD_COUNT}/${RECOVER_CONFIRM} 次（数据开关已开）"
                    if [ "$AUTO_RECOVER" != "1" ]; then
                        [ "$BAD_COUNT" = "1" ] && log "[数据] AUTO_RECOVER=0 -> 不做任何干预"
                    elif [ "$BAD_COUNT" -ge "$RECOVER_CONFIRM" ]; then
                        if [ $((NOW_S - LAST_RECOVER)) -ge "$RECOVER_COOLDOWN" ]; then
                            log "[数据] 持续异常且允许恢复 -> 尝试恢复"
                            try_recover
                            LAST_RECOVER=$NOW_S
                            BAD_COUNT=0
                        else
                            log "[数据] 冷却中(剩 $((RECOVER_COOLDOWN - (NOW_S - LAST_RECOVER)))s) -> 暂不重试"
                            BAD_COUNT=0
                        fi
                    fi
                fi
            fi
        fi

        # ---- 摘要（每 10 轮）----
        if [ $((CYCLE % 10)) -eq 0 ]; then
            PEAK_C=$(tfield "$TS" PEAK)
            log "[摘要] 负载=$(awk '{print $1}' /proc/loadavg) T(${TS}) 数据=$(get_data_status) 开关=$(settings get global mobile_data 2>/dev/null) 承载=${_bearer:-无} RSRP=${RSRP:-?} SINR=${SINR:-?}${PEAK_C:+ PEAK=${PEAK_C}C}"
        fi
    done
) &

log "==================================================="
log "MI14 Net Booster $VERSION 启动完成"
log "TCP/RPS/XPS 管理: netfix_allinone(已让权)"
log "本模块管辖: 承载层(队列深度/可选MTU/可选NAPI) + 数据面守护 + 温度观测"
log "基带属性: 未验证消费方, 默认跳过（RIL_PROPS=$RIL_PROPS）"
log "配置文件: $CFG"
log "能力报告: $CAPFILE"
