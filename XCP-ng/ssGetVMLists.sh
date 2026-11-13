#!/bin/sh
# =========================================================================
# XCP-ng Multi-Pool Inventory Collector (VLAN/Name Grouping & NotAssigned)
# =========================================================================

if [ $# -eq 0 ]; then
    echo "Usage: $0 <pool_master_host_1> [pool_master_host_2 ...]" >&2
    exit 1
fi

# Excel / LibreOffice Calc 文字化け防止用の UTF-8 BOM 出力
printf '\357\273\277'

WORKDIR="/tmp/xcp_inventory_$$"
if ! mkdir -p "$WORKDIR"; then
    echo "Error: Failed to create work directory." >&2
    exit 1
fi
trap 'rm -rf "$WORKDIR"' EXIT INT TERM

GLOBAL_DATA="$WORKDIR/global_collected.tsv"
: > "$GLOBAL_DATA"

# =========================================================================
# 1. 各プールマスターへのSSH接続によるデータ収集フェーズ
# =========================================================================
for MASTER in "$@"; do
    [ -z "$MASTER" ] && continue

    ssh -o ConnectTimeout=5 "root@$MASTER" 'sh -s' << 'EOF' >> "$GLOBAL_DATA"
    # プール基本情報の取得
    POOL_UUID=$(xe pool-list params=uuid --minimal < /dev/null 2>/dev/null | tr -d '\r\n')
    POOL_NAME=$(xe pool-param-get uuid="$POOL_UUID" param-name=name-label < /dev/null 2>/dev/null | tr -d '\r\n')
    [ -z "$POOL_NAME" ] && POOL_NAME="Default-Pool"
    MASTER_UUID=$(xe pool-list params=master --minimal < /dev/null 2>/dev/null | tr -d '\r\n')

    # サブネットマスクをCIDRプレフィックス長に変換するヘルパー関数
    mask_to_cidr() {
        awk -v m="$1" 'BEGIN {
            if (m == "" || m == "<not in database>") { print ""; exit }
            split(m, o, ".");
            bits = 0;
            for (i = 1; i <= 4; i++) {
                v = o[i] + 0;
                while (v > 0) {
                    if (v % 2 == 1) bits++;
                    v = int(v / 2);
                }
            }
            if (bits > 0) print "/" bits;
        }'
    }

    # ---------------------------------------------------------------------
    # A. ネットワーク情報の収集 (NET)
    # ---------------------------------------------------------------------
    for n_uuid in $(xe network-list params=uuid --minimal < /dev/null 2>/dev/null | tr ',' ' ' | tr '\n' ' '); do
        n_uuid=$(printf '%s' "$n_uuid" | tr -d '\r\n')
        [ -z "$n_uuid" ] && continue
        n_name=$(xe network-param-get uuid="$n_uuid" param-name=name-label < /dev/null 2>/dev/null | tr -d '\r\n')
        vlan_id=$(xe network-param-get uuid="$n_uuid" param-name=vlan < /dev/null 2>/dev/null | tr -d '\r\n')

        if [ -z "$vlan_id" ] || [ "$vlan_id" = "<not in database>" ] || [ "$vlan_id" = "-1" ]; then
            pif_uuid=$(xe pif-list network-uuid="$n_uuid" params=uuid --minimal < /dev/null 2>/dev/null | tr ',' ' ' | awk '{print $1}' | tr -d '\r\n')
            [ -n "$pif_uuid" ] && vlan_id=$(xe pif-param-get uuid="$pif_uuid" param-name=VLAN < /dev/null 2>/dev/null | tr -d '\r\n')
            [ "$vlan_id" = "<not in database>" ] && vlan_id=""

            if [ -z "$vlan_id" ] || [ "$vlan_id" = "-1" ]; then
                bridge=$(xe network-param-get uuid="$n_uuid" param-name=bridge < /dev/null 2>/dev/null | tr -d '\r\n')
                case "$bridge" in
                    vlan*) vlan_id=$(printf '%s' "$bridge" | sed 's/vlan//') ;;
                esac
            fi
        fi

        net_type="ACCESS"
        sort_key="0"
        header_name="$n_name"
        vid_val=""

        if [ -n "$vlan_id" ] && [ "$vlan_id" != "-1" ] && [ "$vlan_id" != "" ]; then
            net_type="TRUNK"
            sort_key=$(printf '%04d' "$vlan_id")
            vid_val="$vlan_id"
            case "$n_name" in
                *vLAN* | *VLAN* | *vlan*) header_name="$n_name" ;;
                *) header_name="vLAN${sort_key}" ;;
            esac
        else
            # VLANがない場合はネットワーク名(n_name)をグループキーおよびソートキーにする
            vid_val="NON_VLAN_${n_name}"
            sort_key="NON_VLAN_${n_name}"
        fi
        # NET: $2=n_uuid, $3=header_name, $4=net_type, $5=sort_key, $6=n_name, $7=POOL_NAME, $8=vid_val
        printf 'NET\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$n_uuid" "$header_name" "$net_type" "$sort_key" "$n_name" "$POOL_NAME" "$vid_val"
    done

    # ---------------------------------------------------------------------
    # B. 物理ホスト (PH) およびホストNIC情報の収集
    # ---------------------------------------------------------------------
    for h_uuid in $(xe host-list params=uuid --minimal < /dev/null 2>/dev/null | tr ',' ' ' | tr '\n' ' '); do
        h_uuid=$(printf '%s' "$h_uuid" | tr -d '\r\n')
        [ -z "$h_uuid" ] && continue
        h_name=$(xe host-param-get uuid="$h_uuid" param-name=name-label < /dev/null 2>/dev/null | tr -d '\r\n')

        for pif_uuid in $(xe pif-list host-uuid="$h_uuid" params=uuid --minimal < /dev/null 2>/dev/null | tr ',' ' ' | tr '\n' ' '); do
            pif_uuid=$(printf '%s' "$pif_uuid" | tr -d '\r\n')
            [ -z "$pif_uuid" ] && continue
            pif_net=$(xe pif-param-get uuid="$pif_uuid" param-name=network-uuid < /dev/null 2>/dev/null | tr -d '\r\n')
            pif_dev=$(xe pif-param-get uuid="$pif_uuid" param-name=device < /dev/null 2>/dev/null | tr -d '\r\n')
            pif_vlan=$(xe pif-param-get uuid="$pif_uuid" param-name=VLAN < /dev/null 2>/dev/null | tr -d '\r\n')
            pif_ip=$(xe pif-param-get uuid="$pif_uuid" param-name=IP < /dev/null 2>/dev/null | tr -d '\r\n')
            pif_mask=$(xe pif-param-get uuid="$pif_uuid" param-name=netmask < /dev/null 2>/dev/null | tr -d '\r\n')
            [ "$pif_ip" = "<not in database>" ] && pif_ip=""

            disp_dev="$pif_dev"
            if [ -n "$pif_vlan" ] && [ "$pif_vlan" != "-1" ] && [ "$pif_vlan" != "<not in database>" ]; then
                disp_dev="${pif_dev}.${pif_vlan}"
            fi

            ip_val=""
            if [ -n "$pif_ip" ]; then
                cidr=$(mask_to_cidr "$pif_mask")
                [ -z "$cidr" ] && cidr="/24"
                ip_val="${pif_ip}${cidr}"
            else
                ip_val="NotAssigned"
            fi

            [ -n "$pif_net" ] && [ -n "$disp_dev" ] && printf 'HOST_NIC\t%s\t%s\t%s\t%s\n' "$h_uuid" "$pif_net" "$disp_dev" "$ip_val"
        done

        h_cores=$(xe host-cpu-list host-uuid="$h_uuid" params=number --minimal < /dev/null 2>/dev/null | awk -F',' '{sum+=$1} END {print sum}' | tr -d '\r\n')
        [ -z "$h_cores" ] && h_cores=$(xe host-param-get uuid="$h_uuid" param-name=cpu-info param-key=cpu_count < /dev/null 2>/dev/null | tr -d '\r\n')

        h_mem_bytes=$(xe host-param-get uuid="$h_uuid" param-name=memory-total < /dev/null 2>/dev/null | tr -d '\r\n')
        h_mem_mib=$(awk -v b="${h_mem_bytes:-0}" 'BEGIN { printf "%.0f", b / 1024 / 1024 }')

        h_os_raw=$(xe host-param-get uuid="$h_uuid" param-name=software-version param-key=product_version < /dev/null 2>/dev/null | tr -d '\r\n')
        h_os_ver="XCP-ng Hypervisor v${h_os_raw}"

        sr_uuids=$(xe sr-list host-uuid="$h_uuid" type=lvm params=uuid --minimal < /dev/null 2>/dev/null | tr ',' ' ')
        h_disk_gib=""
        for sr in $sr_uuids; do
            sr=$(printf '%s' "$sr" | tr -d '\r\n')
            [ -z "$sr" ] && continue
            sr_bytes=$(xe sr-param-get uuid="$sr" param-name=physical-size < /dev/null 2>/dev/null | tr -d '\r\n')
            if [ -n "$sr_bytes" ] && [ "$sr_bytes" != "<not in database>" ]; then
                gib=$(awk -v b="$sr_bytes" 'BEGIN { printf "%.1fGiB", b / 1024 / 1024 / 1024 }')
                [ -z "$h_disk_gib" ] && h_disk_gib="$gib" || h_disk_gib="${h_disk_gib}; ${gib}"
            fi
        done

        printf 'HOST\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$POOL_NAME" "$h_name" "$h_os_ver" "${h_cores:-1}" "${h_mem_mib:-0}" "${h_disk_gib:-N/A}" "$h_uuid"
    done

    # ---------------------------------------------------------------------
    # C. 仮想マシン (VM)、コントロールドメイン (CD)、スナップショット (SS) の収集
    # ---------------------------------------------------------------------
    SNAP_UUID_LIST=$(xe snapshot-list params=uuid --minimal < /dev/null 2>/dev/null | tr ',' '\n' | grep -v '^$')
    ALL_UUIDS=$( (xe vm-list is-a-template=false params=uuid --minimal < /dev/null 2>/dev/null | tr ',' '\n'; printf '%s\n' "$SNAP_UUID_LIST") | grep -v '^$' | sort -u )

    for UUID in $ALL_UUIDS; do
        UUID=$(printf '%s' "$UUID" | tr -d '\r\n')
        [ -z "$UUID" ] && continue

        VM_NAME=$(xe vm-param-get uuid="$UUID" param-name=name-label < /dev/null 2>/dev/null | tr -d '\r\n')
        POWER_STATE=$(xe vm-param-get uuid="$UUID" param-name=power-state < /dev/null 2>/dev/null | tr -d '\r\n')
        RESIDENT_UUID=$(xe vm-param-get uuid="$UUID" param-name=resident-on < /dev/null 2>/dev/null | tr -d '\r\n')
        [ "$RESIDENT_UUID" = "<not in database>" ] && RESIDENT_UUID=""
        DOM_ID=$(xe vm-param-get uuid="$UUID" param-name=dom-id < /dev/null 2>/dev/null | tr -d '\r\n')
        IS_CTRL=$(xe vm-param-get uuid="$UUID" param-name=is-control-domain < /dev/null 2>/dev/null | tr -d '\r\n')

        IS_SNAP=$(xe vm-param-get uuid="$UUID" param-name=is-a-snapshot < /dev/null 2>/dev/null | tr -d '\r\n')
        if [ "$IS_SNAP" != "true" ]; then
            if printf '%s\n' "$SNAP_UUID_LIST" | grep -qxF "$UUID"; then
                IS_SNAP="true"
            fi
        fi

        PARENT_UUID=$(xe vm-param-get uuid="$UUID" param-name=snapshot-of < /dev/null 2>/dev/null | tr -d '\r\n')
        [ "$PARENT_UUID" = "<not in database>" ] && PARENT_UUID=""
        C_DATE=$(xe vm-param-get uuid="$UUID" param-name=created-on < /dev/null 2>/dev/null | tr -d '\r\n')
        [ "$C_DATE" = "<not in database>" ] && C_DATE=""

        host_name="Halted"
        if [ -n "$RESIDENT_UUID" ]; then
            host_name=$(xe host-param-get uuid="$RESIDENT_UUID" param-name=name-label < /dev/null 2>/dev/null | tr -d '\r\n')
        elif [ "$POWER_STATE" = "running" ]; then
            host_name="Running"
        fi

        vcpus=$(xe vm-param-get uuid="$UUID" param-name=VCPUs-number < /dev/null 2>/dev/null | tr -d '\r\n')
        mem_bytes=$(xe vm-param-get uuid="$UUID" param-name=memory-static-max < /dev/null 2>/dev/null | tr -d '\r\n')
        mem_mib=$(awk -v b="${mem_bytes:-0}" 'BEGIN { printf "%.0f", b / 1024 / 1024 }')

        os_raw=$(xe vm-param-get uuid="$UUID" param-name=os-version < /dev/null 2>/dev/null)
        os_ver=""
        if [ -n "$os_raw" ] && [ "$os_raw" != "<not in database>" ]; then
            os_ver=$(printf '%s' "$os_raw" | awk -F'; ' '{
                for(i=1; i<=NF; i++) { if ($i ~ /^name:/) { sub(/^name:[[:space:]]*/, "", $i); print $i; exit } }
            }' | tr -d '\r\n')
        fi
        [ "$IS_CTRL" = "true" ] && [ -z "$os_ver" ] && os_ver="XCP-ng (Control Domain)"
        [ "$IS_SNAP" = "true" ] && [ -z "$os_ver" ] && os_ver="N/A (Snapshot)"

        hostname="XXXXXXXX"
        if [ -n "$DOM_ID" ] && [ "$DOM_ID" != "-1" ] && [ -n "$RESIDENT_UUID" ]; then
            h_addr=$(xe host-param-get uuid="$RESIDENT_UUID" param-name=address < /dev/null 2>/dev/null | tr -d '\r\n')
            if [ "$RESIDENT_UUID" = "$MASTER_UUID" ]; then
                hostname=$(xenstore-read "/local/domain/${DOM_ID}/data/hostname" < /dev/null 2>/dev/null | tr -d '\r\n')
                [ -z "$hostname" ] && hostname=$(xenstore-read "/local/domain/${DOM_ID}/attr/hostname" < /dev/null 2>/dev/null | tr -d '\r\n')
            elif [ -n "$h_addr" ]; then
                hostname=$(ssh -n -o ConnectTimeout=2 "root@${h_addr}" "xenstore-read '/local/domain/${DOM_ID}/data/hostname'" 2>/dev/null | tr -d '\r\n')
            fi
        fi
        [ "$IS_CTRL" = "true" ] && [ -z "$hostname" ] && hostname="$host_name"
        [ -z "$hostname" ] && hostname="XXXXXXXX"

        disks_gib=""
        if [ "$IS_CTRL" != "true" ]; then
            vdi_uuids=$(xe vbd-list vm-uuid="$UUID" type=Disk params=vdi-uuid --minimal < /dev/null 2>/dev/null | tr ',' ' ')
            for vdi in $vdi_uuids; do
                vdi=$(printf '%s' "$vdi" | tr -d '\r\n')
                if [ -n "$vdi" ] && [ "$vdi" != "<not in database>" ]; then
                    vdi_bytes=$(xe vdi-param-get uuid="$vdi" param-name=virtual-size < /dev/null 2>/dev/null | tr -d '\r\n')
                    if [ -n "$vdi_bytes" ] && [ "$vdi_bytes" != "<not in database>" ]; then
                        gib=$(awk -v b="$vdi_bytes" 'BEGIN { printf "%.1fGiB", b / 1024 / 1024 / 1024 }')
                        [ -z "$disks_gib" ] && disks_gib="$gib" || disks_gib="${disks_gib}; ${gib}"
                    fi
                fi
            done
        else
            disks_gib="N/A (Control Domain)"
        fi

        if [ "$IS_CTRL" = "true" ]; then
            obj_type="CD"
        elif [ "$IS_SNAP" = "true" ]; then
            obj_type="SS"
        else
            obj_type="VM"
        fi

        printf 'OBJ\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$POOL_NAME" "$host_name" "$obj_type" "$VM_NAME" "$hostname" "$os_ver" "${vcpus:-0}" "${mem_mib:-0}" "${disks_gib:-N/A}" \
            "$UUID" "${IS_CTRL:-false}" "${IS_SNAP:-false}" "${PARENT_UUID}" "${C_DATE}" "${RESIDENT_UUID}"

        # VIF情報の収集
        net_map=$(xe vm-param-get uuid="$UUID" param-name=networks < /dev/null 2>/dev/null)
        vif_uuids=$(xe vif-list vm-uuid="$UUID" params=uuid --minimal < /dev/null 2>/dev/null | tr ',' ' ')
        for vif in $vif_uuids; do
            vif=$(printf '%s' "$vif" | tr -d '\r\n')
            [ -z "$vif" ] && continue
            vif_net_uuid=$(xe vif-param-get uuid="$vif" param-name=network-uuid < /dev/null 2>/dev/null | tr -d '\r\n')
            dev=$(xe vif-param-get uuid="$vif" param-name=device < /dev/null 2>/dev/null | tr -d '\r\n')
            [ -z "$dev" ] && dev="0"
            ip_addr=$(printf '%s' "$net_map" | awk -v dev="$dev" -F'; ' '{
                for(i=1; i<=NF; i++) { if ($i ~ "^" dev "/ip:") { sub("^" dev "/ip:[[:space:]]*", "", $i); print $i; exit } }
            }' | tr -d '\r\n')

            nic_name="${dev}"
            ip_val=""
            if [ -n "$ip_addr" ] && [ "$ip_addr" != "<not in database>" ] && [ "$ip_addr" != "" ]; then
                ip_val="${ip_addr}/24"
            else
                ip_val="NotAssigned"
            fi
            printf 'VIF\t%s\t%s\t%s\t%s\n' "$UUID" "$vif_net_uuid" "$nic_name" "$ip_val"
        done
    done
