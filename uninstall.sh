#!/system/bin/sh
# ============================================================
# mi14_net_booster v3.2 卸载清理
# 只还原本模块真正动过的节点; 未动过的一律不碰
# ============================================================
MODDIR=${0%/*}
[ -d "$MODDIR" ] || MODDIR=/data/adb/modules/mi14_net_booster
ORIGDIR=/data/adb/mi14_net_booster/orig

# ---------- 1. 清掉历史版本(v3.0/v3.1)写入的基带属性 ----------
# v3.2 自身不再写这些; 这里是为了从旧版升级上来的用户能清干净
for P in \
    persist.vendor.radio.ril_slice_size \
    persist.vendor.radio.5g_nr_rrc_idle_timer \
    persist.vendor.radio.data_con_rtd \
    persist.vendor.radio.foreground_nt_selector \
    persist.vendor.radio.enable_temp_thermal \
    persist.vendor.radio.enable_volte \
    persist.vendor.radio.fastdormancy \
    ril.deprioritize.sa.slot0 \
    ril.deprioritize.sa.slot1
do
    resetprop --delete "$P" 2>/dev/null
done

# ---------- 2. 按存档精确还原承载层节点 ----------
restore_knob() {
    _if="$1"; _k="$2"
    _f="$ORIGDIR/$_if.$_k"
    [ -f "$_f" ] || return 0
    _v=$(cat "$_f" 2>/dev/null)
    case "$_v" in ''|*[!0-9]*) return 0 ;; esac
    _t="/sys/class/net/$_if/$_k"
    [ -w "$_t" ] || return 0
    _cur=$(cat "$_t" 2>/dev/null)
    [ "$_cur" = "$_v" ] && return 0
    if echo "$_v" > "$_t" 2>/dev/null; then
        echo "  还原 $_if/$_k: ${_cur}->${_v}"
    fi
}

if [ -d "$ORIGDIR" ]; then
    for f in "$ORIGDIR"/*; do
        [ -f "$f" ] || continue
        n=$(basename "$f")
        _if=${n%.*}
        _k=${n##*.}
        restore_knob "$_if" "$_k"
    done
    echo "mi14_net_booster: 承载层节点已按存档还原"
else
    echo "mi14_net_booster: 无存档(本模块未改过承载层节点)"
fi

echo "mi14_net_booster: 卸载清理完成"
echo "注意: TCP/RPS/XPS 从未由本模块接管(netfix_allinone 管辖), 未做改动"
echo "如需彻底清除用户配置: rm -rf /data/adb/mi14_net_booster"
: > "$MODDIR/debug.log" 2>/dev/null
