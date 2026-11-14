#!/bin/sh
# =========================================================================
# XCP-ng Multi-Pool Inventory Collector (POSIX sh + AWK)
# =========================================================================
# オプション環境変数:
#   XCP_SLAVE_PASS : スレーブホストがPassword認証の場合の共通パスワード
#                    (プールマスター上に sshpass が必要)
# =========================================================================

if [ $# -eq 0 ]; then
    echo "Usage: $0 <pool_master_host_1> [pool_master_host_2 ...]" >&2
    exit 1
fi

WORKDIR="/tmp/xcp_inventory_$$"
if ! mkdir -p "$WORKDIR"; then
    echo "Error: Failed to create work directory." >&2
    exit 1
fi
trap 'rm -rf "$WORKDIR"' EXIT INT TERM

GLOBAL_DATA="$WORKDIR/global_collected.tsv"
: > "$GLOBAL_DATA"

SUCCESS_COUNT=0
FAIL_COUNT=0

# =========================================================================
# 1. 各プールマスターへのSSH接続によるデータ収集フェーズ
# =========================================================================
for MASTER in "$@"; do
    [ -z "$MASTER" ] && continue

    POOL_OUT="$WORKDIR/pool_${SUCCESS_COUNT}_${FAIL_COUNT}.tsv"
    POOL_ERR="$WORKDIR/pool_${SUCCESS_COUNT}_${FAIL_COUNT}.err"

    # シングルクォートを安全にエスケープしてリモートへ環境変数を渡す
    ESCAPED_PASS=$(printf '%s' "${XCP_SLAVE_PASS:-}" | sed "s/'/'\\\\''/g")

    if {
        printf "XCP_SLAVE_PASS='%s'\n" "$ESCAPED_PASS"
        cat << 'EOF'
    # -----------------------------------------------------------------
    # リモート側: 一括 xe コマンド取得 & AWK による高速構造化
    # -----------------------------------------------------------------
    DUMP_DIR="/tmp/xcp_dump_$$"
    mkdir -p "$DUMP_DIR" || exit 1
    trap 'rm -rf "$DUMP_DIR"' EXIT INT TERM

    # N+1実行を避けるため、必要な全オブジェクトを一括取得 (計11回のみ)
    xe pool-list params=uuid,name-label,master < /dev/null > "$DUMP_DIR/pool.txt" 2>/dev/null
    xe network-list params=uuid,name-label,bridge < /dev/null > "$DUMP_DIR/net.txt" 2>/dev/null
    xe pif-list params=uuid,host-uuid,network-uuid,device,VLAN,IP,netmask,IPv6 < /dev/null > "$DUMP_DIR/pif.txt" 2>/dev/null
    xe host-list params=uuid,name-label,address,memory-total,software-version,cpu_info < /dev/null > "$DUMP_DIR/host.txt" 2>/dev/null
    xe sr-list params=uuid,type,content-type,shared,physical-size < /dev/null > "$DUMP_DIR/sr.txt" 2>/dev/null
    xe pbd-list params=uuid,host-uuid,sr-uuid < /dev/null > "$DUMP_DIR/pbd.txt" 2>/dev/null
    xe vm-list is-a-template=false params=uuid,name-label,power-state,resident-on,dom-id,is-control-domain,is-a-snapshot,snapshot-of,snapshot-time,VCPUs-number,memory-static-max,os-version,networks < /dev/null > "$DUMP_DIR/vm.txt" 2>/dev/null
    xe snapshot-list params=uuid,name-label,power-state,resident-on,dom-id,is-control-domain,is-a-snapshot,snapshot-of,snapshot-time,VCPUs-number,memory-static-max,os-version,networks < /dev/null > "$DUMP_DIR/snap.txt" 2>/dev/null
    xe vbd-list type=Disk params=uuid,vm-uuid,vdi-uuid < /dev/null > "$DUMP_DIR/vbd.txt" 2>/dev/null
    xe vdi-list params=uuid,virtual-size < /dev/null > "$DUMP_DIR/vdi.txt" 2>/dev/null
    xe vif-list params=uuid,vm-uuid,network-uuid,device < /dev/null > "$DUMP_DIR/vif.txt" 2>/dev/null

    # 稼働中VMのゲストホスト名 (XenStore) をホスト単位で一括収集
    HOSTNAME_MAP="$DUMP_DIR/hostnames.tsv"
    : > "$HOSTNAME_MAP"

    MASTER_UUID=$(awk -F': ' '/^[[:space:]]*master[[:space:]]*\(/ { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit }' "$DUMP_DIR/pool.txt")

    # ホストUUID -> IPアドレス マップ作成
    awk '
    function flush() {
        if (u != "" && a != "") print u "\t" a;
        u = ""; a = "";
    }
    /^[[:space:]]*uuid[[:space:]]*\(/ { flush(); sub(/^[^:]+:[[:space:]]*/, ""); u = $0; next }
    /^[[:space:]]*address[[:space:]]*\(/ { sub(/^[^:]+:[[:space:]]*/, ""); a = $0; next }
    END { flush() }
    ' "$DUMP_DIR/host.txt" > "$DUMP_DIR/host_addr.tsv"

    # 稼働中 (dom-id > 0) の VM 一覧 (resident_uuid \t dom_id) を抽出
    awk '
    function flush() {
        if (res != "" && dom != "" && dom != "-1" && dom != "0") {
            print res "\t" dom;
        }
        res = ""; dom = "";
    }
    /^[[:space:]]*uuid[[:space:]]*\(/ { flush(); next }
    /^[[:space:]]*resident-on[[:space:]]*\(/ { sub(/^[^:]+:[[:space:]]*/, ""); if ($0 != "<not in database>") res = $0; next }
    /^[[:space:]]*dom-id[[:space:]]*\(/ { sub(/^[^:]+:[[:space:]]*/, ""); dom = $0; next }
    END { flush() }
    ' "$DUMP_DIR/vm.txt" | sort -u > "$DUMP_DIR/running_doms.tsv"

    # ホストごとに1回だけ xenstore-read を実行 (多段SSHの最小化・ハング防止)
    cut -f1 "$DUMP_DIR/running_doms.tsv" | sort -u | while IFS= read -r H_UUID; do
        [ -z "$H_UUID" ] && continue
        DOMS=$(awk -F'\t' -v h="$H_UUID" '$1 == h { printf "%s ", $2 }' "$DUMP_DIR/running_doms.tsv")
        [ -z "$DOMS" ] && continue

        if [ "$H_UUID" = "$MASTER_UUID" ]; then
            for d in $DOMS; do
                hn=$(xenstore-read "/local/domain/${d}/data/hostname" < /dev/null 2>/dev/null)
                [ -z "$hn" ] && hn=$(xenstore-read "/local/domain/${d}/attr/hostname" < /dev/null 2>/dev/null)
                hn=$(printf '%s' "$hn" | tr '\t\r\n' '   ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                [ -n "$hn" ] && printf '%s\t%s\t%s\n' "$H_UUID" "$d" "$hn" >> "$HOSTNAME_MAP"
            done
        else
            H_ADDR=$(awk -F'\t' -v h="$H_UUID" '$1 == h { print $2; exit }' "$DUMP_DIR/host_addr.tsv")
            [ -z "$H_ADDR" ] && continue

            REMOTE_CMD="for d in $DOMS; do hn=\$(xenstore-read \"/local/domain/\${d}/data/hostname\" 2>/dev/null); [ -z \"\$hn\" ] && hn=\$(xenstore-read \"/local/domain/\${d}/attr/hostname\" 2>/dev/null); [ -n \"\$hn\" ] && printf '%s\t%s\n' \"\$d\" \"\$hn\"; done"

            RAW_RES=""
            if [ -n "$XCP_SLAVE_PASS" ] && command -v sshpass >/dev/null 2>&1; then
                RAW_RES=$(SSHPASS="$XCP_SLAVE_PASS" sshpass -e ssh -n \
                    -o StrictHostKeyChecking=no \
                    -o UserKnownHostsFile=/dev/null \
                    -o LogLevel=ERROR \
                    -o ConnectTimeout=3 \
                    "root@${H_ADDR}" "$REMOTE_CMD" < /dev/null 2>/dev/null)
            else
                RAW_RES=$(ssh -n \
                    -o BatchMode=yes \
                    -o StrictHostKeyChecking=no \
                    -o UserKnownHostsFile=/dev/null \
                    -o LogLevel=ERROR \
                    -o ConnectTimeout=3 \
                    "root@${H_ADDR}" "$REMOTE_CMD" < /dev/null 2>/dev/null)
            fi

            if [ -n "$RAW_RES" ]; then
                printf '%s\n' "$RAW_RES" | while IFS="$(printf '\t')" read -r d hn; do
                    hn=$(printf '%s' "$hn" | tr '\t\r\n' '   ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                    [ -n "$d" ] && [ -n "$hn" ] && printf '%s\t%s\t%s\n' "$H_UUID" "$d" "$hn" >> "$HOSTNAME_MAP"
                done
            fi
        fi
    done < /dev/null

    # ダンプファイルを AWK で一括パースし、正規化済み TSV レコードを出力
    awk -v dump_dir="$DUMP_DIR" '
    function clean(s) {
        gsub(/[\t\r\n]+/, " ", s);
        sub(/^[[:space:]]+/, "", s);
        sub(/[[:space:]]+$/, "", s);
        if (s == "<not in database>") return "";
        return s;
    }

    # サブネットマスクの厳密検証 & CIDR変換
    function mask_to_cidr(m,   n, o, i, v, val, k, target) {
        m = clean(m);
        if (m == "") return "(Err)";
        if (m !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) return "(Err)";
        n = split(m, o, ".");
        if (n != 4) return "(Err)";
        val = 0;
        for (i = 1; i <= 4; i++) {
            v = o[i] + 0;
            if (v < 0 || v > 255) return "(Err)";
            val = val * 256 + v;
        }
        for (k = 0; k <= 32; k++) {
            target = 4294967296 - (2 ^ (32 - k));
            if (val == target) return "/" k;
        }
        return "(Err)";
    }

    # 1以上の整数 (VLAN ID 1..4094) かどうか判定
    function is_valid_vlan(v,   num) {
        v = clean(v);
        if (v !~ /^[0-9]+$/) return 0;
        num = v + 0;
        return (num >= 1 && num <= 4094);
    }

    # xe *-list のキー:値を抽出
    function parse_kv(line, kv,   pos, k, v) {
        pos = index(line, ":");
        if (pos == 0) return 0;
        k = substr(line, 1, pos - 1);
        v = substr(line, pos + 1);
        sub(/^[[:space:]]+/, "", k);
        sub(/[[:space:]]*\([^)]*\)[[:space:]]*$/, "", k);
        kv[1] = k;
        kv[2] = clean(v);
        return 1;
    }

    BEGIN {
        # 1. Pool 情報
        f = dump_dir "/pool.txt";
        pool_name = "Default-Pool";
        while ((getline line < f) > 0) {
            if (parse_kv(line, kv) && kv[1] == "name-label" && kv[2] != "") {
                pool_name = kv[2];
            }
        }
        close(f);

        # 2. Hostnames (XenStore)
        f = dump_dir "/hostnames.tsv";
        while ((getline line < f) > 0) {
            split(line, a, "\t");
            if (a[1] != "" && a[2] != "") {
                xs_hn[a[1] SUBSEP a[2]] = clean(a[3]);
            }
        }
        close(f);

        # 3. Network 情報
        f = dump_dir "/net.txt";
        cur = "";
        while ((getline line < f) > 0) {
            if (parse_kv(line, kv)) {
                if (kv[1] == "uuid") {
                    cur = kv[2];
                    net_list[++net_cnt] = cur;
                } else if (cur != "") {
                    if (kv[1] == "name-label") net_name[cur] = kv[2];
                    else if (kv[1] == "bridge") net_bridge[cur] = kv[2];
                }
            }
        }
        close(f);

        # 4. PIF 情報
        f = dump_dir "/pif.txt";
        cur = "";
        while ((getline line < f) > 0) {
            if (parse_kv(line, kv)) {
                if (kv[1] == "uuid") {
                    cur = kv[2];
                    pif_list[++pif_cnt] = cur;
                } else if (cur != "") {
                    pif[cur, kv[1]] = kv[2];
                }
            }
        }
        close(f);

        # PIFのVLAN情報からNetworkのVLANを補完し、HOST_NICレコードを生成 (IPv4 / IPv6 分離)
        for (i = 1; i <= pif_cnt; i++) {
            pu = pif_list[i];
            hu = pif[pu, "host-uuid"];
            nu = pif[pu, "network-uuid"];
            dev = pif[pu, "device"];
            pvlan = pif[pu, "VLAN"];
            pip4 = pif[pu, "IP"];
            pmask = pif[pu, "netmask"];
            pip6 = pif[pu, "IPv6"];

            if (nu != "" && is_valid_vlan(pvlan) && net_vlan[nu] == "") {
                net_vlan[nu] = (pvlan + 0) "";
            }

            disp_dev = dev;
            if (is_valid_vlan(pvlan)) {
                disp_dev = dev "." (pvlan + 0);
            }

            ipv4_str = "";
            if (pip4 != "") {
                ipv4_str = pip4 mask_to_cidr(pmask);
            }

            ipv6_str = "";
            if (pip6 != "") {
                n6 = split(pip6, arr6, ";");
                for (j = 1; j <= n6; j++) {
                    v6 = clean(arr6[j]);
                    if (v6 != "") {
                        ipv6_str = (ipv6_str == "" ? v6 : ipv6_str "; " v6);
                    }
                }
            }

            if (hu != "" && nu != "" && disp_dev != "") {
                printf "HOST_NIC\t%s\t%s\t%s\t%s\t%s\n", hu, nu, disp_dev, ipv4_str, ipv6_str;
            }
        }

        # NET レコード出力
        for (i = 1; i <= net_cnt; i++) {
            nu = net_list[i];
            vid = net_vlan[nu];
            if (vid == "" && net_bridge[nu] ~ /^vlan[0-9]+$/) {
                b_vid = net_bridge[nu];
                sub(/^vlan/, "", b_vid);
                if (is_valid_vlan(b_vid)) vid = (b_vid + 0) "";
            }
            printf "NET\t%s\t%s\t%s\t%s\n", nu, net_name[nu], vid, pool_name;
        }

        # 5. SR & PBD 情報
        f = dump_dir "/sr.txt";
        cur = "";
        while ((getline line < f) > 0) {
            if (parse_kv(line, kv)) {
                if (kv[1] == "uuid") cur = kv[2];
                else if (cur != "") sr[cur, kv[1]] = kv[2];
            }
        }
        close(f);

        f = dump_dir "/pbd.txt";
        cur = "";
        while ((getline line < f) > 0) {
            if (parse_kv(line, kv)) {
                if (kv[1] == "uuid") {
                    cur = kv[2];
                    pbd_list[++pbd_cnt] = cur;
                } else if (cur != "") {
                    pbd[cur, kv[1]] = kv[2];
                }
            }
        }
        close(f);

        for (i = 1; i <= pbd_cnt; i++) {
            pu = pbd_list[i];
            cur_h = pbd[pu, "host-uuid"];
            cur_s = pbd[pu, "sr-uuid"];
            if (cur_h != "" && cur_s != "") {
                pbd_key = cur_h SUBSEP cur_s;
                if (!seen_pbd[pbd_key]++) {
                    host_srs[cur_h] = (host_srs[cur_h] == "" ? cur_s : host_srs[cur_h] " " cur_s);
                }
            }
        }

        # 6. Host 情報
        f = dump_dir "/host.txt";
        cur = "";
        while ((getline line < f) > 0) {
            if (parse_kv(line, kv)) {
                if (kv[1] == "uuid") {
                    cur = kv[2];
                    host_list[++host_cnt] = cur;
                } else if (cur != "") {
                    host[cur, kv[1]] = kv[2];
                }
            }
        }
        close(f);

        for (i = 1; i <= host_cnt; i++) {
            hu = host_list[i];
            hname = host[hu, "name-label"];
            host_name_map[hu] = hname;

            cores = "1";
            cpu_model = "Unknown";
            cinfo = host[hu, "cpu_info"];
            if (cinfo != "") {
                n_ci = split(cinfo, ci_arr, ";");
                for (j = 1; j <= n_ci; j++) {
                    item = clean(ci_arr[j]);
                    if (item ~ /^cpu_count:/) {
                        sub(/^cpu_count:[[:space:]]*/, "", item);
                        if (clean(item) != "") cores = clean(item);
                    } else if (item ~ /^modelname:/) {
                        sub(/^modelname:[[:space:]]*/, "", item);
                        gsub(/[[:space:]]+/, " ", item);
                        if (clean(item) != "") cpu_model = clean(item);
                    }
                }
            }

            mem_b = host[hu, "memory-total"] + 0;
            mem_mib = sprintf("%.0f", mem_b / 1024 / 1024);
            os_ver = "XCP-ng Hypervisor v" host[hu, "software-version"];

            local_disk = ""; shared_disk = "";
            n_sr = split(host_srs[hu], sr_arr, " ");
            for (j = 1; j <= n_sr; j++) {
                su = sr_arr[j];
                if (sr[su, "content-type"] != "user") continue;
                s_bytes = sr[su, "physical-size"];
                if (s_bytes == "" || (s_bytes + 0) <= 0) continue;
                s_type = sr[su, "type"];
                gib = sprintf("%.1fGiB (%s)", (s_bytes + 0) / 1024 / 1024 / 1024, s_type);
                if (sr[su, "shared"] == "false") {
                    local_disk = (local_disk == "" ? gib : local_disk "; " gib);
                } else {
                    sh_gib = sprintf("%.1fGiB (%s/shared)", (s_bytes + 0) / 1024 / 1024 / 1024, s_type);
                    shared_disk = (shared_disk == "" ? sh_gib : shared_disk "; " sh_gib);
                }
            }
            disk_disp = (local_disk != "" ? local_disk : (shared_disk != "" ? shared_disk : "N/A"));

            # HOST: $2=pool_name, $3=hname, $4=os_ver, $5=cores, $6=cpu_model, $7=mem_mib, $8=disk_disp, $9=hu
            printf "HOST\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", pool_name, hname, os_ver, cores, cpu_model, mem_mib, disk_disp, hu;
        }

        # 7. VDI & VBD (ディスク容量マップ)
        f = dump_dir "/vdi.txt";
        cur = "";
        while ((getline line < f) > 0) {
            if (parse_kv(line, kv)) {
                if (kv[1] == "uuid") cur = kv[2];
                else if (cur != "" && kv[1] == "virtual-size") vdi_size[cur] = kv[2];
            }
        }
        close(f);

        f = dump_dir "/vbd.txt";
        cur = "";
        while ((getline line < f) > 0) {
            if (parse_kv(line, kv)) {
                if (kv[1] == "uuid") {
                    cur = kv[2];
                    vbd_list[++vbd_cnt] = cur;
                } else if (cur != "") {
                    vbd[cur, kv[1]] = kv[2];
                }
            }
        }
        close(f);

        for (i = 1; i <= vbd_cnt; i++) {
            bu = vbd_list[i];
            cur_vm = vbd[bu, "vm-uuid"];
            cur_vdi = vbd[bu, "vdi-uuid"];
            if (cur_vm != "" && cur_vdi != "") {
                vb = vdi_size[cur_vdi];
                if (vb != "" && (vb + 0) > 0) {
                    dgib = sprintf("%.1fGiB", (vb + 0) / 1024 / 1024 / 1024);
                    vm_disks[cur_vm] = (vm_disks[cur_vm] == "" ? dgib : vm_disks[cur_vm] "; " dgib);
                }
            }
        }

        # 8. VM & Snapshot 情報
        for (pass = 1; pass <= 2; pass++) {
            f = (pass == 1 ? dump_dir "/vm.txt" : dump_dir "/snap.txt");
            cur = "";
            while ((getline line < f) > 0) {
                if (parse_kv(line, kv)) {
                    if (kv[1] == "uuid") {
                        cur = kv[2];
                        if (!seen_vm[cur]++) vm_list[++vm_cnt] = cur;
                        if (pass == 2) is_snap_file[cur] = "true";
                    } else if (cur != "") {
                        vm[cur, kv[1]] = kv[2];
                    }
                }
            }
            close(f);
        }

        for (i = 1; i <= vm_cnt; i++) {
            vu = vm_list[i];
            vname = vm[vu, "name-label"];
            pstate = vm[vu, "power-state"];
            res_u = vm[vu, "resident-on"];
            dom_id = vm[vu, "dom-id"];
            is_ctrl = (vm[vu, "is-control-domain"] == "true" ? "true" : "false");
            is_snap = (vm[vu, "is-a-snapshot"] == "true" || is_snap_file[vu] == "true" ? "true" : "false");
            parent_u = vm[vu, "snapshot-of"];
            snap_time = vm[vu, "snapshot-time"];

            hname = "Halted";
            if (res_u != "" && host_name_map[res_u] != "") {
                hname = host_name_map[res_u];
            } else if (pstate == "running") {
                hname = "Running";
            }

            # VM / CD / SS は CPU_Model 列に "vCPU" を出力
            cpu_model = "vCPU";

            vcpus = (vm[vu, "VCPUs-number"] != "" ? vm[vu, "VCPUs-number"] : "0");
            mb = vm[vu, "memory-static-max"] + 0;
            mmib = sprintf("%.0f", mb / 1024 / 1024);

            os_ver = "";
            os_raw = vm[vu, "os-version"];
            if (os_raw != "") {
                n_os = split(os_raw, os_arr, ";");
                for (j = 1; j <= n_os; j++) {
                    item = clean(os_arr[j]);
                    if (item ~ /^name:/) {
                        sub(/^name:[[:space:]]*/, "", item);
                        os_ver = clean(item);
                        break;
                    }
                }
            }
            if (is_ctrl == "true" && os_ver == "") os_ver = "XCP-ng (Control Domain)";
            if (is_snap == "true" && os_ver == "") os_ver = "N/A (Snapshot)";

            hn = xs_hn[res_u SUBSEP dom_id];
            if (is_ctrl == "true" && hn == "") hn = hname;
            if (hn == "") hn = "XXXXXXXX";

            disks = (is_ctrl == "true" ? "N/A (Control Domain)" : (vm_disks[vu] != "" ? vm_disks[vu] : "N/A"));
            otype = (is_ctrl == "true" ? "CD" : (is_snap == "true" ? "SS" : "VM"));

            # OBJ: $2=pool, $3=hname, $4=otype, $5=vname, $6=hn, $7=os_ver, $8=vcpus, $9=cpu_model, $10=mmib, $11=disks,
            #      $12=vu, $13=is_ctrl, $14=is_snap, $15=parent_u, $16=snap_time, $17=res_u
            printf "OBJ\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n",
                pool_name, hname, otype, vname, hn, os_ver, vcpus, cpu_model, mmib, disks,
                vu, is_ctrl, is_snap, parent_u, snap_time, res_u;

            nets_raw = vm[vu, "networks"];
            if (nets_raw != "") {
                n_net = split(nets_raw, net_items, ";");
                for (j = 1; j <= n_net; j++) {
                    entry = clean(net_items[j]);
                    cpos = index(entry, ":");
                    if (cpos == 0) continue;
                    nk = clean(substr(entry, 1, cpos - 1));
                    nv = clean(substr(entry, cpos + 1));
                    if (nv == "") continue;

                    if (nk ~ /^[0-9]+\/(ip|ipv4\/[0-9]+)$/) {
                        dev_id = nk;
                        sub(/\/.*$/, "", dev_id);
                        ip_k = vu SUBSEP dev_id SUBSEP nv;
                        if (!seen_vm_ipv4[ip_k]++) {
                            vm_dev_ipv4[vu, dev_id] = (vm_dev_ipv4[vu, dev_id] == "" ? nv : vm_dev_ipv4[vu, dev_id] "; " nv);
                        }
                    } else if (nk ~ /^[0-9]+\/ipv6\/[0-9]+$/) {
                        dev_id = nk;
                        sub(/\/.*$/, "", dev_id);
                        ip_k = vu SUBSEP dev_id SUBSEP nv;
                        if (!seen_vm_ipv6[ip_k]++) {
                            vm_dev_ipv6[vu, dev_id] = (vm_dev_ipv6[vu, dev_id] == "" ? nv : vm_dev_ipv6[vu, dev_id] "; " nv);
                        }
                    }
                }
            }
        }

        # 9. VIF 情報 (IPv4 / IPv6 分離出力)
        f = dump_dir "/vif.txt";
        cur = "";
        while ((getline line < f) > 0) {
            if (parse_kv(line, kv)) {
                if (kv[1] == "uuid") {
                    cur = kv[2];
                    vif_list[++vif_cnt] = cur;
                } else if (cur != "") {
                    vif[cur, kv[1]] = kv[2];
                }
            }
        }
        close(f);

        for (i = 1; i <= vif_cnt; i++) {
            vifu = vif_list[i];
            vu = vif[vifu, "vm-uuid"];
            nu = vif[vifu, "network-uuid"];
            dev = vif[vifu, "device"];
            if (dev == "") dev = "0";
            if (vu != "" && nu != "") {
                printf "VIF\t%s\t%s\teth%s\t%s\t%s\n", vu, nu, dev, vm_dev_ipv4[vu, dev], vm_dev_ipv6[vu, dev];
            }
        }
    }
    ' < /dev/null
EOF
    } | ssh \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -o ConnectTimeout=5 \
        "root@$MASTER" 'sh -s' > "$POOL_OUT" 2> "$POOL_ERR"; then

        if [ -s "$POOL_OUT" ]; then
            cat "$POOL_OUT" >> "$GLOBAL_DATA"
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        else
            echo "Warning: Connected to '$MASTER', but no inventory data was returned." >&2
            [ -s "$POOL_ERR" ] && sed 's/^/  /' "$POOL_ERR" >&2
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
    else
        echo "Error: Failed to collect data from pool master '$MASTER'." >&2
        [ -s "$POOL_ERR" ] && sed 's/^/  /' "$POOL_ERR" >&2
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
done

if [ "$SUCCESS_COUNT" -eq 0 ]; then
    echo "Error: No data collected from any specified pool master. Aborting." >&2
    exit 1
fi

# Excel / LibreOffice Calc 文字化け防止用の UTF-8 BOM 出力
printf '\357\273\277'

# =========================================================================
# 2. AWK による統合処理・2行ヘッダーおよび全レコード出力フェーズ
# =========================================================================
awk -F'\t' '
function append_uniq(existing, val,   n, arr, i) {
    if (val == "") return existing;
    if (existing == "") return val;
    n = split(existing, arr, "; ");
    for (i = 1; i <= n; i++) {
        if (arr[i] == val) return existing;
    }
    return existing "; " val;
}

{
    type = $1;
    if (type == "NET") {
        n_uuid = $2; r_name = $3; vid_s = $4;
        if (vid_s ~ /^[0-9]+$/ && (vid_s + 0) >= 1 && (vid_s + 0) <= 4094) {
            vnum = vid_s + 0;
            s_key = sprintf("%04d", vnum);
            agg_key = "TRUNK:" s_key;
            h_name = "vLAN" s_key;
            n_type = "TRUNK";
            v_val = vnum "";
        } else {
            agg_key = "ACCESS:" (r_name != "" ? r_name : n_uuid);
            h_name = (r_name != "" ? r_name : "Unnamed-Network");
            n_type = "ACCESS";
            s_key = "0000";
            v_val = "";
        }
        net_to_agg[n_uuid] = agg_key;
        if (seen_agg[agg_key] == "") {
            seen_agg[agg_key] = 1;
            net_name[agg_key] = h_name;
            net_vid[agg_key] = v_val;
            net_type_map[agg_key] = n_type;
            net_sort_map[agg_key] = s_key;
            net_raw_map[agg_key] = r_name;
            net_keys[++net_count] = agg_key;
        }
    } else if (type == "HOST") {
        # HOST: $2=pool_name, $3=hname, $4=os_ver, $5=cores, $6=cpu_model, $7=mem_mib, $8=disk_disp, $9=hu
        h_uuid = $9;
        if (h_uuid != "") {
            host_pool[h_uuid] = $2;
            host_name[h_uuid] = $3;
            host_os[h_uuid] = $4;
            host_cores[h_uuid] = $5;
            host_cpu[h_uuid] = $6;
            host_mem[h_uuid] = $7;
            host_disk[h_uuid] = $8;
            if (seen_host[h_uuid] == "") {
                seen_host[h_uuid] = 1;
                host_keys[++host_count] = h_uuid;
            }
        }
    } else if (type == "HOST_NIC") {
        raw_host_nic[++hnic_cnt, 1] = $2;
        raw_host_nic[hnic_cnt, 2] = $3;
        raw_host_nic[hnic_cnt, 3] = $4;
        raw_host_nic[hnic_cnt, 4] = $5;
        raw_host_nic[hnic_cnt, 5] = $6;
    } else if (type == "OBJ") {
        # OBJ: $2=pool, $3=hname, $4=otype, $5=vname, $6=hn, $7=os_ver, $8=vcpus, $9=cpu_model, $10=mmib, $11=disks,
        #      $12=vu, $13=is_ctrl, $14=is_snap, $15=parent_u, $16=snap_time, $17=res_u
        uuid = $12;
        if (uuid == "") next;

        obj_pool[uuid] = $2;
        obj_host[uuid] = $3;
        obj_type[uuid] = $4;
        obj_name[uuid] = $5;
        obj_hn[uuid] = $6;
        obj_os[uuid] = $7;
        obj_vc[uuid] = $8;
        obj_cpu[uuid] = $9;
        obj_mem[uuid] = $10;
        obj_disk[uuid] = $11;
        is_ctrl = $13;
        is_snap = $14;
        parent = $15;
        stime = ($16 != "" ? $16 : "99999999T99:99:99Z");
        res_host[uuid] = $17;

        if (is_snap == "true") {
            if (parent != "") {
                snap_list[parent] = snap_list[parent] (snap_list[parent] == "" ? "" : "\n") stime "\t" uuid;
            } else {
                orphan_keys[++orphan_count] = uuid;
            }
        } else {
            if (obj_type[uuid] == "CD") {
                cd_keys[++cd_count] = uuid;
            } else {
                vm_keys[++vm_count] = uuid;
            }
        }
    } else if (type == "VIF") {
        raw_vif[++vif_cnt, 1] = $2;
        raw_vif[vif_cnt, 2] = $3;
        raw_vif[vif_cnt, 3] = $4;
        raw_vif[vif_cnt, 4] = $5;
        raw_vif[vif_cnt, 5] = $6;
    }
}
END {
    # 集約キーベースでのマップ構築
    for (i = 1; i <= hnic_cnt; i++) {
        hu = raw_host_nic[i, 1];
        nu = raw_host_nic[i, 2];
        agg = net_to_agg[nu];
        if (agg == "") continue;
        key = hu SUBSEP agg;
        host_nic[key] = append_uniq(host_nic[key], raw_host_nic[i, 3]);
        host_ipv4[key] = append_uniq(host_ipv4[key], raw_host_nic[i, 4]);
        host_ipv6[key] = append_uniq(host_ipv6[key], raw_host_nic[i, 5]);
    }

    for (i = 1; i <= vif_cnt; i++) {
        vu = raw_vif[i, 1];
        nu = raw_vif[i, 2];
        agg = net_to_agg[nu];
        if (agg == "") continue;
        key = vu SUBSEP agg;
        vif_nic[key] = append_uniq(vif_nic[key], raw_vif[i, 3]);
        vif_ipv4[key] = append_uniq(vif_ipv4[key], raw_vif[i, 4]);
        vif_ipv6[key] = append_uniq(vif_ipv6[key], raw_vif[i, 5]);
    }

    # ネットワークソート
    for (i = 1; i < net_count; i++) {
        for (j = i + 1; j <= net_count; j++) {
            ki = net_keys[i]; kj = net_keys[j];
            cond = 0;
            if (net_type_map[ki] == "TRUNK" && net_type_map[kj] == "ACCESS") {
                cond = 1;
            } else if (net_type_map[ki] == "ACCESS" && net_type_map[kj] == "TRUNK") {
                cond = 0;
            } else if (net_type_map[ki] == "TRUNK" && net_type_map[kj] == "TRUNK") {
                if (net_sort_map[ki] > net_sort_map[kj]) cond = 1;
            } else {
                if (net_raw_map[ki] > net_raw_map[kj]) cond = 1;
            }
            if (cond) {
                temp = net_keys[i]; net_keys[i] = net_keys[j]; net_keys[j] = temp;
            }
        }
    }

    # ヘッダー出力 (vCPUs_or_Cores の隣に CPU_Model を配置)
    header1 = "\"Pool_Name\",\"Resident_Host\",\"Object_Type\",\"VM_Name\",\"Hostname\",\"OS_Version\",\"vCPUs_or_Cores\",\"CPU_Model\",\"Memory_MiB\",\"Disks_GiB\",\"UUID\"";
    header2 = "\"\",\"\",\"\",\"\",\"\",\"\",\"\",\"\",\"\",\"\",\"\"";

    for (i = 1; i <= net_count; i++) {
        agg = net_keys[i];
        n_name = net_name[agg];
        v_id = net_vid[agg];
        gsub(/"/, "\"\"", n_name);
        header1 = header1 sprintf(",\"%s (NIC)\",\"%s (IPv4 addr)\",\"%s (IPv6 addr)\"", n_name, n_name, n_name);
        header2 = header2 sprintf(",\"%s\",\"%s\",\"%s\"", v_id, v_id, v_id);
    }
    print header1;
    print header2;

    # 1. 物理ホスト (PH)
    for (idx = 1; idx <= host_count; idx++) {
        h_uuid = host_keys[idx];
        p = host_pool[h_uuid];
        h = host_name[h_uuid];
        os = host_os[h_uuid];
        cores = host_cores[h_uuid];
        cpu = host_cpu[h_uuid];
        mem = host_mem[h_uuid];
        disk = host_disk[h_uuid];

        gsub(/"/, "\"\"", p); gsub(/"/, "\"\"", h); gsub(/"/, "\"\"", os);
        gsub(/"/, "\"\"", cpu); gsub(/"/, "\"\"", disk);

        line = sprintf("\"%s\",\"%s\",\"PH\",\"%s\",\"XXXXXXXX\",\"%s\",\"%s\",\"%s\",\"%s\",\"%s\",\"%s\"",
            p, h, h, os, cores, cpu, mem, disk, h_uuid);

        for (j = 1; j <= net_count; j++) {
            agg = net_keys[j];
            key = h_uuid SUBSEP agg;
            nic_v = host_nic[key];
            ipv4_v = host_ipv4[key];
            ipv6_v = host_ipv6[key];

            if (nic_v != "") {
                if (ipv4_v == "") ipv4_v = "NotAssigned";
                if (ipv6_v == "") ipv6_v = "NotAssigned";
            }

            gsub(/"/, "\"\"", nic_v); gsub(/"/, "\"\"", ipv4_v); gsub(/"/, "\"\"", ipv6_v);
            line = line sprintf(",\"%s\",\"%s\",\"%s\"", nic_v, ipv4_v, ipv6_v);
        }
        print line;
    }

    # 2. コントロールドメイン (CD)
    for (idx = 1; idx <= cd_count; idx++) {
        uuid = cd_keys[idx];
        h_uuid = res_host[uuid];
        for (j = 1; j <= net_count; j++) {
            agg = net_keys[j];
            h_key = h_uuid SUBSEP agg;
            c_key = uuid SUBSEP agg;
            if (host_nic[h_key] != "") vif_nic[c_key] = host_nic[h_key];
            if (host_ipv4[h_key] != "") vif_ipv4[c_key] = host_ipv4[h_key];
            if (host_ipv6[h_key] != "") vif_ipv6[c_key] = host_ipv6[h_key];
        }
        print_obj_row(uuid, "");
    }

    # 3. 通常仮想マシン (VM) ＆ スナップショット (SS)
    for (idx = 1; idx <= vm_count; idx++) {
        vm = vm_keys[idx];
        vm_real_name = obj_name[vm];
        print_obj_row(vm, "");

        if (snap_list[vm] != "") {
            sorted_snaps = sort_snaps(snap_list[vm]);
            s_count = split(sorted_snaps, s_arr, "\n");
            for (j = 1; j <= s_count; j++) {
                split(s_arr[j], s_parts, "\t");
                s_uuid = s_parts[2];
                if (s_uuid != "") print_obj_row(s_uuid, "[Parent: " vm_real_name "]");
            }
        }
    }

    # 4. 孤立スナップショット (SS)
    for (idx = 1; idx <= orphan_count; idx++) {
        o_uuid = orphan_keys[idx];
        if (o_uuid != "") print_obj_row(o_uuid, "[Orphan Snapshot]");
    }
}

# オブジェクト行出力関数 (VM, CD, SS共通)
function print_obj_row(uuid, prefix,    p, h, t, n, hn, os, vc, cpu, m, d, line, i, agg, key, nic_val, ipv4_val, ipv6_val) {
    if (printed[uuid] == 1) return;
    printed[uuid] = 1;

    p = obj_pool[uuid]; h = obj_host[uuid]; t = obj_type[uuid];
    n = (prefix == "" ? obj_name[uuid] : prefix " " obj_name[uuid]);
    hn = obj_hn[uuid]; os = obj_os[uuid]; vc = obj_vc[uuid]; cpu = obj_cpu[uuid]; m = obj_mem[uuid]; d = obj_disk[uuid];

    gsub(/"/, "\"\"", p); gsub(/"/, "\"\"", h); gsub(/"/, "\"\"", t);
    gsub(/"/, "\"\"", n); gsub(/"/, "\"\"", hn); gsub(/"/, "\"\"", os);
    gsub(/"/, "\"\"", cpu); gsub(/"/, "\"\"", d);

    line = sprintf("\"%s\",\"%s\",\"%s\",\"%s\",\"%s\",\"%s\",\"%s\",\"%s\",\"%s\",\"%s\",\"%s\"", p, h, t, n, hn, os, vc, cpu, m, d, uuid);

    for (i = 1; i <= net_count; i++) {
        agg = net_keys[i];
        key = uuid SUBSEP agg;
        nic_val = vif_nic[key];
        ipv4_val = vif_ipv4[key];
        ipv6_val = vif_ipv6[key];

        if (nic_val != "") {
            if (ipv4_val == "") ipv4_val = "NotAssigned";
            if (ipv6_val == "") ipv6_val = "NotAssigned";
        }

        gsub(/"/, "\"\"", nic_val);
        gsub(/"/, "\"\"", ipv4_val);
        gsub(/"/, "\"\"", ipv6_val);

        line = line sprintf(",\"%s\",\"%s\",\"%s\"", nic_val, ipv4_val, ipv6_val);
    }
    print line;
}

# スナップショットソート
function sort_snaps(str,   arr, count, i, j, temp, res) {
    count = split(str, arr, "\n");
    for (i = 1; i < count; i++) {
        for (j = i + 1; j <= count; j++) {
            if (arr[i] > arr[j]) {
                temp = arr[i]; arr[i] = arr[j]; arr[j] = temp;
            }
        }
    }
    res = "";
    for (i = 1; i <= count; i++) {
        if (arr[i] != "") res = res (res == "" ? "" : "\n") arr[i];
    }
    return res;
}
' "$GLOBAL_DATA"

[ "$FAIL_COUNT" -gt 0 ] && exit 2
exit 0
