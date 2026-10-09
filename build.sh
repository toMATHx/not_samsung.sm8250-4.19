#!/usr/bin/env bash
set -Eeuo pipefail

SECONDS=0

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${BLUE}[*] $*${NC}"; }
warn() { echo -e "${YELLOW}[!] $*${NC}"; }
die()  { echo -e "${RED}ERROR: $*${NC}" >&2; exit 1; }

# DEVICE must be provided by the GitHub Actions workflow.
: "${DEVICE:?Defina DEVICE no workflow do GitHub Actions.}"

ROOT_DIR="$(pwd)"
OUT_DIR="${ROOT_DIR}/out"
TC_DIR="${ROOT_DIR}/tc/clang"
BOOT_DIR="${OUT_DIR}/arch/arm64/boot"
DTS_DIR="${BOOT_DIR}/dts/vendor/qcom"

# ===== AnyKernel3 =====
AK3_REPO="https://github.com/notkernel-oss/AnyKernel3"
AK3_BRANCH="${DEVICE}"
ZIPNAME="not-$(date '+%Y%m%d').zip"

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    head_commit="$(git rev-parse --verify HEAD 2>/dev/null || true)"
    if [[ -n "$head_commit" ]]; then
        ZIPNAME="not-$(date '+%Y%m%d')-${head_commit:0:8}-${DEVICE}.zip"
    fi
fi

# Keep the original NotKernel config order.
DEFCONFIG=(
    "vendor/kona-perf_defconfig"
    "vendor/samsung/kona-sec-common.config"
    "vendor/samsung/${DEVICE}.config"
    "vendor/not/ksu.config"
    "vendor/not/localversion.config"
)

git submodule update --init --recursive

# ---------------------------------------------------------------------------
# STEP 1 + 2: Fetch official non-GKI patches and apply them before configuring.
# The patch list is taken from Droidspaces-OSS itself, not hard-coded.
# Existing patches are detected so reruns do not apply them twice.
# ---------------------------------------------------------------------------
PATCH_REPO="https://github.com/ravindu644/Droidspaces-OSS.git"
PATCH_DIR="${ROOT_DIR}/.droidspaces-oss"

log "Obtendo patches oficiais do Droidspaces-OSS..."
rm -rf "$PATCH_DIR"
git clone --depth=1 --filter=blob:none "$PATCH_REPO" "$PATCH_DIR" ||
    die "Não foi possível clonar o repositório oficial Droidspaces-OSS."

PATCH_SOURCE="${PATCH_DIR}/Documentation/resources/kernel-patches/non-GKI"
[[ -d "$PATCH_SOURCE" ]] ||
    die "Pasta oficial de patches non-GKI não encontrada: $PATCH_SOURCE"

