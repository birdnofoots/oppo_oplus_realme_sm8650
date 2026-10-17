#!/system/bin/sh
# 99-bbr.sh —— 开机全局启用 BBR（+ fq 队列算法）
#
# 安装：/data/adb/service.d/99-bbr.sh，权限 755
# 日志：/data/local/tmp/bbr.log
#
# 说明：
#   1) 必须在【Android 宿主】执行；容器里的 sysctl 只管容器自己的 netns
#   2) 需要内核编入 CONFIG_TCP_CONG_BBR=y
#   3) 先设 default_qdisc=fq，之后新建的接口会自动套 fq；
#      已存在的接口再单独 replace 一次即可，无需反复重试
#   4) 幂等：重复执行无害

CC=/proc/sys/net/ipv4/tcp_congestion_control
QD=/proc/sys/net/core/default_qdisc
LOG=/data/local/tmp/bbr.log

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

log "=================================================="
log "boot:  before cc=$(cat $CC 2>/dev/null)  qdisc=$(cat $QD 2>/dev/null || echo 'n/a')"

# 1) 默认队列算法 fq：对之后新建的接口自动生效
if [ -w "$QD" ]; then
    echo fq > "$QD" 2>/dev/null && log "ok:    default_qdisc -> fq"
else
    log "skip:  $QD 不可写"
fi

# 2) 启用 BBR
if echo bbr > "$CC" 2>/dev/null; then
    log "ok:    tcp_congestion_control -> $(cat $CC)"
else
    log "FAIL:  设置 bbr 失败，可用: $(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null)"
fi

# 3) 空闲后不重置拥塞窗口（切网/短暂空闲后不重新慢启动）
echo 0 > /proc/sys/net/ipv4/tcp_slow_start_after_idle 2>/dev/null \
    && log "ok:    tcp_slow_start_after_idle -> 0"

# 4) 给当前已存在的实体网卡套 fq（一次即可；之后新建的接口由 default_qdisc 负责）
TC=""
for t in /system/bin/tc /system/xbin/tc /vendor/bin/tc; do
    [ -x "$t" ] && { TC="$t"; break; }
done

if [ -n "$TC" ]; then
    log "tc:    $TC"
    for d in $(ls /sys/class/net 2>/dev/null); do
        case "$d" in
            lo|docker0|tailscale0|tunl0|gre0|gretap0|erspan0|sit0|ip_vti0|ip6tnl0|ip6gre0|ip6_vti0|bond0) continue ;;
            rmnet_ipa*|rmnet_*_mux*) continue ;;
        esac
        "$TC" qdisc replace dev "$d" root fq 2>/dev/null \
            && log "ok:    qdisc fq -> $d"
    done
else
    log "skip:  找不到 tc，跳过网卡 qdisc（BBR 仍可用）"
fi

log "boot:  after  cc=$(cat $CC 2>/dev/null)  qdisc=$(cat $QD 2>/dev/null || echo 'n/a')"
log "=================================================="

exit 0