EOF
done

# =========================================================================
# 2. AWK による統合処理・VLAN/名前ベースのグループ化とNotAssigned対応
# =========================================================================
awk -F'\t' '
{
    type = $1
    if (type == "NET") {
        # NET: $2=n_uuid, $3=header_name, $4=net_type, $5=sort_key, $6=n_name, $7=pool_name, $8=vid_val
        n_uuid = $2; h_name = $3; n_type = $4; s_key = $5; r_name = $6; p_name = $7; v_val = $8;
        
        # VLANがない場合は vid_val に "NON_VLAN_ネットワーク名" が入るため、
        # プール間でネットワーク名が一致すれば同じグループにまとまる
        group_key = v_val;

        if (net_group_names[group_key] == "") {
            net_group_names[group_key] = h_name;
            net_group_types[group_key] = n_type;
            net_group_sort[group_key] = s_key;
            net_group_vid[group_key] = v_val;
            net_keys[++net_count] = group_key;
        } else {
            if (net_group_names[group_key] != h_name) {
                if (index(net_group_names[group_key], "(ERR)") == 0) {
                    net_group_names[group_key] = net_group_names[group_key] "(ERR)";
                }
            }
        }
        net_uuid_to_group[n_uuid] = group_key;

    } else if (type == "HOST") {
        h_uuid = $8;
        if (h_uuid != "") {
            host_pool[h_uuid] = $2;
            host_name[h_uuid] = $3;
            host_os[h_uuid] = $4;
            host_cores[h_uuid] = $5;
            host_mem[h_uuid] = $6;
            host_disk[h_uuid] = $7;
            if (seen_host[h_uuid] == "") {
                seen_host[h_uuid] = 1;
                host_keys[++host_count] = h_uuid;
            }
        }
    } else if (type == "HOST_NIC") {
        # HOST_NIC: $2=h_uuid, $3=pif_net, $4=disp_dev, $5=ip_val
        h_uuid = $2; pif_net = $3; nic_n = $4; ip_n = $5;
        g_id = net_uuid_to_group[pif_net];
        if (g_id != "") {
            key = h_uuid SUBSEP g_id;
            if (nic_n != "") host_nic[key] = (host_nic[key] == "" ? nic_n : host_nic[key] "; " nic_n);
            if (ip_n != "") host_ip[key] = (host_ip[key] == "" ? ip_n : host_ip[key] "; " ip_n);
        }
    } else if (type == "OBJ") {
        uuid = $11;
        if (uuid == "") next;

        obj_pool[uuid] = $2;
        obj_host[uuid] = $3;
        obj_type[uuid] = $4;
        obj_name[uuid] = $5;
        obj_hn[uuid] = $6;
        obj_os[uuid] = $7;
        obj_vc[uuid] = $8;
        obj_mem[uuid] = $9;
        obj_disk[uuid] = $10;
        is_ctrl = $12;
        is_snap = $13;
        parent = $14;
        cdate = $15;
        res_host[uuid] = $16;

        if (is_snap == "true") {
            if (parent != "") {
                snap_list[parent] = snap_list[parent] (snap_list[parent] == "" ? "" : "\n") uuid "\t" cdate;
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
        # VIF: $2=UUID, $3=vif_net_uuid, $4=nic_name, $5=ip_val
        uuid = $2; pif_net = $3; nic_n = $4; ip_n = $5;
        g_id = net_uuid_to_group[pif_net];
        if (g_id != "") {
            key = uuid SUBSEP g_id;
            if (nic_n != "") vif_nic[key] = (vif_nic[key] == "" ? nic_n : vif_nic[key] "; " nic_n);
            if (ip_n != "") vif_ip[key] = (vif_ip[key] == "" ? ip_n : vif_ip[key] "; " ip_n);
        }
    }
}
END {
    # ネットワークグループのソート
    for (i = 1; i < net_count; i++) {
        for (j = i + 1; j <= net_count; j++) {
            ki = net_keys[i]; kj = net_keys[j];
            cond = 0;
            if (net_group_types[ki] == "TRUNK" && net_group_types[kj] == "ACCESS") {
                cond = 1;
            } else if (net_group_types[ki] == "ACCESS" && net_group_types[kj] == "TRUNK") {
                cond = 0;
            } else if (net_group_types[ki] == "TRUNK" && net_group_types[kj] == "TRUNK") {
                if (net_group_sort[ki] > net_group_sort[kj]) cond = 1;
            } else {
                if (net_group_names[ki] > net_group_names[kj]) cond = 1;
            }
            if (cond) {
                temp = net_keys[i]; net_keys[i] = net_keys[j]; net_keys[j] = temp;
            }
        }
    }

    # 2行ヘッダーの構築・出力
    header1 = "\"Pool_Name\",\"Resident_Host\",\"Object_Type\",\"VM_Name\",\"Hostname\",\"OS_Version\",\"vCPUs_or_Cores\",\"Memory_MiB\",\"Disks_GiB\",\"UUID\"";
    header2 = "\"\",\"\",\"\",\"\",\"\",\"\",\"\",\"\",\"\",\"\"";

    for (i = 1; i <= net_count; i++) {
        g_id = net_keys[i];
        n_name = net_group_names[g_id];
        v_id = net_group_vid[g_id];
        
        # NON_VLAN の場合はVID表示欄を空欄にする
        if (index(v_id, "NON_VLAN_") == 1) {
            v_id = "";
        }
        
        gsub(/"/, "\"\"", n_name);
        header1 = header1 sprintf(",\"%s\",\"%s\"", n_name, n_name);
        header2 = header2 sprintf(",\"%s\",\"%s\"", v_id, v_id);
    }
    print header1;
    print header2;

    # 1. 物理ホスト (PH) 行の出力
    for (idx = 1; idx <= host_count; idx++) {
        h_uuid = host_keys[idx];
        p = host_pool[h_uuid];
        h = host_name[h_uuid];
        os = host_os[h_uuid];
        cores = host_cores[h_uuid];
        mem = host_mem[h_uuid];
        disk = host_disk[h_uuid];

        gsub(/"/, "\"\"", p); gsub(/"/, "\"\"", h); gsub(/"/, "\"\"", os); gsub(/"/, "\"\"", disk);

        line = sprintf("\"%s\",\"%s\",\"PH\",\"%s\",\"XXXXXXXX\",\"%s\",\"%s\",\"%s\",\"%s\",\"%s\"",
            p, h, h, os, cores, mem, disk, h_uuid);

        for (j = 1; j <= net_count; j++) {
            g_id = net_keys[j];
            key = h_uuid SUBSEP g_id;
            nic_v = host_nic[key];
            ip_v = host_ip[key];
            gsub(/"/, "\"\"", nic_v); gsub(/"/, "\"\"", ip_v);
            line = line sprintf(",\"%s\",\"%s\"", nic_v, ip_v);
        }
        print line;
    }

    # 2. コントロールドメイン (CD) 行の出力
    for (idx = 1; idx <= cd_count; idx++) {
        uuid = cd_keys[idx];
        h_uuid = res_host[uuid];
        for (j = 1; j <= net_count; j++) {
            g_id = net_keys[j];
            h_key = h_uuid SUBSEP g_id;
            c_key = uuid SUBSEP g_id;
            if (host_nic[h_key] != "") {
                vif_nic[c_key] = host_nic[h_key];
            }
            if (host_ip[h_key] != "") {
                vif_ip[c_key] = host_ip[h_key];
            }
        }
        print_obj_row(uuid, "");
    }

    # 3. 通常仮想マシン (VM) および紐付くスナップショットの出力
    for (idx = 1; idx <= vm_count; idx++) {
        vm = vm_keys[idx];
        vm_real_name = obj_name[vm];
        print_obj_row(vm, "");

        if (snap_list[vm] != "") {
            sorted_snaps = sort_snaps(snap_list[vm]);
            s_count = split(sorted_snaps, s_arr, "\n");
            for (j = 1; j <= s_count; j++) {
                split(s_arr[j], s_parts, "\t");
                s_uuid = s_parts[1];
                if (s_uuid != "") {
                    print_obj_row(s_uuid, "[Parent: " vm_real_name "]");
                }
            }
        }
    }

    # 4. 孤立スナップショット (SS) の出力
    for (idx = 1; idx <= orphan_count; idx++) {
        o_uuid = orphan_keys[idx];
        if (o_uuid != "") {
            print_obj_row(o_uuid, "[Orphan Snapshot]");
        }
    }
}

function print_obj_row(uuid, prefix,    p, h, t, n, hn, os, vc, m, d, line, i, g_id, key, nic_val, ip_val) {
    if (printed[uuid] == 1) return;
    printed[uuid] = 1;

    p = obj_pool[uuid]; h = obj_host[uuid]; t = obj_type[uuid];
    n = (prefix == "" ? obj_name[uuid] : prefix " " obj_name[uuid]);
    hn = obj_hn[uuid]; os = obj_os[uuid]; vc = obj_vc[uuid]; m = obj_mem[uuid]; d = obj_disk[uuid];

    gsub(/"/, "\"\"", p); gsub(/"/, "\"\"", h); gsub(/"/, "\"\"", t);
    gsub(/"/, "\"\"", n); gsub(/"/, "\"\"", hn); gsub(/"/, "\"\"", os); gsub(/"/, "\"\"", d);

    line = sprintf("\"%s\",\"%s\",\"%s\",\"%s\",\"%s\",\"%s\",\"%s\",\"%s\",\"%s\",\"%s\"", p, h, t, n, hn, os, vc, m, d, uuid);

    for (i = 1; i <= net_count; i++) {
        g_id = net_keys[i];
        key = uuid SUBSEP g_id;
        nic_val = vif_nic[key];
        ip_val = vif_ip[key];

        gsub(/"/, "\"\"", nic_val);
        gsub(/"/, "\"\"", ip_val);

        line = line sprintf(",\"%s\",\"%s\"", nic_val, ip_val);
    }
    print line;
}

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