shopt -s nullglob
PATCHES=("$PATCH_SOURCE"/*.patch)
shopt -u nullglob
((${#PATCHES[@]} > 0)) ||
    die "Nenhum arquivo .patch foi encontrado na pasta oficial non-GKI."

for patch_file in "${PATCHES[@]}"; do
    patch_name="$(basename "$patch_file")"
    log "Verificando patch: $patch_name"

    if patch --batch --forward --dry-run -p1 < "$patch_file" >/dev/null 2>&1; then
        patch --batch --forward -p1 < "$patch_file" ||
            die "Falha ao aplicar $patch_name."
        log "Patch aplicado: $patch_name"
    elif patch --batch --reverse --dry-run -p1 < "$patch_file" >/dev/null 2>&1; then
        warn "Patch já aplicado; ignorando: $patch_name"
    else
        die "O patch $patch_name não se aplica ao código atual e também não parece já estar aplicado. Build interrompido para evitar alterações parciais."
    fi
done

# ---------------------------------------------------------------------------
# Toolchain setup (preserved from the original build.sh).
# ---------------------------------------------------------------------------
export PATH="${TC_DIR}/bin:${PATH}"

if [[ ! -d "$TC_DIR" ]]; then
    log "Clang não encontrado; baixando..."
    mkdir -p "$TC_DIR"

    ASSET_URL="$(
        curl -fsSL https://api.github.com/repos/Neutron-Toolchains/clang-build-catalogue/releases/latest |
        jq -r '[.assets[] | select(.name | endswith(".tar.zst"))][0].browser_download_url // empty'
    )"
    [[ -n "$ASSET_URL" ]] || die "Não foi possível encontrar um release do Clang."

    curl -fL "$ASSET_URL" | tar --zstd -x -C "$TC_DIR" --strip-components=1 ||
        die "Falha ao baixar/extrair o Clang."
fi

mkdir -p "$OUT_DIR"
log "Configurando kernel com: ${DEFCONFIG[*]}"
make O=out ARCH=arm64 "${DEFCONFIG[@]}"

# ---------------------------------------------------------------------------
# STEP 3: Generate and merge the Droidspaces config fragment.
# Includes mandatory legacy-kernel settings plus optional UFW/Fail2ban
# firewall settings, as requested. olddefconfig resolves Kconfig dependencies.
# ---------------------------------------------------------------------------
DROIDSPACES_CONFIG="${OUT_DIR}/droidspaces.config"
cat > "$DROIDSPACES_CONFIG" <<'DROIDSPACES_CONFIG_EOF'
# Droidspaces mandatory configuration for legacy/non-GKI Linux 4.19
CONFIG_SYSCTL=y
CONFIG_SYSVIPC=y
CONFIG_POSIX_MQUEUE=y

CONFIG_NAMESPACES=y
CONFIG_PID_NS=y
CONFIG_UTS_NS=y
CONFIG_IPC_NS=y
CONFIG_USER_NS=y

CONFIG_SECCOMP=y
CONFIG_SECCOMP_FILTER=y

CONFIG_CGROUPS=y
CONFIG_CGROUP_DEVICE=y
CONFIG_CGROUP_SCHED=y
CONFIG_FAIR_GROUP_SCHED=y
CONFIG_CGROUP_FREEZER=y
CONFIG_CGROUP_NET_PRIO=y
CONFIG_MEMCG=y
CONFIG_CFS_BANDWIDTH=y
CONFIG_CGROUP_PIDS=y
CONFIG_CGROUP_CPUACCT=y

CONFIG_DEVTMPFS=y
CONFIG_OVERLAY_FS=y
CONFIG_TMPFS_POSIX_ACL=y
CONFIG_TMPFS_XATTR=y

CONFIG_FW_LOADER=y
CONFIG_FW_LOADER_USER_HELPER=y
CONFIG_FW_LOADER_COMPRESS=y

CONFIG_NET_NS=y
CONFIG_VETH=y
CONFIG_BRIDGE=y
CONFIG_NETFILTER=y
CONFIG_BRIDGE_NETFILTER=y
CONFIG_NETFILTER_ADVANCED=y
CONFIG_NF_CONNTRACK=y
CONFIG_IP_NF_IPTABLES=y
CONFIG_IP_NF_FILTER=y
CONFIG_NF_NAT=y
CONFIG_NF_TABLES=y
CONFIG_IP_NF_TARGET_MASQUERADE=y
CONFIG_NETFILTER_XT_TARGET_MASQUERADE=y
CONFIG_NETFILTER_XT_TARGET_TCPMSS=y
CONFIG_NETFILTER_XT_MATCH_ADDRTYPE=y
CONFIG_NF_CONNTRACK_NETLINK=y
CONFIG_NF_NAT_REDIRECT=y
CONFIG_IP_ADVANCED_ROUTER=y
CONFIG_IP_MULTIPLE_TABLES=y

# Legacy IPv4 compatibility options from the Droidspaces guide
CONFIG_NF_CONNTRACK_IPV4=y
CONFIG_NF_NAT_IPV4=y
CONFIG_IP_NF_NAT=y

# IPv6 NAT support from the legacy-kernel guide
CONFIG_IPV6=y
CONFIG_IPV6_MULTIPLE_TABLES=y
CONFIG_IP6_NF_IPTABLES=y
CONFIG_IP6_NF_FILTER=y
CONFIG_IP6_NF_MANGLE=y
CONFIG_IP6_NF_NAT=y
CONFIG_IP6_NF_TARGET_MASQUERADE=y
CONFIG_NF_CONNTRACK_IPV6=y
CONFIG_NF_NAT_IPV6=y

# Older Android kernels: disable Android paranoid network restriction
# CONFIG_ANDROID_PARANOID_NETWORK is not set

# Optional firewall support: UFW / Fail2ban
CONFIG_NETFILTER_XT_MATCH_COMMENT=y
CONFIG_NETFILTER_XT_MATCH_STATE=y
CONFIG_NETFILTER_XT_MATCH_CONNTRACK=y
CONFIG_NETFILTER_XT_MATCH_MULTIPORT=y
CONFIG_NETFILTER_XT_MATCH_HL=y
CONFIG_NETFILTER_XT_TARGET_REJECT=y
CONFIG_IP_NF_TARGET_REJECT=y
CONFIG_NETFILTER_XT_TARGET_LOG=y
CONFIG_IP_NF_TARGET_ULOG=y
CONFIG_NETFILTER_XT_MATCH_RECENT=y
CONFIG_NETFILTER_XT_MATCH_LIMIT=y
CONFIG_NETFILTER_XT_MATCH_HASHLIMIT=y
CONFIG_NETFILTER_XT_MATCH_OWNER=y
CONFIG_NETFILTER_XT_MATCH_PKTTYPE=y
CONFIG_NETFILTER_XT_MATCH_MARK=y
CONFIG_NETFILTER_XT_TARGET_MARK=y
CONFIG_IP_SET=y
CONFIG_IP_SET_HASH_IP=y
CONFIG_IP_SET_HASH_NET=y
CONFIG_NETFILTER_XT_SET=y
CONFIG_NETFILTER_NETLINK_QUEUE=y
CONFIG_NETFILTER_NETLINK_LOG=y
CONFIG_NETFILTER_XT_TARGET_NFLOG=y
DROIDSPACES_CONFIG_EOF

[[ -x scripts/kconfig/merge_config.sh ]] ||
    die "scripts/kconfig/merge_config.sh não existe neste kernel."

log "Mesclando configurações Droidspaces..."
scripts/kconfig/merge_config.sh -m -O "$OUT_DIR" "$OUT_DIR/.config" "$DROIDSPACES_CONFIG" ||
    die "Falha ao mesclar as configurações Droidspaces."

make O=out ARCH=arm64 olddefconfig ||
    die "olddefconfig falhou."

# Report all requested settings after Kconfig resolves dependencies.
log "Verificando opções obrigatórias no out/.config..."
REQUIRED_CONFIGS=(
    CONFIG_SYSCTL CONFIG_SYSVIPC CONFIG_POSIX_MQUEUE
    CONFIG_NAMESPACES CONFIG_PID_NS CONFIG_UTS_NS CONFIG_IPC_NS CONFIG_USER_NS
    CONFIG_SECCOMP CONFIG_SECCOMP_FILTER
    CONFIG_CGROUPS CONFIG_CGROUP_DEVICE CONFIG_CGROUP_SCHED CONFIG_FAIR_GROUP_SCHED
    CONFIG_CGROUP_FREEZER CONFIG_CGROUP_NET_PRIO CONFIG_MEMCG CONFIG_CFS_BANDWIDTH
    CONFIG_CGROUP_PIDS CONFIG_CGROUP_CPUACCT
    CONFIG_DEVTMPFS CONFIG_OVERLAY_FS CONFIG_TMPFS_POSIX_ACL CONFIG_TMPFS_XATTR
    CONFIG_FW_LOADER CONFIG_FW_LOADER_USER_HELPER CONFIG_FW_LOADER_COMPRESS
    CONFIG_NET_NS CONFIG_VETH CONFIG_BRIDGE CONFIG_NETFILTER CONFIG_BRIDGE_NETFILTER
    CONFIG_NETFILTER_ADVANCED CONFIG_NF_CONNTRACK CONFIG_IP_NF_IPTABLES CONFIG_IP_NF_FILTER
    CONFIG_NF_NAT CONFIG_NF_TABLES CONFIG_IP_NF_TARGET_MASQUERADE
    CONFIG_NETFILTER_XT_TARGET_MASQUERADE CONFIG_NETFILTER_XT_TARGET_TCPMSS
    CONFIG_NETFILTER_XT_MATCH_ADDRTYPE CONFIG_NF_CONNTRACK_NETLINK CONFIG_NF_NAT_REDIRECT
    CONFIG_IP_ADVANCED_ROUTER CONFIG_IP_MULTIPLE_TABLES
    CONFIG_NF_CONNTRACK_IPV4 CONFIG_NF_NAT_IPV4 CONFIG_IP_NF_NAT
    CONFIG_IPV6 CONFIG_IPV6_MULTIPLE_TABLES CONFIG_IP6_NF_IPTABLES
    CONFIG_IP6_NF_FILTER CONFIG_IP6_NF_MANGLE CONFIG_IP6_NF_NAT
    CONFIG_IP6_NF_TARGET_MASQUERADE CONFIG_NF_CONNTRACK_IPV6 CONFIG_NF_NAT_IPV6
)
missing=0
for symbol in "${REQUIRED_CONFIGS[@]}"; do
    if grep -qx "${symbol}=y" "$OUT_DIR/.config"; then
        echo -e "${GREEN}OK${NC} $symbol=y"
    else
        echo -e "${RED}MISSING${NC} $symbol"
        missing=1
    fi
done
if grep -qx 'CONFIG_ANDROID_PARANOID_NETWORK=y' "$OUT_DIR/.config"; then
    echo -e "${RED}MISSING${NC} CONFIG_ANDROID_PARANOID_NETWORK=n"
    missing=1
else
    echo -e "${GREEN}OK${NC} CONFIG_ANDROID_PARANOID_NETWORK is not enabled"
fi
(( missing == 0 )) || die "Uma ou mais configurações obrigatórias não ficaram habilitadas. Veja as linhas MISSING acima."

log "Configuração Droidspaces validada. Iniciando compilação..."

make -j"$(nproc --all)" O=out ARCH=arm64 \
    CC=clang LD=ld.lld AS=llvm-as AR=llvm-ar NM=llvm-nm \
    OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip \
    CROSS_COMPILE=aarch64-linux-gnu- CROSS_COMPILE_ARM32=arm-linux-gnueabi- \
    LLVM=1 LLVM_IAS=1 dtbo.img ||
    die "Falha ao compilar dtbo.img."

make -j"$(nproc --all)" O=out ARCH=arm64 \
    CC=clang LD=ld.lld AS=llvm-as AR=llvm-ar NM=llvm-nm \
    OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip \
    CROSS_COMPILE=aarch64-linux-gnu- CROSS_COMPILE_ARM32=arm-linux-gnueabi- \
    LLVM=1 LLVM_IAS=1 Image ||
    die "Falha ao compilar Image."

[[ -f "$BOOT_DIR/Image" ]] || die "Compilação falhou: Image não encontrado."

log "Kernel Image encontrado."
[[ -d "$DTS_DIR" ]] || die "Diretório DTS não encontrado: $DTS_DIR"
mapfile -t DTB_FILES < <(find "$DTS_DIR" -type f -name "*.dtb" | sort)
((${#DTB_FILES[@]} > 0)) || die "Nenhum arquivo .dtb foi gerado em $DTS_DIR"
cat "${DTB_FILES[@]}" > "$BOOT_DIR/dtb"
[[ -s "$BOOT_DIR/dtb" ]] || die "Falha ao gerar dtb."

rm -rf AnyKernel3
log "Clonando AnyKernel3 para $DEVICE..."
git clone -q -b "$AK3_BRANCH" "$AK3_REPO" AnyKernel3 ||
    die "Falha ao clonar AnyKernel3."

[[ -f "$BOOT_DIR/dtbo.img" ]] || die "dtbo.img não encontrado."
cp "$BOOT_DIR/dtbo.img" AnyKernel3/dtbo.img
cp "$BOOT_DIR/Image" AnyKernel3/Image
cp "$BOOT_DIR/dtb" AnyKernel3/dtb

(
    cd AnyKernel3
    zip -r9 "../$ZIPNAME" . -x ".git/*" "README.md" "*placeholder*"
) || die "Falha ao criar o ZIP."

echo -e "\n${GREEN}Concluído em $((SECONDS / 60)) minuto(s) e $((SECONDS % 60)) segundo(s)!${NC}"
echo -e "${GREEN}ZIP: $ZIPNAME${NC}"
